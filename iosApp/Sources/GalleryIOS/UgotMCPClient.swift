import Foundation

struct UgotMCPWidgetResource {
  let uri: String
  let mimeType: String?
  let html: String
  let csp: [String: Any]?
  let permissions: [String: Any]?
}

final class UgotMCPClient {
  static let uiExtensionId = "io.modelcontextprotocol/ui"
  static let resourceMimeType = "text/html;profile=mcp-app"
  static let latestUiProtocolVersion = "2026-01-26"

  let connectorId: String
  let endpoint: URL

  private let bearerToken: String?
  private var sessionId: String?
  private var nextId = 1
  private var didInitialize = false

  init(connectorId: String, endpoint: URL, bearerToken: String?) {
    self.connectorId = connectorId
    self.endpoint = endpoint
    self.bearerToken = bearerToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
      ? bearerToken
      : nil
  }

  func initialize() async throws {
    guard !didInitialize else { return }
    _ = try await send(
      payload: [
        "jsonrpc": "2.0",
        "id": nextRequestId(),
        "method": "initialize",
        "params": Self.paramsWithLocaleMeta([
          "protocolVersion": "2025-03-26",
          "capabilities": [
            "tools": [:],
            "resources": [:],
            "extensions": [
              Self.uiExtensionId: [
                "mimeTypes": [Self.resourceMimeType, "text/html", "text/html+skybridge"]
              ]
            ],
          ],
          "clientInfo": [
            "name": "ugot-ios",
            "version": "0.1",
          ],
        ]),
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
    didInitialize = true
  }

  func request(method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
    try await initialize()
    let response = try await send(
      payload: [
        "jsonrpc": "2.0",
        "id": nextRequestId(),
        "method": method,
        "params": Self.paramsWithLocaleMeta(params),
      ],
      expectsResponse: true
    )
    guard let result = response?["result"] as? [String: Any] else {
      throw MCPError.invalidResponse("\(method) returned no object result")
    }
    return result
  }

  func listTools() async throws -> [[String: Any]] {
    let result = try await request(method: "tools/list")
    return result["tools"] as? [[String: Any]] ?? []
  }

  func listPrompts() async throws -> [[String: Any]] {
    let result = try await request(method: "prompts/list")
    return result["prompts"] as? [[String: Any]] ?? []
  }

  func getPrompt(name: String, arguments: [String: Any] = [:]) async throws -> [String: Any] {
    try await request(
      method: "prompts/get",
      params: [
        "name": name,
        "arguments": arguments,
      ]
    )
  }

  func completePromptArgument(
    promptName: String,
    argumentName: String,
    partialValue: String = "",
    arguments: [String: String] = [:]
  ) async throws -> UgotMCPPromptCompletionResult {
    var params: [String: Any] = [
      "ref": [
        "type": "ref/prompt",
        "name": promptName,
      ],
      "argument": [
        "name": argumentName,
        "value": partialValue,
      ],
    ]
    if !arguments.isEmpty {
      params["context"] = ["arguments": arguments]
    }
    let result = try await request(method: "completion/complete", params: params)
    guard let completion = result["completion"] as? [String: Any] else { return .empty }
    let values = (completion["values"] as? [String] ?? [])
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    let total = (completion["total"] as? Int) ??
      (completion["total"] as? NSNumber)?.intValue ??
      values.count
    let hasMore = (completion["hasMore"] as? Bool) ??
      (completion["has_more"] as? Bool) ??
      ((completion["hasMore"] as? NSNumber)?.boolValue) ??
      ((completion["has_more"] as? NSNumber)?.boolValue) ??
      false
    return UgotMCPPromptCompletionResult(values: values, total: total, hasMore: hasMore)
  }

  func listResources() async throws -> [[String: Any]] {
    let result = try await request(method: "resources/list")
    return result["resources"] as? [[String: Any]] ?? []
  }

  func callTool(name: String, arguments: [String: Any]) async throws -> [String: Any] {
    try await request(
      method: "tools/call",
      params: [
        "name": name,
        "arguments": arguments,
      ]
    )
  }

  func readResource(uri: String) async throws -> [String: Any]? {
    try await request(method: "resources/read", params: ["uri": uri])
  }

  func readWidgetResource(uri: String, listedResources: [[String: Any]] = []) async throws -> UgotMCPWidgetResource? {
    guard let result = try await readResource(uri: uri),
          let contents = result["contents"] as? [[String: Any]] else {
      return nil
    }

    let listingMeta = listedResources
      .first { ($0["uri"] as? String) == uri }
      .flatMap { Self.uiMeta(from: $0) }

    for item in contents {
      let mimeType = item["mimeType"] as? String
      let itemURI = item["uri"] as? String ?? uri
      let text = Self.itemText(item)
      guard !text.isEmpty else { continue }
      if Self.isSupportedWidgetMime(mimeType) || text.localizedCaseInsensitiveContains("<html") {
        let contentMeta = Self.uiMeta(from: item)
        return UgotMCPWidgetResource(
          uri: itemURI,
          mimeType: mimeType,
          html: text,
          csp: (contentMeta?["csp"] as? [String: Any]) ?? (listingMeta?["csp"] as? [String: Any]),
          permissions: (contentMeta?["permissions"] as? [String: Any]) ?? (listingMeta?["permissions"] as? [String: Any])
        )
      }
    }
    return nil
  }

  func resolveWidgetResource(
    tools: [[String: Any]],
    toolName: String,
    result: [String: Any]
  ) async throws -> UgotMCPWidgetResource? {
    // The tool result is the source of truth. If a tool returns an inline HTML
    // resource, render it regardless of static metadata.
    if let inline = Self.widgetResource(fromToolResult: result) {
      return inline
    }

    // Otherwise render only the widget template explicitly declared by this
    // exact tool. Do not fall back to arbitrary resources/list HTML entries:
    // servers commonly expose multiple app resources, and choosing the first
    // one can show an unrelated widget after a data-only tool such as
    // set_default_user.
    guard let tool = tools.first(where: { ($0["name"] as? String) == toolName }),
          let uri = Self.widgetResourceURI(from: tool) else {
      return nil
    }

    let resources = (try? await listResources()) ?? []
    return try? await readWidgetResource(uri: uri, listedResources: resources)
  }

  func widgetBaseURL(for uri: String) -> String {
    if let url = URL(string: uri), let scheme = url.scheme, scheme.hasPrefix("http") {
      var components = URLComponents()
      components.scheme = url.scheme
      components.host = url.host
      components.port = url.port
      return components.url?.absoluteString ?? endpoint.absoluteString
    }
    var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
    components?.path = "/"
    components?.query = nil
    return components?.url?.absoluteString ?? endpoint.absoluteString
  }

  static func widgetResourceURI(from tool: [String: Any]) -> String? {
    if let uri = tool["outputTemplate"] as? String {
      return uri
    }
    for metaKey in ["_meta", "meta"] {
      guard let meta = tool[metaKey] as? [String: Any] else { continue }
      if let ui = meta["ui"] as? [String: Any], let uri = ui["resourceUri"] as? String {
        return uri
      }
      if let uri = meta["ui/resourceUri"] as? String ??
        meta["openai/outputTemplate"] as? String ??
        meta["openai/output_template"] as? String ??
        meta["outputTemplate"] as? String {
        return uri
      }
    }
    return nil
  }

  static func isSupportedWidgetMime(_ mimeType: String?) -> Bool {
    guard let mimeType = mimeType?.lowercased() else { return false }
    return mimeType.hasPrefix("text/html") ||
      mimeType.contains("mcp-app") ||
      mimeType.contains("skybridge")
  }

  static func compactForWidget(_ value: Any, maxStringLength: Int = 24_000, maxArrayCount: Int = 80) -> Any {
    if let string = value as? String {
      if string.count <= maxStringLength { return string }
      return String(string.prefix(maxStringLength)) + "\n\n…"
    }
    if value is NSNull || value is NSNumber || value is Bool { return value }
    if let array = value as? [Any] {
      return Array(array.prefix(maxArrayCount)).map { compactForWidget($0, maxStringLength: maxStringLength, maxArrayCount: maxArrayCount) }
    }
    if let dict = value as? [String: Any] {
      var out: [String: Any] = [:]
      for (key, nested) in dict {
        out[key] = compactForWidget(nested, maxStringLength: maxStringLength, maxArrayCount: maxArrayCount)
      }
      return out
    }
    return String(describing: value)
  }

  private func send(payload: [String: Any], expectsResponse: Bool) async throws -> [String: Any]? {
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = Self.isLocalEndpoint(endpoint) ? 8 : 30
    if let bearerToken {
      request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
    }
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    request.setValue(UgotMCPLocale.acceptLanguageHeader, forHTTPHeaderField: "Accept-Language")
    if let sessionId {
      request.setValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id")
    }
    request.httpBody = try JSONSerialization.data(withJSONObject: payload)

    let (data, response) = try await Self.dataWithLocalNetworkRetry(for: request, endpoint: endpoint)
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

    guard let decoded = Self.decodeResponse(data) else {
      if data.isEmpty && !expectsResponse { return nil }
      throw MCPError.invalidResponse(String(data: data, encoding: .utf8) ?? "Unreadable response")
    }
    if let error = decoded["error"] as? [String: Any] {
      let message = error["message"] as? String ?? "\(error)"
      throw MCPError.rpc(message)
    }
    return decoded
  }

  private func nextRequestId() -> Int {
    defer { nextId += 1 }
    return nextId
  }

  static func localeMeta(locale: String = UgotMCPLocale.preferredLanguageTag) -> [String: Any] {
    [
      "locale": locale,
      "openai/locale": locale,
    ]
  }

  static func paramsWithLocaleMeta(_ params: [String: Any]) -> [String: Any] {
    var out = params
    var meta = out["_meta"] as? [String: Any] ?? [:]
    for (key, value) in localeMeta() {
      meta[key] = value
    }
    out["_meta"] = meta
    return out
  }

  private static func dataWithLocalNetworkRetry(
    for request: URLRequest,
    endpoint: URL
  ) async throws -> (Data, URLResponse) {
    let maxAttempts = isLocalEndpoint(endpoint) ? 4 : 1
    var lastError: Error?
    for attempt in 1...maxAttempts {
      do {
        return try await URLSession.shared.data(for: request)
      } catch {
        lastError = error
        guard attempt < maxAttempts, shouldRetryLocalNetworkError(error) else {
          throw error
        }
        let delayNanos = UInt64(650_000_000 * UInt64(attempt))
        try? await Task.sleep(nanoseconds: delayNanos)
      }
    }
    throw lastError ?? MCPError.invalidResponse("Request failed")
  }

  private static func shouldRetryLocalNetworkError(_ error: Error) -> Bool {
    guard let urlError = error as? URLError else { return false }
    switch urlError.code {
    case .cancelled,
         .userCancelledAuthentication:
      return false
    default:
      return true
    }
  }

  private static func isLocalEndpoint(_ url: URL) -> Bool {
    guard let host = url.host?.lowercased() else { return false }
    return host == "localhost" ||
      host == "127.0.0.1" ||
      host.hasSuffix(".local") ||
      host.hasPrefix("10.") ||
      host.hasPrefix("192.168.") ||
      host.range(of: #"^172\.(1[6-9]|2[0-9]|3[0-1])\."#, options: .regularExpression) != nil
  }

  private static func decodeResponse(_ data: Data) -> [String: Any]? {
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

  private static func widgetResource(fromToolResult result: [String: Any]) -> UgotMCPWidgetResource? {
    let content = result["content"] as? [[String: Any]] ?? []
    for item in content {
      if let resource = item["resource"] as? [String: Any] {
        let mimeType = resource["mimeType"] as? String
        let uri = resource["uri"] as? String ?? "inline://mcp-widget"
        let text = itemText(resource)
        if !text.isEmpty, isSupportedWidgetMime(mimeType) || text.localizedCaseInsensitiveContains("<html") {
          let meta = uiMeta(from: resource)
          return UgotMCPWidgetResource(uri: uri, mimeType: mimeType, html: text, csp: meta?["csp"] as? [String: Any], permissions: meta?["permissions"] as? [String: Any])
        }
      }

      let mimeType = item["mimeType"] as? String
      let uri = item["uri"] as? String ?? "inline://mcp-widget"
      let text = itemText(item)
      if !text.isEmpty, isSupportedWidgetMime(mimeType) || text.localizedCaseInsensitiveContains("<html") {
        let meta = uiMeta(from: item)
        return UgotMCPWidgetResource(uri: uri, mimeType: mimeType, html: text, csp: meta?["csp"] as? [String: Any], permissions: meta?["permissions"] as? [String: Any])
      }
    }
    return nil
  }

  private static func itemText(_ item: [String: Any]) -> String {
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

  private static func uiMeta(from item: [String: Any]) -> [String: Any]? {
    if let meta = item["_meta"] as? [String: Any], let ui = meta["ui"] as? [String: Any] {
      return ui
    }
    if let meta = item["meta"] as? [String: Any], let ui = meta["ui"] as? [String: Any] {
      return ui
    }
    return nil
  }

  private static func mimePriority(_ mimeType: String?) -> Int {
    switch mimeType?.lowercased() {
    case Self.resourceMimeType: return 3
    case "text/html+skybridge": return 2
    case "text/html": return 1
    default: return 0
    }
  }

  enum MCPError: LocalizedError {
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
