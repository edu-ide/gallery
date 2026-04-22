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
/// The index intentionally does not contain connector-specific aliases or
/// language-specific keyword tables. Any natural-language query rewriting should
/// happen before this layer; this type only ranks metadata against the supplied
/// query terms.
struct UgotMCPToolSearchIndex {
  private let tools: [[String: Any]]

  init(tools: [[String: Any]]) {
    self.tools = tools
  }

  func search(query: String, limit: Int = 8) -> [UgotMCPToolSearchResult] {
    let terms = Self.queryTerms(for: query)
    guard !terms.isEmpty else { return [] }

    let queryCompact = Self.compact(query)
    let allowsMutation = Self.queryImpliesMutation(query)

    let results = tools.compactMap { tool -> UgotMCPToolSearchResult? in
      guard let name = tool["name"] as? String, !name.isEmpty else { return nil }
      let document = Self.document(for: tool)
      let compactDocument = Self.compact(document)
      let compactName = Self.compact(name)
      var score = 0
      var matched: [String] = []

      if !queryCompact.isEmpty, !compactName.isEmpty, queryCompact.contains(compactName) {
        score += 28
        matched.append(name)
      }

      for term in terms {
        let normalized = Self.normalized(term.value)
        let compact = Self.compact(term.value)
        guard !normalized.isEmpty || !compact.isEmpty else { continue }

        let didMatch =
          (!normalized.isEmpty && document.contains(normalized)) ||
          (!compact.isEmpty && compactDocument.contains(compact))
        guard didMatch else { continue }

        score += term.weight
        matched.append(term.value)
      }

      if Self.toolImpliesMutation(tool), !allowsMutation {
        score -= 18
      }
      if Self.toolImpliesDestructiveMutation(tool), !Self.queryImpliesDestructiveMutation(query) {
        score -= 80
      }

      guard score > 0 else { return nil }
      return UgotMCPToolSearchResult(
        tool: tool,
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
    for (key, value) in dict {
      parts.append(key)
      if let string = value as? String {
        parts.append(string)
      } else if let bool = value as? Bool {
        parts.append(bool ? "true" : "false")
      } else if let number = value as? NSNumber {
        parts.append(number.stringValue)
      }
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

  private static func queryTerms(for query: String) -> [WeightedTerm] {
    uniqueWeightedTerms(tokens(from: query).map { WeightedTerm(value: $0, weight: 4) })
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

  private static func containsAny(_ text: String, _ terms: [String]) -> Bool {
    terms.contains { text.contains($0) }
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

  private static func queryImpliesMutation(_ query: String) -> Bool {
    containsAny(compact(query), ["save", "set", "update", "change", "select", "create", "configure", "clear", "delete", "remove", "reset", "unset"])
  }

  private static func queryImpliesDestructiveMutation(_ query: String) -> Bool {
    containsAny(compact(query), ["clear", "delete", "remove", "reset", "unset"])
  }

  private static func toolImpliesMutation(_ tool: [String: Any]) -> Bool {
    let document = document(for: tool)
    return containsAny(document, ["save", "set", "update", "create", "delete", "remove", "clear", "reset", "preference", "default"])
  }

  private static func toolImpliesDestructiveMutation(_ tool: [String: Any]) -> Bool {
    if let annotations = tool["annotations"] as? [String: Any],
       let destructive = annotations["destructiveHint"] as? Bool {
      return destructive
    }
    let document = document(for: tool)
    return containsAny(document, ["delete", "remove", "clear", "reset", "unset"])
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
