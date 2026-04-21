import Foundation
import GallerySharedCore

enum GalleryFortuneActionRunner {
  static func runIfNeeded(
    prompt: String,
    activeSkillIds: Set<String>,
    activeConnectorIds: Set<String>
  ) async -> GalleryChatActionResult? {
    guard isFortuneRequest(prompt) else { return nil }

    guard activeSkillIds.contains(GalleryAgentSkill.fortuneId) else {
      return GalleryChatActionResult(message: "Fortune skill을 켜면 오늘의 운세를 볼 수 있어요.")
    }
    guard activeConnectorIds.contains(GalleryConnector.fortuneMcpId) else {
      return GalleryChatActionResult(message: "Fortune connector를 켜면 오늘의 운세를 볼 수 있어요.")
    }
    guard let accessToken = UgotAuthStore.accessToken() else {
      return GalleryChatActionResult(message: "Fortune MCP를 사용하려면 UGOT 로그인이 필요해요.")
    }

    do {
      let client = GalleryFortuneMCPClient(accessToken: accessToken)
      let response = try await client.fetchTodayFortune()
      return GalleryChatActionResult(message: response.message, widgetSnapshot: response.snapshot)
    } catch {
      return GalleryChatActionResult(message: "Fortune MCP 호출에 실패했어요.\n\n\(error.localizedDescription)")
    }
  }

  private static func isFortuneRequest(_ prompt: String) -> Bool {
    let normalized = prompt
      .lowercased()
      .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
    return normalized.contains("운세") ||
      normalized.contains("사주") ||
      normalized.contains("fortune") ||
      normalized.contains("horoscope")
  }
}

struct GalleryFortuneMCPResponse {
  let message: String
  let snapshot: McpWidgetSnapshot
}

final class GalleryFortuneMCPClient {
  private static let defaultEndpoint = URL(string: GalleryConnector.fortuneMcpEndpoint)!
  private let endpoint: URL
  private let accessToken: String
  private let mcpClient: GalleryMCPExtAppsClient
  private var sessionId: String?
  private var nextId = 1

  init(accessToken: String) {
    let endpoint = Self.defaultEndpoint
    self.endpoint = endpoint
    self.accessToken = accessToken
    self.mcpClient = GalleryMCPExtAppsClient(
      connectorId: GalleryConnector.fortuneMcpId,
      endpoint: endpoint,
      accessToken: accessToken
    )
  }

  func fetchTodayFortune() async throws -> GalleryFortuneMCPResponse {
    try await mcpClient.initialize()
    let tools = try await mcpClient.listTools()
    let toolName = pickTodayFortuneTool(from: tools)
    let arguments: [String: Any] = [
      "lang": "ko",
      "target_date": todayString(),
    ]
    let result = try await mcpClient.callTool(name: toolName, arguments: arguments)
    let widgetResource =
      (try? await mcpClient.resolveWidgetResource(tools: tools, toolName: toolName, result: result)) ??
      widgetResource(fromToolResult: result)
    let message = renderToolResult(result, toolName: toolName)
    return GalleryFortuneMCPResponse(
      message: message,
      snapshot: makeSnapshot(toolName: toolName, message: message, result: result, widgetResource: widgetResource, tools: tools)
    )
  }

  func callToolForWidget(name: String, arguments: [String: Any]) async throws -> [String: Any] {
    try await mcpClient.callTool(name: name, arguments: arguments)
  }

  private func initialize() async throws {
    _ = try await send(
      payload: [
        "jsonrpc": "2.0",
        "id": nextRequestId(),
        "method": "initialize",
        "params": [
          "protocolVersion": "2025-03-26",
          "capabilities": [:],
          "clientInfo": [
            "name": "ugot-gallery-ios",
            "version": "0.1",
          ],
        ],
      ],
      expectsResponse: true
    )

    _ = try? await send(
      payload: [
        "jsonrpc": "2.0",
        "method": "notifications/initialized",
        "params": [:],
      ],
      expectsResponse: false
    )
  }

