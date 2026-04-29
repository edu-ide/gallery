import Foundation

struct UgotMCPToolSearchResult {
  let tool: [String: Any]
  let score: Int
  let matchedTerms: [String]
}

/// Query expansion is intentionally outside the search index.
///
/// The index should rank MCP metadata; it should not own locale/domain
/// knowledge such as Korean -> English synonyms. Built-in apps can provide a
/// fallback lexicon here, while external MCP servers should prefer shipping
/// localized `title`/`description`/`_meta["tool/searchKeywords"]` metadata.
struct UgotMCPQueryExpansionProvider {
  let expand: (_ query: String, _ originalTokens: [String]) -> [(value: String, weight: Int)]

  static let none = UgotMCPQueryExpansionProvider { _, _ in [] }
  static let localizedFallback = UgotMCPQueryExpansionProvider { query, originalTokens in
    UgotMCPBuiltInLocaleLexicon.expand(query: query, originalTokens: originalTokens)
  }
}

private enum UgotMCPBuiltInLocaleLexicon {
  static func expand(query: String, originalTokens: [String]) -> [(value: String, weight: Int)] {
    let compactQuery = compact(query)
    let compactTokens = Set(originalTokens.map(compact).filter { !$0.isEmpty })
    var out: [(value: String, weight: Int)] = []

    func add(_ terms: [String], weight: Int = 2) {
      out.append(contentsOf: terms.map { ($0, weight) })
    }

    func containsAny(_ values: [String]) -> Bool {
      values.contains { value in
        let key = compact(value)
        return compactQuery.contains(key) || compactTokens.contains(key)
      }
    }

    if containsAny(["기본", "대표", "default"]) {
      add(["default"], weight: 4)
    }
    if containsAny(["사용자", "프로필", "사람", "타깃", "타겟", "대상", "user", "profile", "target"]) {
      add(["user", "profile", "person", "target"], weight: 3)
    }
    if containsAny(["목록", "리스트", "list"]) {
      add(["list", "browse", "view"], weight: 3)
    }
    if containsAny(["찾아", "찾기", "검색", "search", "find"]) {
      add(["find", "search", "lookup"], weight: 3)
    }
    if containsAny([
      "설정", "설정해", "설정할", "변경", "변경해", "변경할",
      "바꿔", "바꿀", "바꾸", "지정", "선택",
      "set", "change", "update", "select", "make",
    ]) {
      add(["set", "change", "update", "select"], weight: 4)
    }
    if containsAny(["삭제", "지워", "해제", "delete", "remove", "clear"]) {
      add(["delete", "remove", "clear"], weight: 4)
    }
    if containsAny(["계정", "계좌", "로그인", "연결", "연동", "접속", "인증", "account", "identity", "login", "connected", "connection", "auth"]) {
      add(["account", "identity", "login", "connected", "connection", "auth", "oauth"], weight: 4)
    }
    if containsAny(["동기화", "싱크", "sync", "synchronize"]) {
      add(["sync", "synchronize"], weight: 4)
    }
    if containsAny([
      "됨", "됐", "되었", "되어", "되어있", "되어있어", "연결됨", "연결됐", "연동됨", "연동됐",
      "status", "check", "connected", "linked", "loggedin",
    ]) {
      add(["status", "check", "connected", "connection", "list"], weight: 4)
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

  private static func compact(_ text: String) -> String {
    text
      .lowercased()
      .replacingOccurrences(of: "_", with: " ")
      .replacingOccurrences(of: "-", with: " ")
      .replacingOccurrences(of: "[^\\p{L}\\p{N}]+", with: "", options: .regularExpression)
  }
}

/// Client-side virtual MCP `tool_search`.
///
/// This follows the Codex-style idea at the mobile host boundary:
/// - keep full MCP tool schemas out of the local model prompt;
/// - index generic tool metadata locally (`name`, `description`, schema fields, annotations);
/// - retrieve a small candidate set for the current turn;
/// - let approval/execution use the actual MCP tool definition.
///
/// The index intentionally does not contain connector-specific aliases. Optional
/// query expansion is injected from `UgotMCPQueryExpansionProvider`, so external
/// connectors can rely on their own localized MCP metadata instead of client
/// hardcoding.
struct UgotMCPToolSearchIndex {
  private struct IndexedTool {
    let tool: [String: Any]
    let name: String
    let document: String
    let compactDocument: String
    let compactName: String
    let discoveryKeywords: [String]
    let explicitRequestAlternatives: [String]
    let excludedRequestAlternatives: [String]
    let requiredParameters: [String]
    let supportsSavedDefaultTarget: Bool
    let requiresConcreteTarget: Bool
    let tokenFrequencies: [String: Int]
    let tokenCount: Int
  }

  private let entries: [IndexedTool]
  private let documentFrequencies: [String: Int]
  private let averageDocumentLength: Double
  private let queryExpansionProvider: UgotMCPQueryExpansionProvider

  init(
    tools: [[String: Any]],
    sourceName: String? = nil,
    sourceDescription: String? = nil,
    queryExpansionProvider: UgotMCPQueryExpansionProvider = .localizedFallback
  ) {
    self.queryExpansionProvider = queryExpansionProvider
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
      let excludedRequestAlternatives = Self.excludedRequestAlternatives(from: document)
      let requiredParameters = Self.requiredParameters(for: tool)
      let tokens = Self.searchTokens(from: ([document] + discoveryKeywords).joined(separator: " "))
      return IndexedTool(
        tool: tool,
        name: name,
        document: document,
        compactDocument: Self.compact(document),
        compactName: Self.compact(name),
        discoveryKeywords: discoveryKeywords,
        explicitRequestAlternatives: explicitRequestAlternatives,
        excludedRequestAlternatives: excludedRequestAlternatives,
        requiredParameters: requiredParameters,
        supportsSavedDefaultTarget: Self.toolSupportsSavedDefaultTarget(tool, document: document),
        requiresConcreteTarget: Self.toolRequiresConcreteTarget(tool, document: document),
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

  func search(
    query: String,
    limit: Int = 8,
    allowIncompatiblePrimaryTools: Bool = false
  ) -> [UgotMCPToolSearchResult] {
    let scoringQuery = Self.userIntentText(from: query)
    let terms = Self.queryTerms(for: scoringQuery, expansionProvider: queryExpansionProvider)
    guard !terms.isEmpty else { return [] }

    let intent = UgotMCPToolIntent(prompt: scoringQuery)
    let queryCompact = Self.compact(scoringQuery)
    let results = entries.compactMap { entry -> UgotMCPToolSearchResult? in
      guard Self.satisfiesExplicitRequestConstraint(
        queryCompact: queryCompact,
        alternatives: entry.explicitRequestAlternatives
      ) else {
        return nil
      }
      if !entry.excludedRequestAlternatives.isEmpty,
         Self.satisfiesExplicitRequestConstraint(
           queryCompact: queryCompact,
           alternatives: entry.excludedRequestAlternatives
         ) {
        return nil
      }
      guard allowIncompatiblePrimaryTools || !intent.isIncompatiblePrimaryTool(tool: entry.tool, document: entry.document) else {
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

  func eligibleTools(query: String, allowIncompatiblePrimaryTools: Bool = false) -> [[String: Any]] {
    let scoringQuery = Self.userIntentText(from: query)
    let intent = UgotMCPToolIntent(prompt: scoringQuery)
    let queryCompact = Self.compact(scoringQuery)
    return entries.compactMap { entry in
      Self.satisfiesExplicitRequestConstraint(
        queryCompact: queryCompact,
        alternatives: entry.explicitRequestAlternatives
      ) &&
        (entry.excludedRequestAlternatives.isEmpty ||
          !Self.satisfiesExplicitRequestConstraint(
            queryCompact: queryCompact,
            alternatives: entry.excludedRequestAlternatives
          )) &&
        (allowIncompatiblePrimaryTools || !intent.isIncompatiblePrimaryTool(tool: entry.tool, document: entry.document))
        ? entry.tool
        : nil
    }
  }

  static func searchScore(
    query: String,
    document: String,
    queryExpansionProvider: UgotMCPQueryExpansionProvider = .localizedFallback
  ) -> (score: Int, matchedTerms: [String]) {
    let terms = queryTerms(for: userIntentText(from: query), expansionProvider: queryExpansionProvider)
    guard !terms.isEmpty else { return (0, []) }
    let normalizedDocument = normalized(document)
    let compactDocument = compact(document)
    return searchScore(terms: terms, normalizedDocument: normalizedDocument, compactDocument: compactDocument)
  }

  private static func userIntentText(from query: String) -> String {
    if query.contains("[MCP attachment request]"),
       let attachmentIntent = mcpAttachmentIntentText(from: query),
       !attachmentIntent.isEmpty {
      return attachmentIntent
    }
    let markers = [
      "\nprevious mcp observations:",
      "\nprevious tool observations:",
      "\nmcp observations:",
      "\ntool observations:",
      "\nobservations:",
    ]
    let lowered = query.lowercased()
    let cut = markers
      .compactMap { marker -> String.Index? in
        lowered.range(of: marker)?.lowerBound
      }
      .min()
    guard let cut else { return query }
    return String(query[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func mcpAttachmentIntentText(from query: String) -> String? {
    let lines = query.components(separatedBy: .newlines)
    var out: [String] = []
    var capturingRenderedInstruction = false

    for rawLine in lines {
      let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      let lower = line.lowercased()

      if capturingRenderedInstruction {
        if lower.hasPrefix("treat the attached artifact") ||
            lower.hasPrefix("do not expose raw mcp") ||
            lower.hasPrefix("the user attached these") {
          capturingRenderedInstruction = false
        } else if !line.isEmpty {
          out.append(line)
          continue
        }
      }

      if lower.hasPrefix("user message:") {
        let value = String(line.dropFirst("User message:".count))
          .trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty, value != "<attached prompt/resource only>" {
          out.append(value)
        }
      } else if lower.hasPrefix("- prompt:") || lower.hasPrefix("- resource:") {
        out.append(line)
      } else if lower.hasPrefix("- selected arguments:") {
        out.append(line)
      } else if lower.hasPrefix("- rendered instruction:") {
        capturingRenderedInstruction = true
      }
    }

    let text = out.joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
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

  static func requiredParameters(for tool: [String: Any]) -> [String] {
    guard let schema = tool["inputSchema"] as? [String: Any],
          let required = schema["required"] as? [String] else {
      return []
    }
    return required
  }

  /// True when a tool explicitly says omitted target/person fields can be
  /// resolved from an already saved/default profile. This is a generic
  /// capability signal derived from tool metadata, not from connector/tool
  /// names.
  static func toolSupportsSavedDefaultTarget(
    _ tool: [String: Any],
    document: String? = nil
  ) -> Bool {
    let rawDocument = document ?? Self.document(for: tool)
    let compactDocument = compact(rawDocument)
    let tokens = Set(searchTokens(from: rawDocument))

    if compactDocument.contains("defaultsavedprofile") ||
        compactDocument.contains("defaultsaveduser") ||
        compactDocument.contains("saveddefaultprofile") ||
        compactDocument.contains("saveddefaultuser") ||
        compactDocument.contains("defaulttarget") ||
        compactDocument.contains("기본사용자") ||
        compactDocument.contains("기본프로필") ||
        compactDocument.contains("대표사용자") ||
        compactDocument.contains("대표프로필") {
      return true
    }

    let hasDefault = tokens.contains("default") ||
      compactDocument.contains("기본") ||
      compactDocument.contains("대표")
    let hasSaved = tokens.contains("saved") ||
      tokens.contains("registered") ||
      compactDocument.contains("저장")
    let hasTarget = tokens.contains("profile") ||
      tokens.contains("user") ||
      tokens.contains("person") ||
      tokens.contains("target") ||
      compactDocument.contains("프로필") ||
      compactDocument.contains("사용자") ||
      compactDocument.contains("대상") ||
      compactDocument.contains("타깃") ||
      compactDocument.contains("타겟")
    let hasOmitSupport = tokens.contains("omit") ||
      tokens.contains("omitted") ||
      tokens.contains("missing") ||
      tokens.contains("prefer") ||
      compactDocument.contains("생략")

    return hasDefault && hasSaved && hasTarget && hasOmitSupport
  }

  /// True when the schema requires concrete target identity fields that the
  /// host should not fabricate from a generic request. The rule is schema-based
  /// and remains connector-agnostic: it never checks a concrete MCP tool name.
  static func toolRequiresConcreteTarget(
    _ tool: [String: Any],
    document: String? = nil
  ) -> Bool {
    let required = requiredParameters(for: tool).map(compact)
    guard !required.isEmpty else { return false }
    let targetRequiredMarkers: Set<String> = [
      "birthdate", "birthtime", "birthday",
      "gender", "sex",
      "profileid", "userid", "useridentifier",
      "saveduserid", "savedprofileid", "targetid",
      "memberbirthdate", "memberbirthtime", "membergender",
    ]
    if required.contains(where: { field in
      targetRequiredMarkers.contains(field) ||
        field.hasSuffix("profileid") ||
        field.hasSuffix("userid") ||
        field.hasSuffix("targetid") ||
        field.contains("birthdate") ||
        field.contains("birthtime")
    }) {
      return true
    }

    // If every required field is a generic query/search field, the user prompt
    // itself can usually satisfy it. Do not classify that as unresolved target
    // identity.
    let fillablePromptFields: Set<String> = [
      "q", "query", "search", "searchtext", "prompt", "text",
      "message", "date", "targetdate", "year", "limit", "lang",
      "member", "members", "names", "people",
    ]
    return !required.allSatisfy { fillablePromptFields.contains($0) }
  }

  static func queryHasConcreteTargetEvidence(_ query: String) -> Bool {
    let normalizedQuery = normalized(query)
    let compactQuery = compact(query)
    guard !compactQuery.isEmpty else { return false }

    // Schema/error labels like "birth_date", "birth_time", or "gender" are
    // not user-provided target evidence. This function should only return true
    // when the user supplied an actual concrete value such as a date/time.
    let hasCompactDate = compactQuery.range(of: #"\d{6,8}"#, options: .regularExpression) != nil
    let hasSeparatedDate = normalizedQuery.range(
      of: #"(?:19|20)\d{2}\s*(?:년|[-./])\s*\d{1,2}\s*(?:월|[-./])\s*\d{1,2}"#,
      options: .regularExpression
    ) != nil
    let hasTime = normalizedQuery.range(of: #"\b\d{1,2}:\d{2}\b"#, options: .regularExpression) != nil ||
      normalizedQuery.range(of: #"\d{1,2}\s*시"#, options: .regularExpression) != nil ||
      compactQuery.contains("오전") ||
      compactQuery.contains("오후")
    let hasGender = ["남자", "여자", "남성", "여성", "male", "female"]
      .contains { compactQuery.contains(compact($0)) }

    return hasCompactDate || hasSeparatedDate || (hasTime && hasGender)
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
      // "Do not use another tool unless the user explicitly asks for X..." is
      // guidance about that other tool, not an explicit-only constraint for the
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
      let alternatives = requestAlternatives(from: tail)
      if !alternatives.isEmpty {
        return unique(alternatives)
      }
    }
    return []
  }

  private static func excludedRequestAlternatives(from document: String) -> [String] {
    let normalizedDocument = normalized(document)
    let patterns = [
      #"do not use[^.;\n]*unless[^.;\n]*(?:explicitly\s+)?asks?\s+for\s+([^.;\n]+)"#,
      #"don't use[^.;\n]*unless[^.;\n]*(?:explicitly\s+)?asks?\s+for\s+([^.;\n]+)"#,
      #"do not use[^.;\n]*for\s+([^.;\n]+)"#,
      #"don't use[^.;\n]*for\s+([^.;\n]+)"#,
    ]
    var alternatives: [String] = []
    for pattern in patterns {
      guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
      let range = NSRange(normalizedDocument.startIndex..<normalizedDocument.endIndex, in: normalizedDocument)
      for match in regex.matches(in: normalizedDocument, range: range) where match.numberOfRanges > 1 {
        guard let captureRange = Range(match.range(at: 1), in: normalizedDocument) else { continue }
        alternatives.append(contentsOf: requestAlternatives(from: String(normalizedDocument[captureRange])))
      }
    }
    return unique(alternatives)
  }

  private static func requestAlternatives(from raw: String) -> [String] {
    let splitReady = raw
      .replacingOccurrences(of: " or ", with: ",")
      .replacingOccurrences(of: " and ", with: ",")
      .replacingOccurrences(of: " 또는 ", with: ",")
      .replacingOccurrences(of: " 혹은 ", with: ",")
      .replacingOccurrences(of: " 이나 ", with: ",")
    return splitReady
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
    // themselves.
    let genericTokens: Set<String> = [
      "a", "an", "the", "for", "of", "or", "and",
      "ask", "asks", "request", "requests", "explicitly",
    ]
    return !genericTokens.contains(token)
  }

  private static func queryTerms(
    for query: String,
    expansionProvider: UgotMCPQueryExpansionProvider
  ) -> [WeightedTerm] {
    let originalTokens = tokens(from: query)
    let original = originalTokens.map { WeightedTerm(value: $0, weight: 4) }
    let expanded = expansionProvider
      .expand(query, originalTokens)
      .map { WeightedTerm(value: $0.value, weight: $0.weight) }
    return uniqueWeightedTerms(original + expanded)
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

    func toolIdentityHas(_ values: [String]) -> Bool {
      let keywordDocument = compact(entry.discoveryKeywords.joined(separator: " "))
      return values.contains { value in
        let key = compact(value)
        return name.contains(key) || keywordDocument.contains(key)
      }
    }

    func toolIsReadOnly() -> Bool {
      if let annotations = entry.tool["annotations"] as? [String: Any],
         let raw = annotations["readOnlyHint"] {
        if let readOnly = raw as? Bool { return readOnly }
        if let number = raw as? NSNumber { return number.boolValue }
        if let string = raw as? String { return string.lowercased() == "true" }
      }
      let markers = ["show", "get", "list", "find", "search", "view", "read", "fetch", "summarize", "summary", "analyze", "analyse", "lookup"]
      return markers.contains { marker in name.contains(marker) || name.hasPrefix(marker) }
    }

    func boost(_ amount: Int, _ label: String) {
      score += amount
      matched.append(label)
    }

    let asksMutation =
      has([
        "설정", "설정해", "설정할", "변경", "변경해", "변경할",
        "바꿔", "바꿀", "바꾸", "지정", "선택", "등록", "삭제", "보내", "전송", "연동",
        "set", "change", "update", "select", "make", "create", "add", "delete", "remove",
        "send", "sync", "synchronize",
      ])
    if asksMutation {
      if toolIsReadOnly() {
        score -= 24
        matched.append("read-only tool for mutation-like request")
      } else {
        boost(18, "mutation-capable tool")
      }
    }

    let asksAccountConnection = has(["계정", "로그인", "연결", "연동", "접속", "인증", "account", "identity", "login", "connected", "connection", "auth"])
    let asksAccountStatus = asksAccountConnection &&
      has([
        "됨", "됐", "되었", "되어", "되어있", "되어있어",
        "status", "check", "connected", "linked", "loggedin",
      ])
    if asksAccountStatus {
      if toolIsReadOnly(),
         toolHas(["account", "identity", "login", "connected", "connection", "auth", "status", "list"]) {
        boost(74, "account-status-check intent")
      } else if !toolIsReadOnly() || toolHas(["sync", "synchronize", "save", "oauth"]) {
        score -= 92
        matched.append("not account status check tool")
      }
    }

    let asksSummary = has(["요약", "정리", "summary", "summarize", "digest"])
    if asksSummary, toolHas(["summary", "summarize", "digest"]) {
      boost(22, "summary intent")
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

/// Turn-level semantic gate for MCP tool retrieval/planning.
///
/// Codex does not let a raw metadata search result execute a tool by itself:
/// the model emits an explicit tool call, then the host validates policy,
/// approval, and execution. The mobile client still uses a local search index
/// to keep prompts small, so this gate prevents the search/projection layer
/// from offering tools that are semantically invalid for the user's requested
/// action.
///
/// This must stay connector-agnostic: no connector-specific tool names,
/// examples, or server-specific aliases. Connector-specific meaning belongs in
/// MCP tool metadata (`name`, `title`, `description`, `inputSchema`,
/// annotations, `_meta` search fields). The host may infer broad semantics such
/// as "read-only" vs "state-changing", but it must not special-case one
/// connector's concrete tool names.
struct UgotMCPToolIntent {
  private let rawPrompt: String
  private let compactPrompt: String

  init(prompt: String) {
    self.rawPrompt = prompt
    self.compactPrompt = Self.compact(prompt)
  }

  var isDefaultUserMutation: Bool {
    false
  }

  var requiresStateChangingTool: Bool {
    requiresPlannerBeforeToolExecution
  }

  /// True when this turn asks to mutate connector state. In this mode a
  /// read-only metadata hit must not execute as a fallback; the request must go
  /// through explicit model planning and approval, or fail closed.
  var requiresPlannerBeforeToolExecution: Bool {
    if hasExplicitReadOnlyDirective {
      return false
    }
    return hasStateChangingVerb && hasPotentialToolStateObject
  }

  /// True when the user is asking to inspect/list/show/summarize information.
  /// For these turns, non-read-only tools are not just lower ranked; they are
  /// semantically invalid and must be excluded before model planning and again
  /// during host validation.
  var prefersReadOnlyTool: Bool {
    hasExplicitReadOnlyDirective || (hasReadOnlyLookupIntent && !hasStateChangingVerb)
  }

  func isPreferredPrimaryTool(tool: [String: Any], document: String? = nil) -> Bool {
    return true
  }

  func isIncompatiblePrimaryTool(tool: [String: Any], document: String? = nil) -> Bool {
    let rawDocument = document ?? UgotMCPToolSearchIndex.document(for: tool)
    if Self.isReadOnly(tool: tool),
       !UgotMCPToolSearchIndex.queryHasConcreteTargetEvidence(compactPrompt),
       UgotMCPToolSearchIndex.toolRequiresConcreteTarget(tool, document: rawDocument),
       !UgotMCPToolSearchIndex.toolSupportsSavedDefaultTarget(tool, document: rawDocument) {
      return true
    }

    if prefersReadOnlyTool {
      return !Self.isReadOnly(tool: tool)
    }

    if requiresPlannerBeforeToolExecution, Self.isReadOnly(tool: tool) {
      return true
    }

    return false
  }

  private var hasMutationVerb: Bool {
    hasAny([
      "설정", "설정해", "설정할", "변경", "변경해", "변경할",
      "바꿔", "바꿀", "바꾸", "지정", "선택",
    ]) || hasAnyToken(["set", "change", "update", "select", "make"])
  }

  private var hasStateChangingVerb: Bool {
    if hasConnectionStatusQuestion || hasExplicitReadOnlyDirective {
      return false
    }
    return hasMutationVerb ||
      hasAny([
        "등록", "삭제", "지워", "해제", "초기화", "보내", "보내줘", "전송", "답장", "회신",
        "동기화", "싱크", "연동",
      ]) ||
      hasAnyToken([
        "create", "add", "register", "delete", "remove", "clear", "reset", "send", "reply",
        "sync", "synchronize",
      ]) ||
      (hasAny(["저장", "save"]) && !hasReadOnlyLookupIntent)
  }

  private var hasReadOnlyLookupIntent: Bool {
    hasAny([
      "저장목록", "저장된목록", "목록", "리스트", "조회", "보여", "보여줘", "보여주세요",
      "알려", "알려줘", "알려주세요", "읽어", "요약", "정리", "최근", "최신",
      "어때", "뭐야", "보기", "분석", "설명", "평가", "됨", "됐", "되어", "되어있",
      "list", "browse", "view", "show", "read", "summary", "summarize", "recent", "latest",
      "what", "how", "explain", "analyze", "status", "check",
    ])
  }

  private var hasConnectionStatusQuestion: Bool {
    hasAny(["계정", "로그인", "연동", "연결", "인증", "account", "identity", "login", "auth", "oauth"]) &&
      hasAny([
        "됨", "됐", "되었", "되어", "되어있", "되어있어",
        "status", "check", "connected", "linked", "loggedin",
      ])
  }

  private var hasExplicitReadOnlyDirective: Bool {
    let lowered = rawPrompt.lowercased()
    return lowered.contains("intent effect: read-only") ||
      lowered.contains("intent-effect: read-only") ||
      lowered.contains("read-only mcp") ||
      lowered.contains("do not mutate connector state")
  }

  private var hasPotentialToolStateObject: Bool {
    hasAny([
      "설정", "환경설정", "승인", "권한", "도구", "커넥터", "connector", "tool",
      "라벨", "계정", "로그인", "인증", "연동",
      "label", "draft", "account", "identity", "login", "auth", "oauth",
      "프로필", "사용자", "유저", "타깃", "타겟", "대상",
      "settings", "preference", "approval", "permission",
    ])
  }

  private func hasAny(_ values: [String]) -> Bool {
    values.contains { value in
      let key = Self.compact(value)
      return !key.isEmpty && compactPrompt.contains(key)
    }
  }

  private func hasAnyToken(_ values: [String]) -> Bool {
    let promptTokens = Set(Self.tokens(from: rawPrompt))
    return values.contains { value in
      promptTokens.contains(value.lowercased())
    }
  }

  private static func isReadOnly(tool: [String: Any]) -> Bool {
    if let annotations = tool["annotations"] as? [String: Any],
       let raw = annotations["readOnlyHint"] {
      if let readOnly = raw as? Bool { return readOnly }
      if let number = raw as? NSNumber { return number.boolValue }
      if let string = raw as? String { return string.lowercased() == "true" }
    }
    return inferredReadOnlyFromToolName(tool)
  }

  private static func inferredReadOnlyFromToolName(_ tool: [String: Any]) -> Bool {
    let name = ((tool["name"] as? String) ?? "")
      .lowercased()
      .replacingOccurrences(of: "-", with: "_")
    guard !name.isEmpty else { return false }
    let mutatingNameMarkers = [
      "set_", "save_", "create_", "register_", "update_", "delete_", "remove_",
      "clear_", "reset_", "send_", "move_", "import_", "upload_", "write_", "edit_",
      "apply_", "commit_", "cancel_"
    ]
    if mutatingNameMarkers.contains(where: { name.contains($0) || name.hasPrefix(String($0.dropLast())) }) {
      return false
    }
    let readNameMarkers = [
      "show_", "get_", "list_", "find_", "search_", "view_", "read_", "fetch_",
      "summarize_", "summary_", "analyze_", "analyse_", "lookup_"
    ]
    return readNameMarkers.contains { name.contains($0) || name.hasPrefix(String($0.dropLast())) }
  }

  private static func compact(_ text: String) -> String {
    text
      .lowercased()
      .replacingOccurrences(of: "_", with: " ")
      .replacingOccurrences(of: "-", with: " ")
      .replacingOccurrences(of: "[^\\p{L}\\p{N}]+", with: "", options: .regularExpression)
  }

  private static func tokens(from text: String) -> [String] {
    text
      .lowercased()
      .replacingOccurrences(of: "_", with: " ")
      .replacingOccurrences(of: "-", with: " ")
      .replacingOccurrences(of: "[^\\p{L}\\p{N}]+", with: " ", options: .regularExpression)
      .split(separator: " ")
      .map(String.init)
      .filter { !$0.isEmpty }
  }
}

private extension Array {
  func prefixArray(_ maxLength: Int) -> [Element] {
    Array(prefix(maxLength))
  }
}
