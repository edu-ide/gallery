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
        name: "show_saju_interpretation",
        title: "Saju Interpretation",
        description: "Provides detailed text interpretation of the selected Saju natal chart. Use this for chart explanation prompts and saved-profile chart interpretation.",
        keywords: ["saju interpretation", "chart explanation", "saju chart", "사주 해석", "사주 설명", "사주 차트", "현재 사주 차트 설명"],
        required: []
      ),
      tool(
        name: "show_saju_chart",
        title: "Saju Natal Chart",
        description: "Displays the Saju natal chart surface for the selected profile.",
        keywords: ["saju chart", "natal chart", "manse", "사주 차트", "명식", "만세력"],
        required: []
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
        keywords: ["기본 사용자", "기본 유저", "기본 타깃", "대표 사용자", "설정", "변경", "바꾸기", "default user", "default target", "set default"],
        required: ["saved_user_id"],
        readOnly: false
      ),
      tool(
        name: "clear_default_user",
        title: "Clear Default Saved User",
        description: "Clear the current default saved user.",
        keywords: [],
        required: [],
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
      tool(
        name: "list_accounts",
        title: "List Mail Accounts",
        description: "List embedded mail accounts available on this device. Use to check whether a mail account is connected, logged in, authenticated, or available.",
        keywords: ["mail", "email", "account", "identity", "login", "connected", "connection", "auth", "메일", "계정", "연결", "로그인"],
        required: []
      ),
      tool(
        name: "sync_oauth_account",
        title: "Sync OAuth Account",
        description: "Save or synchronize an OAuth mail account into the embedded device mail account store.",
        keywords: ["mail", "email", "account", "oauth", "sync", "synchronize", "save", "메일", "계정", "동기화", "연동", "저장"],
        required: ["email", "access_token", "refresh_token"],
        readOnly: false
      ),
      tool(
        name: "list_emails",
        title: "List Emails",
        description: "List recent emails from the embedded mail backend.",
        keywords: ["mail", "email", "inbox", "message", "recent", "latest", "메일", "최근메일", "받은메일"],
        required: []
      ),
    ]

    let index = UgotMCPToolSearchIndex(tools: tools)
    assertTop(index, query: "오늘의 운세 알려줘", expected: "show_today_fortune")
    assertTop(index, query: "띠별 운세 알려줘", expected: "show_zodiac_horoscope")
    assertTop(index, query: "기본 사용자를 Yw로 바꿔", expected: "set_default_user", minimumScore: 36)
    assertTop(index, query: "기본 유저를 sk로 바꿔", expected: "set_default_user", minimumScore: 36)
    assertTop(index, query: "기본 사용자를 Yw 로 바꿀수 있어", expected: "set_default_user", minimumScore: 36)
    assertTop(index, query: "기본 유저 sk 로 지정해", expected: "set_default_user", minimumScore: 36)
    assertTop(index, query: "기본 타깃을 Yw로 바꿔봐", expected: "set_default_user", minimumScore: 36)
    assertNotContains(index, query: "기본 사용자를 Yw 로 바꿀수 있어", unexpected: "show_today_fortune")
    assertNotContains(index, query: "기본 유저를 sk로 바꿔", unexpected: "show_today_fortune")
    assertNotContains(index, query: "기본 타깃을 Yw로 바꿔봐", unexpected: "show_today_fortune")
    assertNotContains(index, query: "기본사용자를 yw로 바꿔", unexpected: "list_emails")
    assertNotContains(index, query: "기본사용자를 yw로 바꿔", unexpected: "list_accounts")
    assertTop(index, query: "저장목록 보여줘", expected: "view_registered_profiles")
    assertNotContains(index, query: "저장목록", unexpected: "clear_default_user")
    assertTop(index, query: "David랑 Yw 궁합 어때", expected: "show_group_compatibility")
    assertNotContains(index, query: "David랑 Yw 궁합 어때", unexpected: "clear_default_user")
    let selectedPromptQuery = """
    [MCP attachment request]
    Intent effect: read-only explanation.
    User message: 어때 보여

    The user attached these MCP prompt/resource artifacts as the request:
    - Prompt: 현재 사주 차트 설명 (UGOT Fortune)
      - id: mcp-prompt:explain-current-saju
      - selected arguments: language=ko, target_name=David
      - rendered instruction:
    David의 현재 사주 차트를 설명하세요.
    birth_date=1988-11-23
    birth_time=14:00
    gender=male
    name=David
    이 요청은 오늘의 운세가 아니라 선택 대상의 사주 차트/해석 설명입니다.
    """
    assertTop(index, query: selectedPromptQuery, expected: "show_saju_interpretation")
    assertNotContains(index, query: selectedPromptQuery, unexpected: "show_today_fortune")
    assertTop(index, query: "최근 메일 요약해줘", expected: "summarize_recent_mail")
    assertTop(index, query: "메일 계정 연결되어 있냐", expected: "list_accounts")
    assertTop(index, query: "메일 로그인 되어 있어?", expected: "list_accounts")
    assertTop(index, query: "메일 계정 동기화해줘", expected: "sync_oauth_account")
    assertTop(index, query: "계정 연결되어있음", expected: "list_accounts")
    assertTop(index, query: "계정 연결되어 있음", expected: "list_accounts")
    assertTop(index, query: "계정 연동 됨?", expected: "list_accounts")
    assertTop(index, query: "메일 계정 연동 됨?", expected: "list_accounts")
    assertNotContains(index, query: "계정 연동 됨?", unexpected: "sync_oauth_account")

    let noAnnotationIndex = UgotMCPToolSearchIndex(tools: [
      tool(
        name: "show_today_fortune",
        title: "Today's Fortune",
        description: "Use this for generic requests like today's fortune.",
        keywords: ["fortune", "today", "오늘", "운세"],
        required: [],
        includeAnnotations: false
      ),
      tool(
        name: "set_default_user",
        title: "Set Default Saved User",
        description: "Set the default saved user.",
        keywords: [],
        required: ["saved_user_id"],
        readOnly: false,
        includeAnnotations: false
      ),
    ])
    assertTop(noAnnotationIndex, query: "오늘의 운세 알려줘", expected: "show_today_fortune")
    assertNotContains(noAnnotationIndex, query: "오늘의 운세 알려줘", unexpected: "set_default_user")

    let fastMcpStyleIndex = UgotMCPToolSearchIndex(tools: [
      tool(
        name: "show_today_fortune",
        title: "Today's Fortune",
        description: "Shows a person's fortune for today. Use this for generic requests like today's fortune, my fortune today, or a saved person's fortune today. It should prefer the user's default saved profile when explicit birth data is missing.",
        keywords: ["오늘의 운세", "오늘 운세", "오늘", "운세", "today fortune", "fortune today"],
        required: [],
        includeAnnotations: false
      ),
      tool(
        name: "show_saju_daily",
        title: "Daily Fortune Surface",
        description: "Displays the full personal daily fortune surface for a specific person. Use this when birth data or a concrete saved person target is already known. For ambiguous generic requests like today's fortune, use show_today_fortune first.",
        keywords: ["일진", "개인 일일 운세", "daily fortune"],
        required: ["birth_date", "birth_time", "gender"],
        includeAnnotations: false
      ),
    ])
    assertTop(fastMcpStyleIndex, query: "오늘의 운세 알려줘", expected: "show_today_fortune")
    let contaminatedRetryQuery = """
    오늘의 운세 알려줘

    Previous MCP observations:
    show_saju_daily status=missing_arguments output=Daily Fortune 도구를 실행하려면 birth_date, birth_time, gender 값이 더 필요해요.
    """
    assertTop(fastMcpStyleIndex, query: contaminatedRetryQuery, expected: "show_today_fortune")
    assertNotContains(fastMcpStyleIndex, query: contaminatedRetryQuery, unexpected: "show_saju_daily")
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

  private static func assertNotContains(
    _ index: UgotMCPToolSearchIndex,
    query: String,
    unexpected: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let results = index.search(query: query, limit: 8)
    let names = results.compactMap { $0.tool["name"] as? String }
    guard !names.contains(unexpected) else {
      fputs("FAIL \(query): did not expect \(unexpected), got \(names)\n", stderr)
      exit(1)
    }
    print("PASS \(query): excludes \(unexpected)")
  }

  private static func tool(
    name: String,
    title: String,
    description: String,
    keywords: [String],
    required: [String],
    readOnly: Bool = true,
    includeAnnotations: Bool = true
  ) -> [String: Any] {
    var properties: [String: Any] = [:]
    for key in required {
      properties[key] = ["type": "string", "description": key]
    }
    var result: [String: Any] = [
      "name": name,
      "title": title,
      "description": description,
      "inputSchema": [
        "type": "object",
        "required": required,
        "properties": properties,
      ],
      "_meta": ["tool/searchKeywords": keywords],
    ]
    if includeAnnotations {
      result["annotations"] = ["readOnlyHint": readOnly]
    }
    return result
  }
}