  private func listTools() async throws -> [[String: Any]] {
    let response = try await send(
      payload: [
        "jsonrpc": "2.0",
        "id": nextRequestId(),
        "method": "tools/list",
        "params": [:],
      ],
      expectsResponse: true
    )
    guard let result = response?["result"] as? [String: Any] else { return [] }
    return result["tools"] as? [[String: Any]] ?? []
  }

  private func listResources() async throws -> [[String: Any]] {
    let response = try await send(
      payload: [
        "jsonrpc": "2.0",
        "id": nextRequestId(),
        "method": "resources/list",
        "params": [:],
      ],
      expectsResponse: true
    )
    guard let result = response?["result"] as? [String: Any] else { return [] }
    return result["resources"] as? [[String: Any]] ?? []
  }

  private func readResource(uri: String) async throws -> GalleryMCPWidgetResource? {
    let response = try await send(
      payload: [
        "jsonrpc": "2.0",
        "id": nextRequestId(),
        "method": "resources/read",
        "params": ["uri": uri],
      ],
      expectsResponse: true
    )
    guard let result = response?["result"] as? [String: Any],
          let contents = result["contents"] as? [[String: Any]] else {
      return nil
    }

    for item in contents {
      let mimeType = item["mimeType"] as? String
      let itemURI = item["uri"] as? String ?? uri
      let text = itemText(item)
      guard !text.isEmpty else { continue }
      if isSupportedWidgetMime(mimeType) || text.localizedCaseInsensitiveContains("<html") {
        return GalleryMCPWidgetResource(uri: itemURI, mimeType: mimeType, html: text, csp: nil, permissions: nil)
      }
    }
    return nil
  }

  private func loadWidgetResource(tools: [[String: Any]], toolName: String) async throws -> GalleryMCPWidgetResource? {
    var candidateURIs: [String] = []

    if let tool = tools.first(where: { ($0["name"] as? String) == toolName }),
       let uri = outputTemplateURI(from: tool) {
      candidateURIs.append(uri)
    }

    let resources = (try? await listResources()) ?? []
    let preferredResources = resources
      .compactMap { resource -> (uri: String, mimeType: String?)? in
        guard let uri = resource["uri"] as? String else { return nil }
        return (uri, resource["mimeType"] as? String)
      }
      .filter { isSupportedWidgetMime($0.mimeType) }
      .sorted { lhs, rhs in
        if mimePriority(lhs.mimeType) != mimePriority(rhs.mimeType) {
          return mimePriority(lhs.mimeType) > mimePriority(rhs.mimeType)
        }
        return lhs.uri.contains("?v=") && !rhs.uri.contains("?v=")
      }
      .map(\.uri)
    candidateURIs.append(contentsOf: preferredResources)

    var seen = Set<String>()
    for uri in candidateURIs where seen.insert(uri).inserted {
      if let resource = try? await readResource(uri: uri) {
        return resource
      }
    }
    return nil
  }

  private func callTool(name: String, arguments: [String: Any]) async throws -> [String: Any] {
    let response = try await send(
      payload: [
        "jsonrpc": "2.0",
        "id": nextRequestId(),
        "method": "tools/call",
        "params": [
          "name": name,
          "arguments": arguments,
        ],
      ],
      expectsResponse: true
    )
    guard let result = response?["result"] as? [String: Any] else {
      throw MCPError.invalidResponse("tools/call returned no result")
    }
    return result
  }

  private func send(payload: [String: Any], expectsResponse: Bool) async throws -> [String: Any]? {
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    if let sessionId {
      request.setValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id")
    }
    request.httpBody = try JSONSerialization.data(withJSONObject: payload)

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw MCPError.invalidResponse("Missing HTTP response")
    }
    if let sessionId = http.mcpSessionId {
      self.sessionId = sessionId
    }

    if !expectsResponse && (200..<300).contains(http.statusCode) {
      return nil
    }
    guard (200..<300).contains(http.statusCode) else {
      let raw = String(data: data, encoding: .utf8) ?? ""
      throw MCPError.http(status: http.statusCode, body: raw)
    }

