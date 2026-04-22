import Foundation

final class UgotMCPRuntimeClient {
  private enum Backend {
    case http(UgotMCPClient)
    case embeddedMail(UgotEmbeddedMailMCPClient)
  }

  let connectorId: String
  let endpoint: URL
  private let backend: Backend

  private init(connectorId: String, endpoint: URL, backend: Backend) {
    self.connectorId = connectorId
    self.endpoint = endpoint
    self.backend = backend
  }

  static func make(connectorId: String, endpoint: URL, accessToken: String) -> UgotMCPRuntimeClient {
    if endpoint.scheme == "embedded", connectorId == GalleryConnector.mailMcpId {
      return UgotMCPRuntimeClient(
        connectorId: connectorId,
        endpoint: endpoint,
        backend: .embeddedMail(UgotEmbeddedMailMCPClient(connectorId: connectorId, endpoint: endpoint))
      )
    }
    return UgotMCPRuntimeClient(
      connectorId: connectorId,
      endpoint: endpoint,
      backend: .http(UgotMCPClient(connectorId: connectorId, endpoint: endpoint, accessToken: accessToken))
    )
  }

  func initialize() async throws {
    switch backend {
    case .http(let client): try await client.initialize()
    case .embeddedMail(let client): try await client.initialize()
    }
  }

  func request(method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
    switch backend {
    case .http(let client): return try await client.request(method: method, params: params)
    case .embeddedMail(let client): return try await client.request(method: method, params: params)
    }
  }

  func listTools() async throws -> [[String: Any]] {
    switch backend {
    case .http(let client): return try await client.listTools()
    case .embeddedMail(let client): return try await client.listTools()
    }
  }

  func listPrompts() async throws -> [[String: Any]] {
    switch backend {
    case .http(let client): return try await client.listPrompts()
    case .embeddedMail(let client): return try await client.listPrompts()
    }
  }

  func getPrompt(name: String, arguments: [String: Any] = [:]) async throws -> [String: Any] {
    switch backend {
    case .http(let client): return try await client.getPrompt(name: name, arguments: arguments)
    case .embeddedMail(let client): return try await client.getPrompt(name: name, arguments: arguments)
    }
  }

  func listResources() async throws -> [[String: Any]] {
    switch backend {
    case .http(let client): return try await client.listResources()
    case .embeddedMail(let client): return try await client.listResources()
    }
  }

  func callTool(name: String, arguments: [String: Any]) async throws -> [String: Any] {
    switch backend {
    case .http(let client): return try await client.callTool(name: name, arguments: arguments)
    case .embeddedMail(let client): return try await client.callTool(name: name, arguments: arguments)
    }
  }

  func readResource(uri: String) async throws -> [String: Any]? {
    switch backend {
    case .http(let client): return try await client.readResource(uri: uri)
    case .embeddedMail(let client): return try await client.readResource(uri: uri)
    }
  }

  func resolveWidgetResource(
    tools: [[String: Any]],
    toolName: String,
    result: [String: Any]
  ) async throws -> UgotMCPWidgetResource? {
    switch backend {
    case .http(let client): return try await client.resolveWidgetResource(tools: tools, toolName: toolName, result: result)
    case .embeddedMail(let client): return try await client.resolveWidgetResource(tools: tools, toolName: toolName, result: result)
    }
  }

  func widgetBaseURL(for uri: String) -> String {
    switch backend {
    case .http(let client): return client.widgetBaseURL(for: uri)
    case .embeddedMail(let client): return client.widgetBaseURL(for: uri)
    }
  }
}

final class UgotEmbeddedMailMCPClient {
  let connectorId: String
  let endpoint: URL
  private var didInitialize = false

  init(connectorId: String, endpoint: URL) {
    self.connectorId = connectorId
    self.endpoint = endpoint
  }

  func initialize() async throws {
    guard !didInitialize else { return }
    let dbPath = try Self.embeddedDatabasePath()
    let response = try Self.invokeRust({ ptr in mail_mcp_rs_embedded_init(ptr) }, stringArg: dbPath)
    guard (response["ok"] as? Bool) != false else {
      throw EmbeddedMailError.rust(response["error"] as? String ?? "Failed to initialize embedded mail-mcp-rs")
    }
    didInitialize = true
  }

  func request(method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
    try await initialize()
    switch method {
    case "tools/list":
      return try await listToolsResult()
    case "tools/call":
      guard let name = params["name"] as? String else {
        throw EmbeddedMailError.invalidRequest("tools/call requires name")
      }
      let arguments = params["arguments"] as? [String: Any] ?? [:]
      return try await callTool(name: name, arguments: arguments)
    case "resources/list":
      return ["resources": []]
    case "prompts/list":
      return ["prompts": []]
    default:
      throw EmbeddedMailError.invalidRequest("Unsupported embedded mail MCP method: \(method)")
    }
  }

  func listTools() async throws -> [[String: Any]] {
    let result = try await listToolsResult()
    return result["tools"] as? [[String: Any]] ?? []
  }

  func listPrompts() async throws -> [[String: Any]] { [] }

  func getPrompt(name: String, arguments: [String: Any] = [:]) async throws -> [String: Any] {
    throw EmbeddedMailError.invalidRequest("Embedded mail-mcp-rs does not expose prompts yet")
  }

  func listResources() async throws -> [[String: Any]] { [] }

  func callTool(name: String, arguments: [String: Any]) async throws -> [String: Any] {
    try await initialize()
    let argsJson = try Self.jsonString(arguments)
    return try Self.invokeRust({ namePtr in
      argsJson.withCString { argsPtr in
        mail_mcp_rs_embedded_call_tool(namePtr, argsPtr)
      }
    }, stringArg: name)
  }

  func readResource(uri: String) async throws -> [String: Any]? { nil }

  func resolveWidgetResource(
    tools: [[String: Any]],
    toolName: String,
    result: [String: Any]
  ) async throws -> UgotMCPWidgetResource? {
    nil
  }

  func widgetBaseURL(for uri: String) -> String {
    endpoint.absoluteString
  }

  private func listToolsResult() async throws -> [String: Any] {
    try await initialize()
    return try Self.invokeRust { mail_mcp_rs_embedded_list_tools() }
  }

  private static func embeddedDatabasePath() throws -> String {
    let appSupport = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let dir = appSupport.appendingPathComponent("MailMCPRS", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("mail_mcp_rs.sqlite").path
  }

  private static func jsonString(_ value: Any) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    return String(data: data, encoding: .utf8) ?? "{}"
  }

  private static func invokeRust(_ call: () -> UnsafeMutablePointer<CChar>?) throws -> [String: Any] {
    guard let ptr = call() else {
      throw EmbeddedMailError.rust("Rust returned null")
    }
    defer { mail_mcp_rs_embedded_free_string(ptr) }
    let text = String(cString: ptr)
    guard let data = text.data(using: .utf8),
          let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw EmbeddedMailError.rust("Invalid Rust JSON response: \(text)")
    }
    return decoded
  }

  private static func invokeRust(
    _ call: (UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?,
    stringArg: String
  ) throws -> [String: Any] {
    try stringArg.withCString { ptr in
      try invokeRust { call(ptr) }
    }
  }

  enum EmbeddedMailError: LocalizedError {
    case rust(String)
    case invalidRequest(String)

    var errorDescription: String? {
      switch self {
      case .rust(let message): return message
      case .invalidRequest(let message): return message
      }
    }
  }
}
