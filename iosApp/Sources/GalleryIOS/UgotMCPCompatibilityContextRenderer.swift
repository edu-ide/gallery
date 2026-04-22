import Foundation

enum UgotMCPCompatibilityContextRenderer {
  static func markdown(from value: Any) -> String? {
    guard let group = groupResult(from: value) else { return nil }

    let members = memberNames(from: group)
    let memberNameById = memberNameMap(from: group)
    let score = intValue(group["groupScore"] ?? group["group_score"] ?? group["score"])
    let summary = stringValue(group["summary"])
    let pairRelations = arrayValue(group["pairRelations"] ?? group["pair_relations"])
    let strengths = stringArray(group["strengths"])
    let weaknesses = stringArray(group["weaknesses"])
    let balance = dictionaryValue(group["ohaengBalance"] ?? group["ohaeng_balance"])

    var lines: [String] = []
    lines.append("Current compatibility analysis details. Use these facts for relationship follow-up questions; do not merely restate that a result exists.")
    if !members.isEmpty {
      lines.append("- Members: \(members.joined(separator: ", "))")
    }
    if let score {
      lines.append("- Overall compatibility score: \(score)/100")
    }
    if let summary, !summary.isEmpty {
      lines.append("- Summary: \(summary)")
    }

    let pairLines = pairRelations.prefix(6).compactMap { item -> String? in
      guard let pair = item as? [String: Any] else { return nil }
      let leftId = stringValue(pair["member1Id"] ?? pair["member1_id"])
      let rightId = stringValue(pair["member2Id"] ?? pair["member2_id"])
      let left = leftId.flatMap { memberNameById[$0] } ?? leftId ?? stringValue(pair["member1Name"] ?? pair["member1_name"]) ?? "Member 1"
      let right = rightId.flatMap { memberNameById[$0] } ?? rightId ?? stringValue(pair["member2Name"] ?? pair["member2_name"]) ?? "Member 2"
      let pairScore = intValue(pair["score"])
      let relationType = stringValue(pair["relationType"] ?? pair["relation_type"])
      let relationDetail = stringValue(pair["relationDetail"] ?? pair["relation_detail"])
      let description = stringValue(pair["description"] ?? pair["advice"])

      var parts = ["\(left) ↔ \(right)"]
      if let pairScore { parts.append("\(pairScore)/100") }
      if let relationType, !relationType.isEmpty { parts.append(relationType) }
      if let relationDetail, !relationDetail.isEmpty { parts.append(relationDetail) }
      if let description, !description.isEmpty { parts.append(description) }
      return "  - " + parts.joined(separator: " · ")
    }
    if !pairLines.isEmpty {
      lines.append("- Pair details:\n" + pairLines.joined(separator: "\n"))
    }

    if !strengths.isEmpty {
      lines.append("- Strengths: \(strengths.prefix(5).joined(separator: "; "))")
    }
    if !weaknesses.isEmpty {
      lines.append("- Cautions: \(weaknesses.prefix(5).joined(separator: "; "))")
    }
    if let balance, !balance.isEmpty {
      let rendered = balance
        .sorted { $0.key < $1.key }
        .map { key, value in "\(key) \(String(describing: value))" }
        .joined(separator: ", ")
      if !rendered.isEmpty {
        lines.append("- Five-element balance: \(rendered)")
      }
    }

    return lines.joined(separator: "\n")
  }

  static func groupResult(from value: Any) -> [String: Any]? {
    if let array = value as? [Any] {
      return array.compactMap(groupResult).first
    }
    guard let dict = value as? [String: Any] else { return nil }

    if hasGroupResultShape(dict) {
      return dict
    }

    for key in [
      "groupResult",
      "group_result",
      "groupAnalysis",
      "group_analysis",
      "compatibilityResult",
      "compatibility_result",
      "structuredContent",
      "structured_content",
      "result",
      "data"
    ] {
      if let nested = dict[key], let result = groupResult(from: nested) {
        return result
      }
    }
    return nil
  }

  private static func hasGroupResultShape(_ dict: [String: Any]) -> Bool {
    dict["groupScore"] != nil ||
      dict["group_score"] != nil ||
      dict["pairRelations"] != nil ||
      dict["pair_relations"] != nil ||
      dict["members"] != nil
  }

  private static func memberNames(from group: [String: Any]) -> [String] {
    arrayValue(group["members"])
      .compactMap { item -> String? in
        guard let dict = item as? [String: Any] else { return stringValue(item) }
        return stringValue(dict["name"])
      }
      .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  }

  private static func memberNameMap(from group: [String: Any]) -> [String: String] {
    var map: [String: String] = [:]
    for item in arrayValue(group["members"]) {
      guard let dict = item as? [String: Any],
            let id = stringValue(dict["id"] ?? dict["_id"]),
            let name = stringValue(dict["name"]),
            !name.isEmpty else { continue }
      map[id] = name
    }
    return map
  }

  private static func arrayValue(_ value: Any?) -> [Any] {
    value as? [Any] ?? []
  }

  private static func dictionaryValue(_ value: Any?) -> [String: Any]? {
    value as? [String: Any]
  }

  private static func stringArray(_ value: Any?) -> [String] {
    arrayValue(value).compactMap { stringValue($0) }.filter { !$0.isEmpty }
  }

  private static func stringValue(_ value: Any?) -> String? {
    if let string = value as? String {
      let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    if let number = value as? NSNumber { return number.stringValue }
    return nil
  }

  private static func intValue(_ value: Any?) -> Int? {
    if let int = value as? Int { return int }
    if let number = value as? NSNumber { return number.intValue }
    if let string = value as? String { return Int(string.trimmingCharacters(in: .whitespacesAndNewlines)) }
    return nil
  }
}
