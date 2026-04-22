import Foundation

struct UgotMCPToolSearchResult {
  let tool: [String: Any]
  let score: Int
  let matchedTerms: [String]
}

/// Client-side virtual MCP `tool_search`.
///
/// This follows the Codex-style idea at the mobile host boundary:
/// - keep full MCP tool schemas out of the local model prompt;
/// - index generic tool metadata locally (`name`, `description`, schema fields, annotations);
/// - retrieve a small candidate set for the current turn;
/// - let approval/execution use the actual MCP tool definition.
///
/// The index intentionally does not contain connector-specific aliases. It does
/// include a small generic locale bridge for common action nouns/verbs (for
/// example "변경" -> "set/change/update") because the mobile host cannot assume
/// every MCP server ships Korean search keywords for otherwise English tool
/// names. Domain-specific aliases still belong in MCP tool metadata.
struct UgotMCPToolSearchIndex {
  private struct IndexedTool {
    let tool: [String: Any]
    let name: String
    let document: String
    let compactDocument: String
    let compactName: String
    let discoveryKeywords: [String]
    let explicitRequestAlternatives: [String]
    let tokenFrequencies: [String: Int]
    let tokenCount: Int
  }

  private let entries: [IndexedTool]
  private let documentFrequencies: [String: Int]
  private let averageDocumentLength: Double

  init(
    tools: [[String: Any]],
    sourceName: String? = nil,
    sourceDescription: String? = nil
  ) {
    let sourceDocument = Self.normalized([
      sourceName,
      sourceDescription,
    ].compactMap { value -> String? in
      let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      return trimmed.isEmpty ? nil : trimmed
    }.joined(separator: " "))

    let builtEntries: [IndexedTool] = tools.compactMap { tool in
      guard let name = tool["name"] as? String, !name.isEmpty else { return nil }
      let baseDocument = Self.document(for: tool)
      let document = [baseDocument, sourceDocument]
        .filter { !$0.isEmpty }
        .joined(separator: " ")
      let discoveryKeywords = Self.discoveryKeywords(for: tool)
      let explicitRequestAlternatives = Self.explicitRequestAlternatives(from: document)
      let tokens = Self.searchTokens(from: ([document] + discoveryKeywords).joined(separator: " "))
      return IndexedTool(
        tool: tool,
        name: name,
        document: document,
        compactDocument: Self.compact(document),
        compactName: Self.compact(name),
        discoveryKeywords: discoveryKeywords,
        explicitRequestAlternatives: explicitRequestAlternatives,
        tokenFrequencies: Dictionary(tokens.map { ($0, 1) }, uniquingKeysWith: +),
        tokenCount: max(1, tokens.count)
      )
    }
    self.entries = builtEntries

    var frequencies: [String: Int] = [:]
    var totalTokenCount = 0
    for entry in builtEntries {
      totalTokenCount += entry.tokenCount
      for token in entry.tokenFrequencies.keys {
        frequencies[token, default: 0] += 1
      }
    }
    self.documentFrequencies = frequencies
    self.averageDocumentLength = builtEntries.isEmpty
      ? 1
      : max(1, Double(totalTokenCount) / Double(builtEntries.count))
  }