    guard let decoded = decodeResponse(data) else {
      if data.isEmpty && !expectsResponse { return nil }
      throw MCPError.invalidResponse(String(data: data, encoding: .utf8) ?? "Unreadable response")
    }
    if let error = decoded["error"] as? [String: Any] {
      let message = error["message"] as? String ?? "\(error)"
      throw MCPError.rpc(message)
    }
    return decoded
  }

  private func decodeResponse(_ data: Data) -> [String: Any]? {
    if let direct = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
      return direct
    }

    guard let text = String(data: data, encoding: .utf8) else { return nil }
    var latest: [String: Any]?
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.hasPrefix("data:") else { continue }
      let dataText = trimmed.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
      guard let eventData = dataText.data(using: .utf8),
            let parsed = try? JSONSerialization.jsonObject(with: eventData) as? [String: Any] else {
        continue
      }
      latest = parsed
    }
    return latest
  }

  private func pickTodayFortuneTool(from tools: [[String: Any]]) -> String {
    let names = tools.compactMap { $0["name"] as? String }
    let preferred = [
      "show_today_fortune",
      "_show_today_fortune",
      "show_saju_daily",
      "_show_saju_daily",
      "show_zodiac_horoscope",
      "_show_zodiac_horoscope",
    ]
    if let found = preferred.first(where: { names.contains($0) }) {
      return found
    }
    if let found = names.first(where: { $0.contains("today") || $0.contains("daily") || $0.contains("fortune") }) {
      return found
    }
    return "show_today_fortune"
  }

  private func renderToolResult(_ result: [String: Any], toolName: String) -> String {
    let content = result["content"] as? [[String: Any]] ?? []
    let texts = content.compactMap { item -> String? in
      guard (item["type"] as? String) == "text" else { return nil }
      return item["text"] as? String
    }
    let cleanedTexts = texts.compactMap(cleanToolText)
    if !cleanedTexts.isEmpty {
      return cleanedTexts.joined(separator: "\n\n")
    }
    if let structured = result["structuredContent"],
       let markdown = markdownSummary(from: structured) {
      return markdown
    }
    return "Fortune MCP에서 \(toolName)을 실행했어요."
  }

  private func makeSnapshot(
    toolName: String,
    message: String,
    result: [String: Any],
    widgetResource: GalleryMCPWidgetResource?,
    tools: [[String: Any]] = []
  ) -> McpWidgetSnapshot {
    let compactMessage = trimForWidget(message)
    let compactOutput = compactToolOutput(result, message: compactMessage)
    var state: [String: Any] = [
      "kind": "fortune",
      "connectorId": GalleryConnector.fortuneMcpId,
      "endpoint": GalleryConnector.fortuneMcpEndpoint,
      "toolName": toolName,
      "toolInput": [
        "lang": "ko",
        "target_date": todayString(),
      ],
      "toolOutput": compactOutput,
      "targetDate": todayString(),
      "contentMarkdown": compactMessage,
    ]
    if let toolDefinition = tools.first(where: { ($0["name"] as? String) == toolName }) {
      state["toolDefinition"] = compactToolDefinition(toolDefinition)
    }
    if let widgetResource {
      state["widgetUri"] = widgetResource.uri
      state["widgetMimeType"] = widgetResource.mimeType ?? ""
      state["widgetBaseUrl"] = mcpClient.widgetBaseURL(for: widgetResource.uri)
      state["widgetHtmlBase64"] = Data(widgetResource.html.utf8).base64EncodedString()
    }
    let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
    let json = data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    return McpWidgetSnapshot(
      connectorId: GalleryConnector.fortuneMcpId,
      title: "오늘의 운세",
      summary: firstSummaryLine(from: compactMessage),
      widgetStateJson: json
    )
  }

  private func compactToolDefinition(_ tool: [String: Any]) -> [String: Any] {
    var compact: [String: Any] = [:]
    for key in ["name", "title", "description", "inputSchema", "annotations", "_meta"] {
      if let value = tool[key] {
        compact[key] = GalleryMCPExtAppsClient.compactForWidget(value, maxStringLength: 2_000, maxArrayCount: 30)
      }
    }
    return compact
  }

  private func compactToolOutput(_ result: [String: Any], message: String) -> [String: Any] {
    var compact: [String: Any] = [
      "contentMarkdown": message,
      "generatedAt": ISO8601DateFormatter().string(from: Date()),
    ]
    if let structured = result["structuredContent"],
       let summary = markdownSummary(from: structured) {
      compact["structuredSummary"] = trimForWidget(summary)
    }
    if let target = targetIljin(from: rawSajuDataObject(in: message) ?? rawSajuDataObject(in: String(describing: result))) {
      compact["targetIljin"] = compactIljin(target)
    }
    return compact
  }

  private func firstSummaryLine(from message: String) -> String {
    message
      .split(separator: "\n", omittingEmptySubsequences: true)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .first { !$0.isEmpty }
      .map { String($0.prefix(80)) } ?? "Fortune MCP 결과"
  }

  private func todayString() -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "Asia/Seoul") ?? .current
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: Date())
  }

  private func nextRequestId() -> Int {
    defer { nextId += 1 }
    return nextId
  }

  private func outputTemplateURI(from tool: [String: Any]) -> String? {
    if let uri = tool["outputTemplate"] as? String {
      return uri
    }
    if let meta = tool["_meta"] as? [String: Any] {
      return meta["openai/outputTemplate"] as? String ??
        meta["openai/output_template"] as? String ??
        meta["outputTemplate"] as? String
    }
    return nil
  }

  private func isSupportedWidgetMime(_ mimeType: String?) -> Bool {
    guard let mimeType = mimeType?.lowercased() else { return false }
    return mimeType.hasPrefix("text/html") ||
      mimeType.contains("mcp-app") ||
      mimeType.contains("skybridge")
  }

  private func mimePriority(_ mimeType: String?) -> Int {
    switch mimeType {
    case "text/html;profile=mcp-app": return 2
    case "text/html+skybridge": return 1
    case "text/html": return 1
    default: return 0
    }
  }

  private func widgetResource(fromToolResult result: [String: Any]) -> GalleryMCPWidgetResource? {
    let content = result["content"] as? [[String: Any]] ?? []
    for item in content {
      if let resource = item["resource"] as? [String: Any] {
        let mimeType = resource["mimeType"] as? String
        let uri = resource["uri"] as? String ?? "inline://fortune-widget"
        let text = itemText(resource)
        if !text.isEmpty, isSupportedWidgetMime(mimeType) || text.localizedCaseInsensitiveContains("<html") {
          return GalleryMCPWidgetResource(uri: uri, mimeType: mimeType, html: text, csp: nil, permissions: nil)
        }
      }

      let mimeType = item["mimeType"] as? String
      let uri = item["uri"] as? String ?? "inline://fortune-widget"
      let text = itemText(item)
      if !text.isEmpty, isSupportedWidgetMime(mimeType) || text.localizedCaseInsensitiveContains("<html") {
        return GalleryMCPWidgetResource(uri: uri, mimeType: mimeType, html: text, csp: nil, permissions: nil)
      }
    }
    return nil
  }

  private func itemText(_ item: [String: Any]) -> String {
    if let text = item["text"] as? String {
      return text
    }
    if let blob = item["blob"] as? String,
       let data = Data(base64Encoded: blob),
       let text = String(data: data, encoding: .utf8) {
      return text
    }
    return ""
  }

  private func cleanToolText(_ text: String) -> String? {
    let normalized = text.replacingOccurrences(of: "\\n", with: "\n")
    if let markdown = fortuneMarkdownFromRawToolText(normalized) {
      return markdown
    }

    var trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if let markerRange = trimmed.range(of: "[Raw Saju Data]") {
      trimmed = String(trimmed[..<markerRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if trimmed.lowercased().contains("already loaded"),
       let firstBullet = trimmed.range(of: "\n- ") {
      trimmed = String(trimmed[firstBullet.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if let parsed = parseJsonLikeText(trimmed),
       let summary = markdownSummary(from: parsed) {
      return summary
    }
    if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
      return "오늘의 운세를 불러왔어요."
    }
    return trimmed
  }

  private func fortuneMarkdownFromRawToolText(_ text: String) -> String? {
    guard let raw = rawSajuDataObject(in: text),
          let target = targetIljin(from: raw) else {
      return nil
    }

    let ganji = target["ganji"] as? String ?? target["iljin"] as? String ?? "오늘"
    let dayOfWeek = target["day_of_week"] as? String
    let score = (target["scores"] as? [String: Any])?["fortune_flow"]
    let zodiac = target["zodiac_fortune"] as? [String: Any]
    let stemOverall = ((target["stem_fortune"] as? [String: Any])?["overall"] as? [String])?.first
    let branchOverall = ((target["branch_fortune"] as? [String: Any])?["overall"] as? [String])?.first
    let tips = Array((target["tips"] as? [String] ?? []).prefix(4))

    var lines = [
      "### 오늘의 운세",
      "- **일진**: \(ganji)\(dayOfWeek.map { " (\($0))" } ?? "")",
    ]
    if let score {
      lines.append("- **흐름 점수**: \(score)")
    }
    if let wealth = zodiac?["wealth"] as? String {
      lines.append("- **재물**: \(wealth)")
    }
    if let love = zodiac?["love"] as? String {
      lines.append("- **관계/애정**: \(love)")
    }
    if let health = zodiac?["health"] as? String {
      lines.append("- **건강**: \(health)")
    }
    if let direction = zodiac?["luckyDirection"] as? String {
      lines.append("- **행운 방향**: \(direction)")
    }
    if let stemOverall {
      lines.append("- **핵심 흐름**: \(stemOverall)")
    }
    if let branchOverall, branchOverall != stemOverall {
      lines.append("- **환경 흐름**: \(branchOverall)")
    }
    if !tips.isEmpty {
      lines.append("- **팁**: \(tips.joined(separator: ", "))")
    }
    return lines.joined(separator: "\n")
  }

  private func rawSajuDataObject(in text: String) -> [String: Any]? {
    let normalized = text.replacingOccurrences(of: "\\n", with: "\n")
    guard let marker = normalized.range(of: "[Raw Saju Data]"),
          let firstBrace = normalized[marker.upperBound...].firstIndex(of: "{") else {
      return nil
    }
    let jsonCandidate = String(normalized[firstBrace...])
    guard let jsonString = firstJSONObjectString(in: jsonCandidate),
          let data = jsonString.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return nil
    }
    return object
  }

  private func firstJSONObjectString(in text: String) -> String? {
    var depth = 0
    var isInString = false
    var isEscaped = false
    var endIndex: String.Index?

    for index in text.indices {
      let character = text[index]
      if isInString {
        if isEscaped {
          isEscaped = false
        } else if character == "\\" {
          isEscaped = true
        } else if character == "\"" {
          isInString = false
        }
        continue
      }

      if character == "\"" {
        isInString = true
      } else if character == "{" {
        depth += 1
      } else if character == "}" {
        depth -= 1
        if depth == 0 {
          endIndex = index
          break
        }
      }
    }

    guard let endIndex else { return nil }
    return String(text[...endIndex])
  }

  private func targetIljin(from raw: [String: Any]?) -> [String: Any]? {
    guard let list = raw?["iljin_list"] as? [[String: Any]] else { return nil }
    return list.first { ($0["is_target"] as? Bool) == true } ?? list.first
  }

  private func compactIljin(_ target: [String: Any]) -> [String: Any] {
    var compact: [String: Any] = [:]
    for key in ["year", "month", "day", "day_of_week", "ganji", "stem", "branch", "is_target"] {
      if let value = target[key] {
        compact[key] = value
      }
    }
    if let scores = target["scores"] as? [String: Any] {
      compact["scores"] = scores.filter { key, _ in
        ["balance", "swing", "love", "wealth", "health", "fortune_flow", "wealth_with_flow"].contains(key)
      }
    }
    if let zodiac = target["zodiac_fortune"] as? [String: Any] {
      compact["zodiac_fortune"] = zodiac.filter { key, _ in
        ["zodiac", "relation", "relationHeader", "mainKeyword", "wealth", "health", "love", "luckyDirection"].contains(key)
      }
    }
    if let tips = target["tips"] as? [String] {
      compact["tips"] = Array(tips.prefix(4))
    }
    return compact
  }

  private func trimForWidget(_ text: String, maxLength: Int = 4_000) -> String {
    let normalized = text.replacingOccurrences(of: "\\n", with: "\n")
    if normalized.count <= maxLength {
      return normalized
    }
    return String(normalized.prefix(maxLength)) + "\n\n…"
  }

  private func parseJsonLikeText(_ text: String) -> Any? {
    guard let data = text.data(using: .utf8) else { return nil }
    if let parsed = try? JSONSerialization.jsonObject(with: data) {
      return parsed
    }
    if let unescaped = try? JSONDecoder().decode(String.self, from: data),
       let unescapedData = unescaped.data(using: .utf8),
       let parsed = try? JSONSerialization.jsonObject(with: unescapedData) {
      return parsed
    }
    return nil
  }

  private func markdownSummary(from value: Any) -> String? {
    if let string = value as? String {
      return cleanToolText(string)
    }
    if let array = value as? [Any] {
      return array.compactMap(markdownSummary).first
    }
    guard let dict = value as? [String: Any] else { return nil }

    let preferredStringKeys = [
      "contentMarkdown",
      "markdown",
      "message",
      "summary",
      "interpretation",
      "advice",
      "text",
      "description",
    ]
    for key in preferredStringKeys {
      if let text = dict[key] as? String,
         let cleaned = cleanToolText(text),
         !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return cleaned
      }
    }

    for key in ["structuredContent", "result", "data", "fortune", "today", "daily", "content"] {
      if let nested = dict[key],
         let nestedMarkdown = markdownSummary(from: nested) {
        return nestedMarkdown
      }
    }

    let scalarLines = dict
      .sorted { $0.key < $1.key }
      .compactMap { key, value -> String? in
        guard value is String || value is NSNumber || value is Bool else { return nil }
        let rendered = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rendered.isEmpty else { return nil }
        return "- **\(humanTitle(key))**: \(rendered)"
      }
    return scalarLines.isEmpty ? nil : scalarLines.joined(separator: "\n")
  }

  private func humanTitle(_ key: String) -> String {
    key
      .replacingOccurrences(of: "_", with: " ")
      .replacingOccurrences(of: "-", with: " ")
      .capitalized
  }

  private func widgetBaseURL(for uri: String) -> String {
    if let url = URL(string: uri), let scheme = url.scheme, scheme.hasPrefix("http") {
      var components = URLComponents()
      components.scheme = url.scheme
      components.host = url.host
      components.port = url.port
      return components.url?.absoluteString ?? GalleryConnector.fortuneMcpEndpoint
    }
    var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
    components?.path = "/"
    components?.query = nil
    return components?.url?.absoluteString ?? GalleryConnector.fortuneMcpEndpoint
  }

  private enum MCPError: LocalizedError {
    case http(status: Int, body: String)
    case rpc(String)
    case invalidResponse(String)

    var errorDescription: String? {
      switch self {
      case .http(let status, let body):
        return "HTTP \(status): \(body)"
      case .rpc(let message):
        return message
      case .invalidResponse(let message):
        return message
      }
    }
  }
}

private extension HTTPURLResponse {
  var mcpSessionId: String? {
    for (key, value) in allHeaderFields {
      guard String(describing: key).lowercased() == "mcp-session-id" else { continue }
      return String(describing: value)
    }
    return nil
  }
}
