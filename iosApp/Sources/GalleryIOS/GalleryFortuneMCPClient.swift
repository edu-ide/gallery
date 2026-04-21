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

private struct GalleryFortuneMCPResponse {
  let message: String
  let snapshot: McpWidgetSnapshot
}

private final class GalleryFortuneMCPClient {
  private let endpoint = URL(string: GalleryConnector.fortuneMcpEndpoint)!
  private let accessToken: String
  private var sessionId: String?
  private var nextId = 1

  init(accessToken: String) {
    self.accessToken = accessToken
  }

  func fetchTodayFortune() async throws -> GalleryFortuneMCPResponse {
    try await initialize()
    let tools = try await listTools()
    let toolName = pickTodayFortuneTool(from: tools)
    let result = try await callTool(
      name: toolName,
      arguments: [
        "lang": "ko",
        "target_date": todayString(),
      ]
    )
    let message = renderToolResult(result, toolName: toolName)
    return GalleryFortuneMCPResponse(
      message: message,
      snapshot: makeSnapshot(toolName: toolName, message: message, result: result)
    )
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
    if !texts.isEmpty {
      return texts.joined(separator: "\n\n")
    }
    if let structured = result["structuredContent"],
       let data = try? JSONSerialization.data(withJSONObject: structured, options: [.prettyPrinted]),
       let json = String(data: data, encoding: .utf8) {
      return "Fortune MCP 결과입니다.\n\n```json\n\(json)\n```"
    }
    return "Fortune MCP에서 \(toolName)을 실행했어요. 위젯 응답을 받았지만 표시할 텍스트가 없어요."
  }

  private func makeSnapshot(toolName: String, message: String, result: [String: Any]) -> McpWidgetSnapshot {
    let state: [String: Any] = [
      "kind": "fortune",
      "connectorId": GalleryConnector.fortuneMcpId,
      "endpoint": GalleryConnector.fortuneMcpEndpoint,
      "toolName": toolName,
      "targetDate": todayString(),
      "contentMarkdown": message,
      "rawResult": result,
    ]
    let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
    let json = data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    return McpWidgetSnapshot(
      connectorId: GalleryConnector.fortuneMcpId,
      title: "오늘의 운세",
      summary: firstSummaryLine(from: message),
      widgetStateJson: json
    )
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