  func search(query: String, limit: Int = 8) -> [UgotMCPToolSearchResult] {
    let terms = Self.queryTerms(for: query)
    guard !terms.isEmpty else { return [] }

    let queryCompact = Self.compact(query)
    let results = entries.compactMap { entry -> UgotMCPToolSearchResult? in
      guard Self.satisfiesExplicitRequestConstraint(
        queryCompact: queryCompact,
        alternatives: entry.explicitRequestAlternatives
      ) else {
        return nil
      }

      var score = 0
      var matched: [String] = []

      if !queryCompact.isEmpty, !entry.compactName.isEmpty, queryCompact.contains(entry.compactName) {
        score += 28
        matched.append(entry.name)
      }

      let termScore = Self.searchScore(
        terms: terms,
        normalizedDocument: entry.document,
        compactDocument: entry.compactDocument
      )
      score += termScore.score
      matched.append(contentsOf: termScore.matchedTerms)

      let discoveryScore = Self.discoveryScore(
        queryTerms: terms,
        queryCompact: queryCompact,
        keywords: entry.discoveryKeywords
      )
      score += discoveryScore.score
      matched.append(contentsOf: discoveryScore.matchedTerms)

      let bm25 = bm25Score(terms: terms, entry: entry)
      score += bm25.score
      matched.append(contentsOf: bm25.matchedTerms)

      let intentBoost = Self.intentBoost(
        queryCompact: queryCompact,
        queryTerms: terms,
        entry: entry
      )
      score += intentBoost.score
      matched.append(contentsOf: intentBoost.matchedTerms)

      guard score > 0 else { return nil }
      return UgotMCPToolSearchResult(
        tool: entry.tool,
        score: score,
        matchedTerms: Self.unique(matched).prefixArray(12)
      )
    }

    return results
      .sorted { lhs, rhs in
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        let lhsName = lhs.tool["name"] as? String ?? ""
        let rhsName = rhs.tool["name"] as? String ?? ""
        return lhsName < rhsName
      }
      .prefix(max(1, limit))
      .map { $0 }
  }

  func topScore(query: String) -> Int {
    search(query: query, limit: 1).first?.score ?? 0
  }

  func eligibleTools(query: String) -> [[String: Any]] {
    let queryCompact = Self.compact(query)
    return entries.compactMap { entry in
      Self.satisfiesExplicitRequestConstraint(
        queryCompact: queryCompact,
        alternatives: entry.explicitRequestAlternatives
      ) ? entry.tool : nil
    }
  }

  static func searchScore(query: String, document: String) -> (score: Int, matchedTerms: [String]) {
    let terms = queryTerms(for: query)
    guard !terms.isEmpty else { return (0, []) }
    let normalizedDocument = normalized(document)
    let compactDocument = compact(document)
    return searchScore(terms: terms, normalizedDocument: normalizedDocument, compactDocument: compactDocument)
  }

  static func document(for tool: [String: Any]) -> String {
    var parts: [String] = []
    appendStrings(from: tool, to: &parts)
    if let annotations = tool["annotations"] as? [String: Any] {
      appendStrings(from: annotations, to: &parts)
    }
    if let meta = tool["_meta"] as? [String: Any] {
      appendStrings(from: meta, to: &parts)
    }
    if let schema = tool["inputSchema"] as? [String: Any] {
      appendSchema(schema, to: &parts)
    }
    return normalized(parts.joined(separator: " "))
  }

  private static func appendStrings(from dict: [String: Any], to parts: inout [String]) {
    appendValue(dict, to: &parts, depth: 0)
  }

  private static func appendValue(_ value: Any, to parts: inout [String], depth: Int) {
    guard depth <= 5 else { return }
    switch value {
    case let string as String:
      parts.append(string)
    case let bool as Bool:
      parts.append(bool ? "true" : "false")
    case let number as NSNumber:
      parts.append(number.stringValue)
    case let array as [Any]:
      for item in array {
        appendValue(item, to: &parts, depth: depth + 1)
      }
    case let dict as [String: Any]:
      for (key, nested) in dict {
        parts.append(key)
        appendValue(nested, to: &parts, depth: depth + 1)
      }
    default:
      break
    }
  }

  private static func appendSchema(_ schema: [String: Any], to parts: inout [String]) {
    appendStrings(from: schema, to: &parts)
    if let properties = schema["properties"] as? [String: Any] {
      for (name, rawProperty) in properties {
        parts.append(name)
        if let property = rawProperty as? [String: Any] {
          appendStrings(from: property, to: &parts)
          if let enumValues = property["enum"] as? [Any] {
            parts.append(enumValues.map { String(describing: $0) }.joined(separator: " "))
          }
        }
      }
    }
    if let required = schema["required"] as? [String] {
      parts.append(required.joined(separator: " "))
    }
  }

