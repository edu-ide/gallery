import Foundation

@main
struct ToolSearchSmoke {
  static func main() {
    let tools: [[String: Any]] = [
      tool(
        name: "show_today_fortune",
        title: "Today's Fortune",
        description: "Use this for generic requests like today's fortune, my fortune today, or a saved person's fortune today. Do not use zodiac unless the user explicitly asks for 띠별 or 12-sign fortune.",
        keywords: ["fortune", "today", "daily", "current", "saju", "오늘", "오늘운세", "오늘 운세", "운세", "일진", "사주", "내 운세"],
        required: []
      ),
      tool(
        name: "show_saju_daily",
        title: "Daily Fortune Surface (Iljin)",
        description: "Use this only when birth data, my daily fortune target, or a concrete saved person target is already known. For ambiguous generic requests like today's fortune, use show_today_fortune first. Do not use show_zodiac_horoscope for person-targeted daily fortune.",
        keywords: ["daily", "fortune", "iljin"],
        required: ["birth_date", "birth_time", "gender"]
      ),
      tool(
        name: "get_saju_advice_context",
        title: "Saju Advice Context",
        description: "Return a compact today-fortune advice context with natal chart cues and current flow summaries for model-side reasoning only.",
        keywords: ["today", "fortune", "daily", "saju", "context", "advice"],
        required: []
      ),
      tool(
        name: "show_zodiac_horoscope",
        title: "Zodiac Horoscope",
        description: "Only use this when the user explicitly asks for 띠별 운세, zodiac fortune, or a 12-sign horoscope. Do not use it for generic requests like today's fortune or for a specific person's daily fortune.",
        keywords: ["zodiac", "띠별", "12-sign", "horoscope"],
        required: []
      ),
      tool(
        name: "set_default_user",
        title: "Set Default Saved User",
        description: "Set the default saved user used when future generic fortune requests omit a target.",
        keywords: [],
        required: ["saved_user_id"],
        readOnly: false
      ),
      tool(
        name: "find_saved_user",
        title: "Find Saved User",
        description: "Find a saved user quickly by name and return the best match plus nearby matches. Use this only when the user references a specific saved profile by name.",
        keywords: [],
        required: ["search"]
      ),
      tool(
        name: "view_registered_profiles",
        title: "Saved Profiles",
        description: "Displays the interactive saved profiles widget. Call this once to open the saved profiles list.",
        keywords: ["saved", "registered", "profiles", "list"],
        required: []
      ),
      tool(
        name: "show_group_compatibility",
        title: "Group & Couple Compatibility",
        description: "Analyzes relationship chemistry and harmony. Use this for compatibility, relationship, couple, harmony, group, match, 궁합, 관계.",
        keywords: ["compatibility", "relationship", "궁합", "관계"],
        required: ["members"]
      ),
      tool(
        name: "summarize_recent_mail",
        title: "Recent Mail Summary",
        description: "Search recent mail email inbox messages and summarize them.",
        keywords: ["mail", "email", "recent", "summary", "summarize", "inbox", "메일", "최근", "요약"],
        required: []
      ),
    ]

    let index = UgotMCPToolSearchIndex(tools: tools)
    assertTop(index, query: "오늘의 운세 알려줘", expected: "show_today_fortune")
    assertTop(index, query: "띠별 운세 알려줘", expected: "show_zodiac_horoscope")
    assertTop(index, query: "기본 사용자를 Yw로 바꿔", expected: "set_default_user", minimumScore: 36)
    assertTop(index, query: "저장목록 보여줘", expected: "view_registered_profiles")
    assertTop(index, query: "David랑 Yw 궁합 어때", expected: "show_group_compatibility")
    assertTop(index, query: "최근 메일 요약해줘", expected: "summarize_recent_mail")
    print("tool_search_smoke: ok")
  }

  private static func assertTop(
    _ index: UgotMCPToolSearchIndex,
    query: String,
    expected: String,
    minimumScore: Int = 1,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let results = index.search(query: query, limit: 4)
    let rendered = results.map { "\(($0.tool["name"] as? String) ?? "?")=\($0.score)" }.joined(separator: ", ")
    guard let first = results.first,
          let name = first.tool["name"] as? String,
          name == expected,
          first.score >= minimumScore else {
      fputs("FAIL \(query): expected \(expected) score>=\(minimumScore), got [\(rendered)]\n", stderr)
      exit(1)
    }
    print("PASS \(query): \(rendered)")
  }

  private static func tool(
    name: String,
    title: String,
    description: String,
    keywords: [String],
    required: [String],
    readOnly: Bool = true
  ) -> [String: Any] {
    var properties: [String: Any] = [:]
    for key in required {
      properties[key] = ["type": "string", "description": key]
    }
    return [
      "name": name,
      "title": title,
      "description": description,
      "inputSchema": [
        "type": "object",
        "required": required,
        "properties": properties,
      ],
      "annotations": ["readOnlyHint": readOnly],
      "_meta": ["tool/searchKeywords": keywords],
    ]
  }
}