  private static func discoveryScore(
    queryTerms: [WeightedTerm],
    queryCompact: String,
    keywords: [String]
  ) -> (score: Int, matchedTerms: [String]) {
    guard !keywords.isEmpty else { return (0, []) }

    var score = 0
    var matched: [String] = []
    for keyword in keywords {
      let compactKeyword = compact(keyword)
      guard compactKeyword.count >= 2 else { continue }

      if !queryCompact.isEmpty, queryCompact.contains(compactKeyword) {
        score += 24
        matched.append(keyword)
        continue
      }

      if !queryCompact.isEmpty, compactKeyword.contains(queryCompact), queryCompact.count >= 2 {
        score += 12
        matched.append(keyword)
        continue
      }

      let keywordTokens = tokens(from: keyword).map(compact).filter { $0.count >= 2 }
      for term in queryTerms {
        let compactTerm = compact(term.value)
        guard compactTerm.count >= 2 else { continue }
        if keywordTokens.contains(compactTerm) || compactKeyword == compactTerm {
          score += 10
          matched.append(keyword)
          break
        }
        if keywordTokens.contains(where: { compactTerm.hasPrefix($0) || $0.hasPrefix(compactTerm) }) {
          score += 6
          matched.append(keyword)
          break
        }
      }
    }
    return (score, unique(matched).prefixArray(12))
  }

  private static func searchScore(
    terms: [WeightedTerm],
    normalizedDocument: String,
    compactDocument: String
  ) -> (score: Int, matchedTerms: [String]) {
    var score = 0
    var matched: [String] = []
    for term in terms {
      let normalized = Self.normalized(term.value)
      let compact = Self.compact(term.value)
      guard !normalized.isEmpty || !compact.isEmpty else { continue }

      let didMatch =
        (!normalized.isEmpty && normalizedDocument.contains(normalized)) ||
        (!compact.isEmpty && compactDocument.contains(compact))
      guard didMatch else { continue }

      score += term.weight
      matched.append(term.value)
    }
    return (score, unique(matched).prefixArray(12))
  }

  private func bm25Score(
    terms: [WeightedTerm],
    entry: IndexedTool
  ) -> (score: Int, matchedTerms: [String]) {
    guard !entries.isEmpty else { return (0, []) }

    let documentCount = Double(entries.count)
    let documentLength = Double(max(1, entry.tokenCount))
    let averageLength = max(1, averageDocumentLength)
    let k1 = 1.2
    let b = 0.75

    var rawScore = 0.0
    var matched: [String] = []
    for term in terms {
      let token = Self.compact(term.value)
      guard !token.isEmpty,
            let frequency = entry.tokenFrequencies[token],
            frequency > 0 else {
        continue
      }

      let documentFrequency = Double(max(1, documentFrequencies[token] ?? 0))
      let idf = log(1 + (documentCount - documentFrequency + 0.5) / (documentFrequency + 0.5))
      let termFrequency = Double(frequency)
      let normalizedFrequency = (termFrequency * (k1 + 1)) /
        (termFrequency + k1 * (1 - b + b * (documentLength / averageLength)))
      rawScore += idf * normalizedFrequency * (Double(term.weight) / 4.0)
      matched.append(term.value)
    }

    return (Int((rawScore * 18).rounded()), Self.unique(matched).prefixArray(12))
  }

  private static func discoveryKeywords(for tool: [String: Any]) -> [String] {
    var values: [String] = []

    func appendStrings(_ raw: Any?) {
      switch raw {
      case let string as String:
        values.append(string)
      case let strings as [String]:
        values.append(contentsOf: strings)
      case let array as [Any]:
        for item in array { appendStrings(item) }
      default:
        break
      }
    }

    func appendFromDictionary(_ dict: [String: Any]) {
      appendStrings(dict["tool/searchKeywords"])
      appendStrings(dict["tool/search.keywords"])
      if let search = dict["tool/search"] as? [String: Any] {
        appendStrings(search["keywords"])
      }
      if let tool = dict["tool"] as? [String: Any],
         let search = tool["search"] as? [String: Any] {
        appendStrings(search["keywords"])
      }
    }

    if let meta = tool["_meta"] as? [String: Any] {
      appendFromDictionary(meta)
    }
    if let annotations = tool["annotations"] as? [String: Any] {
      appendFromDictionary(annotations)
    }
    return unique(values)
  }

  private static func explicitRequestAlternatives(from document: String) -> [String] {
    let normalizedDocument = normalized(document)
    let markers = [
      "explicitly asks for",
      "explicitly ask for",
      "explicitly requests",
      "explicitly request",
    ]
    for marker in markers {
      guard let markerRange = normalizedDocument.range(of: marker) else { continue }
      let prefix = String(normalizedDocument[..<markerRange.lowerBound].suffix(100))
      // "Do not use zodiac unless the user explicitly asks for 띠별..."
      // is guidance about another tool, not an explicit-only constraint for the
      // current tool. Treat "explicitly asks for" as a constraint only when the
      // local sentence is framed as "only use this/tool when ...".
      if prefix.contains("unless") || prefix.contains("do not use") || prefix.contains("don't use") {
        continue
      }
      let isExplicitOnlySentence =
        prefix.contains("only use") ||
        prefix.contains("use this only") ||
        prefix.contains("use it only") ||
        prefix.contains("must only") ||
        prefix.contains("only be used")
      guard isExplicitOnlySentence else { continue }
      var tail = String(normalizedDocument[markerRange.upperBound...])
      if let sentenceEnd = tail.firstIndex(where: { ".;\n".contains($0) }) {
        tail = String(tail[..<sentenceEnd])
      }
      let splitReady = tail
        .replacingOccurrences(of: " or ", with: ",")
        .replacingOccurrences(of: " and ", with: ",")
        .replacingOccurrences(of: " 또는 ", with: ",")
        .replacingOccurrences(of: " 혹은 ", with: ",")
        .replacingOccurrences(of: " 이나 ", with: ",")
      let alternatives = splitReady
        .split(separator: ",")
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) }
        .map { phrase -> String in
          var out = phrase
          for prefix in ["a ", "an ", "the "] where out.hasPrefix(prefix) {
            out.removeFirst(prefix.count)
          }
          return out.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        }
        .filter { compact($0).count >= 2 }
      if !alternatives.isEmpty {
        return unique(alternatives)
      }
    }
    return []
  }

  private static func satisfiesExplicitRequestConstraint(
    queryCompact: String,
    alternatives: [String]
  ) -> Bool {
    guard !alternatives.isEmpty else { return true }
    guard !queryCompact.isEmpty else { return false }

    for alternative in alternatives {
      let compactAlternative = compact(alternative)
      if compactAlternative.count >= 2, queryCompact.contains(compactAlternative) {
        return true
      }

      let discriminatorTokens = tokens(from: alternative)
        .map(compact)
        .filter(isExplicitRequestDiscriminator)
      if discriminatorTokens.contains(where: { queryCompact.contains($0) }) {
        return true
      }
    }
    return false
  }

  private static func isExplicitRequestDiscriminator(_ token: String) -> Bool {
    guard token.count >= 2 else { return false }
    // These are generic tail words that appear inside many tool descriptions.
    // They must not satisfy an "explicitly asks for X" constraint by
    // themselves. Example: "오늘의 운세" should not activate a tool whose
    // explicit-only examples are "띠별 운세", "zodiac fortune", or
    // "12-sign horoscope" just because both contain the generic word "운세".
    let genericTokens: Set<String> = [
      "a", "an", "the", "for", "of", "or", "and",
      "ask", "asks", "request", "requests", "explicitly",
      "daily", "today", "todays", "fortune", "horoscope",
      "sign", "signs",
      "운세",
    ]
    return !genericTokens.contains(token)
  }

  private static func queryTerms(for query: String) -> [WeightedTerm] {
    let original = tokens(from: query).map { WeightedTerm(value: $0, weight: 4) }
    return uniqueWeightedTerms(original + localeBridgeTerms(for: query, originalTokens: original.map(\.value)))
  }

  private static func localeBridgeTerms(for query: String, originalTokens: [String]) -> [WeightedTerm] {
    let compactQuery = compact(query)
    let compactTokens = Set(originalTokens.map(compact).filter { !$0.isEmpty })
    var out: [WeightedTerm] = []

    func add(_ terms: [String], weight: Int = 2) {
      out.append(contentsOf: terms.map { WeightedTerm(value: $0, weight: weight) })
    }

    func containsAny(_ values: [String]) -> Bool {
      values.contains { value in
        let key = compact(value)
        return compactQuery.contains(key) || compactTokens.contains(key)
      }
    }

    // Generic Korean/English bridge terms. Keep these domain-neutral and tied
    // to common tool metadata concepts rather than connector-specific tool
    // names.
    if containsAny(["오늘", "오늘의", "금일", "today"]) {
      add(["today", "current", "daily"], weight: 3)
    }
    if containsAny(["운세", "사주", "fortune", "saju"]) {
      add(["fortune", "saju", "daily"], weight: 3)
    }
    if containsAny(["띠별", "띠", "12궁", "12간지", "zodiac"]) {
      add(["zodiac", "12-sign", "horoscope"], weight: 4)
    }
    if containsAny(["기본", "대표", "default"]) {
      add(["default"], weight: 4)
    }
    if containsAny(["사용자", "프로필", "사람", "user", "profile"]) {
      add(["user", "profile", "person"], weight: 3)
    }
    if containsAny(["저장", "저장된", "saved", "registered"]) {
      add(["saved", "registered"], weight: 3)
    }
    if containsAny(["목록", "리스트", "list"]) {
      add(["list", "browse", "view"], weight: 3)
    }
    if containsAny(["찾아", "찾기", "검색", "search", "find"]) {
      add(["find", "search", "lookup"], weight: 3)
    }
    if containsAny(["설정", "변경", "바꿔", "선택", "set", "change", "update", "select"]) {
      add(["set", "change", "update", "select"], weight: 4)
    }
    if containsAny(["삭제", "지워", "해제", "delete", "remove", "clear"]) {
      add(["delete", "remove", "clear"], weight: 4)
    }
    if containsAny(["궁합", "관계", "상성", "연애", "compatibility", "relationship"]) {
      add(["compatibility", "relationship", "harmony", "match", "couple"], weight: 4)
    }
    if containsAny(["메일", "이메일", "mail", "email"]) {
      add(["mail", "email", "message", "inbox"], weight: 4)
    }
    if containsAny(["최근", "최신", "latest", "recent"]) {
      add(["recent", "latest"], weight: 3)
    }
    if containsAny(["요약", "정리", "summary", "summarize"]) {
      add(["summary", "summarize", "digest"], weight: 4)
    }
    if containsAny(["라벨", "label"]) {
      add(["label"], weight: 4)
    }
    if containsAny(["답장", "회신", "reply"]) {
      add(["reply", "draft"], weight: 4)
    }

    return out
  }

  private static func intentBoost(
    queryCompact: String,
    queryTerms: [WeightedTerm],
    entry: IndexedTool
  ) -> (score: Int, matchedTerms: [String]) {
    let termSet = Set(queryTerms.map { compact($0.value) }.filter { !$0.isEmpty })
    let doc = entry.compactDocument
    let name = entry.compactName
    var score = 0
    var matched: [String] = []

    func has(_ values: [String]) -> Bool {
      values.contains { value in
        let key = compact(value)
        return queryCompact.contains(key) || termSet.contains(key)
      }
    }

    func toolHas(_ values: [String]) -> Bool {
      values.contains { value in
        let key = compact(value)
        return name.contains(key) || doc.contains(key)
      }
    }

    func boost(_ amount: Int, _ label: String) {
      score += amount
      matched.append(label)
    }

    let asksTodayFortune = has(["오늘", "today", "current"]) && has(["운세", "fortune", "daily", "saju"])
    if asksTodayFortune, toolHas(["todayfortune", "today", "fortune"]) {
      boost(36, "today-fortune intent")
    }

    let asksDefaultUserMutation =
      has(["기본", "default"]) &&
      has(["사용자", "프로필", "user", "profile"]) &&
      has(["설정", "변경", "바꿔", "set", "change", "update", "select"])
    if asksDefaultUserMutation, toolHas(["setdefault", "defaultuser", "defaultsaveduser"]) {
      boost(48, "default-user mutation intent")
    }

    let asksSavedProfileList =
      has(["저장", "saved", "registered"]) &&
      has(["목록", "리스트", "list", "browse", "view"]) &&
      has(["사용자", "프로필", "user", "profile", "사람"])
    if asksSavedProfileList, toolHas(["registeredprofiles", "savedusers", "savedprofiles", "browse", "view"]) {
      boost(34, "saved-profile-list intent")
    }

    let asksSpecificSavedProfile =
      has(["저장", "saved", "registered"]) &&
      has(["찾아", "검색", "find", "search", "lookup"]) &&
      has(["사용자", "프로필", "user", "profile", "사람"])
    if asksSpecificSavedProfile, toolHas(["findsaveduser", "saveduser", "profile"]) {
      boost(32, "saved-profile-search intent")
    }

    let asksCompatibility = has(["궁합", "관계", "상성", "compatibility", "relationship", "harmony", "match"])
    if asksCompatibility, toolHas(["compatibility", "relationship", "harmony", "match"]) {
      boost(40, "compatibility intent")
    }

    let asksMail = has(["메일", "이메일", "mail", "email"])
    if asksMail, toolHas(["mail", "email", "message", "inbox"]) {
      boost(30, "mail intent")
    }

    let asksMailSummary = asksMail && has(["요약", "정리", "summary", "summarize", "digest"])
    if asksMailSummary, toolHas(["summary", "summarize", "digest"]) {
      boost(26, "mail-summary intent")
    }

    return (score, unique(matched).prefixArray(12))
  }

  private static func uniqueWeightedTerms(_ terms: [WeightedTerm]) -> [WeightedTerm] {
    var best: [String: WeightedTerm] = [:]
    for term in terms {
      let key = compact(term.value)
      guard !key.isEmpty else { continue }
      if let existing = best[key], existing.weight >= term.weight {
        continue
      }
      best[key] = term
    }
    return best.values.sorted {
      if $0.weight != $1.weight { return $0.weight > $1.weight }
      return $0.value < $1.value
    }
  }

  private static func tokens(from text: String) -> [String] {
    normalized(text)
      .replacingOccurrences(of: "[^\\p{L}\\p{N}_-]+", with: " ", options: .regularExpression)
      .split(separator: " ")
      .map(String.init)
      .filter { $0.count >= 1 }
  }

  private static func searchTokens(from text: String) -> [String] {
    tokens(from: text)
      .map(compact)
      .filter { !$0.isEmpty }
  }

  private static func normalized(_ text: String) -> String {
    text
      .lowercased()
      .replacingOccurrences(of: "_", with: " ")
      .replacingOccurrences(of: "-", with: " ")
  }

  private static func compact(_ text: String) -> String {
    normalized(text)
      .replacingOccurrences(of: "[^\\p{L}\\p{N}]+", with: "", options: .regularExpression)
  }

  private static func unique(_ values: [String]) -> [String] {
    var seen = Set<String>()
    var out: [String] = []
    for value in values {
      let key = compact(value)
      guard !key.isEmpty, !seen.contains(key) else { continue }
      seen.insert(key)
      out.append(value)
    }
    return out
  }

  private struct WeightedTerm {
    let value: String
    let weight: Int
  }
}

private extension Array {
  func prefixArray(_ maxLength: Int) -> [Element] {
    Array(prefix(maxLength))
  }
}
