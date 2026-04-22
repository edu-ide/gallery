import Foundation
import GallerySharedCore

enum UgotMCPActionRunner {
  typealias ToolPlanningProvider = (UgotMCPToolPlanningRequest) async -> UgotMCPToolPlanningDecision?

  static func runIfNeeded(
    prompt: String,
    activeSkillIds: Set<String>,
    activeConnectorIds: Set<String>,
    sessionId: String,
    toolPlanningProvider: ToolPlanningProvider? = nil
  ) async -> GalleryChatActionResult? {
    let activeConnectors = GalleryConnector.samples.filter { activeConnectorIds.contains($0.id) }
    guard !activeConnectors.isEmpty else { return nil }

    do {
      guard let accessToken = try await UgotAuthStore.validAccessToken() else {
        return GalleryChatActionResult(message: "UGOT 세션이 만료됐어요. 다시 로그인해 주세요.")
      }
      let clients = activeConnectors.map { connector in
        UgotMCPConnectorAction(
          connector: connector,
          accessToken: accessToken,
          sessionId: sessionId,
          toolPlanningProvider: toolPlanningProvider
        )
      }

      let orderedClients = try await orderedClients(
        clients,
        prompt: prompt,
        sessionId: sessionId,
        activeConnectorIds: activeConnectorIds
      )
      guard !orderedClients.isEmpty else { return nil }
      for client in orderedClients {
        if let response = try await client.run(
          prompt: prompt,
          emitNoToolFailure: false
        ) {
          return GalleryChatActionResult(
            message: response.message,
            widgetSnapshot: response.snapshot,
            approvalRequest: response.approvalRequest,
            toolObservation: response.observation
          )
        }
      }
      // No MCP tool matched this turn. This is not an action failure: active
      // connectors are optional capabilities, so the chat pipeline should fall
      // back to the normal model response instead of surfacing a no-op message.
      return nil
    } catch {
      return GalleryChatActionResult(message: "MCP 호출에 실패했어요.\n\n\(error.localizedDescription)")
    }
  }

  private static func orderedClients(
    _ clients: [UgotMCPConnectorAction],
    prompt: String,
    sessionId: String,
    activeConnectorIds: Set<String>
  ) async throws -> [UgotMCPConnectorAction] {
    if let pendingConnectorId = UgotMCPToolApprovalStore.pendingConnectorId(
      sessionId: sessionId,
      connectorIds: activeConnectorIds
    ), let pendingClient = clients.first(where: { $0.connectorId == pendingConnectorId }) {
      return [pendingClient] + clients.filter { $0.connectorId != pendingConnectorId }
    }

    guard clients.count > 1 else { return clients }

    var candidates: [UgotMCPConnectorToolSearchCandidate] = []
    await withTaskGroup(of: UgotMCPConnectorToolSearchCandidate?.self) { group in
      for client in clients {
        group.addTask {
          guard let candidate = try? await client.planningCandidate(prompt: prompt),
                candidate.searchScore >= UgotMCPToolPlanner.minimumSearchScoreForPlanning else {
            return nil
          }
          return candidate
        }
      }

      for await candidate in group {
        if let candidate {
          candidates.append(candidate)
        }
      }
    }
    // Metadata search is an optimization gate, not a user-visible failure.
    // If no connector advertises a relevant tool for this turn, skip MCP and
    // let the caller continue with the normal model path.
    guard !candidates.isEmpty else { return [] }

    let byConnectorId = Dictionary(uniqueKeysWithValues: clients.map { ($0.connectorId, $0) })
    let metadataOrderedIds = candidates
      .sorted { lhs, rhs in
        if lhs.searchScore != rhs.searchScore { return lhs.searchScore > rhs.searchScore }
        if lhs.connectorTitle != rhs.connectorTitle { return lhs.connectorTitle < rhs.connectorTitle }
        return lhs.connectorId < rhs.connectorId
      }
      .map(\.connectorId)
    return orderedClients(ids: metadataOrderedIds, lookup: byConnectorId, fallback: [])
  }

  private static func orderedClients(
    ids: [String],
    lookup: [String: UgotMCPConnectorAction],
    fallback: [UgotMCPConnectorAction]
  ) -> [UgotMCPConnectorAction] {
    var seen = Set<String>()
    var out: [UgotMCPConnectorAction] = []
    for id in ids where seen.insert(id).inserted {
      if let client = lookup[id] {
        out.append(client)
      }
    }
    for client in fallback where seen.insert(client.connectorId).inserted {
      out.append(client)
    }
    return out
  }


  static func prewarmTools(activeConnectorIds: Set<String>) async {
    let activeConnectors = GalleryConnector.samples.filter { activeConnectorIds.contains($0.id) }
    guard !activeConnectors.isEmpty else { return }
    do {
      guard let accessToken = try await UgotAuthStore.validAccessToken() else { return }
      await withTaskGroup(of: Void.self) { group in
        for connector in activeConnectors {
          group.addTask {
            let client = UgotMCPConnectorAction(
              connector: connector,
              accessToken: accessToken,
              sessionId: "prewarm"
            )
            try? await client.warmToolCatalog()
          }
        }
      }
    } catch {
      return
    }
  }

  static func runApprovedPending(
    sessionId: String,
    activeConnectorIds: Set<String>
  ) async -> GalleryChatActionResult? {
    guard let pending = UgotMCPToolApprovalStore.pendingApproval(
      sessionId: sessionId,
      connectorIds: activeConnectorIds
    ) else {
      return GalleryChatActionResult(message: "승인 대기 중인 도구가 없어요.")
    }
    guard let connector = GalleryConnector.connector(for: pending.connectorId) else {
      UgotMCPToolApprovalStore.clearPending(sessionId: sessionId, connectorId: pending.connectorId)
      return GalleryChatActionResult(message: "승인 대기 중인 connector를 찾지 못했어요.")
    }
    do {
      guard let accessToken = try await UgotAuthStore.validAccessToken() else {
        return GalleryChatActionResult(message: "UGOT 세션이 만료됐어요. 다시 로그인해 주세요.")
      }
      let client = UgotMCPConnectorAction(
        connector: connector,
        accessToken: accessToken,
        sessionId: sessionId
      )
      guard let response = try await client.runApprovedPending() else {
        return GalleryChatActionResult(message: "승인 대기 중인 도구가 없어요.")
      }
      return GalleryChatActionResult(
        message: response.message,
        widgetSnapshot: response.snapshot,
        approvalRequest: response.approvalRequest,
        toolObservation: response.observation
      )
    } catch {
      return GalleryChatActionResult(message: "MCP 승인 실행에 실패했어요.\n\n\(error.localizedDescription)")
    }
  }
}

struct UgotMCPActionResponse {
  let message: String
  let snapshot: McpWidgetSnapshot?
  let approvalRequest: UgotMCPToolApprovalRequest?
  let observation: UgotAgentToolObservation?

  init(
    message: String,
    snapshot: McpWidgetSnapshot?,
    approvalRequest: UgotMCPToolApprovalRequest? = nil,
    observation: UgotAgentToolObservation? = nil
  ) {
    self.message = message
    self.snapshot = snapshot
    self.approvalRequest = approvalRequest
    self.observation = observation
  }
}

struct UgotMCPToolApprovalRequest: Identifiable, Equatable {
  let sessionId: String
  let connectorId: String
  let connectorTitle: String
  let toolName: String
  let toolTitle: String
  let argumentsPreview: String
  let userPrompt: String?

  var id: String { "\(sessionId)::\(connectorId)::\(toolName)" }
}

struct UgotMCPToolPlanningRequest {
  let prompt: String
  let connectorId: String
  let connectorTitle: String
  let tools: [[String: Any]]
}

struct UgotMCPConnectorToolSearchCandidate {
  let connectorId: String
  let connectorTitle: String
  let connectorSummary: String
  let searchScore: Int
  let topTools: [[String: Any]]
}

struct UgotMCPToolPlanningDecision {
  let toolName: String?
  let arguments: [String: Any]
  let entityReference: String?
  let confidence: Double
  let requiresTool: Bool

  var shouldUseTool: Bool {
    guard let toolName, !toolName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return false
    }
    return confidence >= 0.55
  }

  static func parse(from rawText: String) -> UgotMCPToolPlanningDecision? {
    guard let object = jsonObject(from: rawText) else { return nil }
    let rawTool = firstString(in: object, keys: ["tool_name", "toolName", "tool", "name"])
    let normalizedTool = rawTool?.trimmingCharacters(in: .whitespacesAndNewlines)
    let nullToolNames = ["", "none", "null", "no_tool", "no tool", "model"]
    let toolName = normalizedTool.flatMap { value in
      nullToolNames.contains(value.lowercased()) ? nil : value
    }
    let arguments =
      (object["arguments"] as? [String: Any]) ??
      (object["args"] as? [String: Any]) ??
      [:]
    let entityReference = firstString(in: object, keys: [
      "entity_reference",
      "entityReference",
      "target_reference",
      "targetReference",
      "profile_name",
      "profileName",
      "name_reference",
      "nameReference",
    ])?.trimmingCharacters(in: .whitespacesAndNewlines)
    let confidence = firstDouble(in: object, keys: ["confidence", "score"]) ?? (toolName == nil ? 0 : 0.7)
    let requiresTool =
      firstBool(in: object, keys: ["requires_tool", "requiresTool", "needs_tool", "needsTool"]) ??
      (toolName != nil)
    return UgotMCPToolPlanningDecision(
      toolName: toolName,
      arguments: arguments,
      entityReference: entityReference?.isEmpty == false ? entityReference : nil,
      confidence: confidence,
      requiresTool: requiresTool
    )
  }

  private static func jsonObject(from text: String) -> [String: Any]? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let candidates = [
      trimmed,
      fencedJSONBody(from: trimmed),
      firstJSONObjectSubstring(in: trimmed),
    ].compactMap { $0 }

    for candidate in candidates {
      guard let data = candidate.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        continue
      }
      return object
    }
    return nil
  }

  private static func fencedJSONBody(from text: String) -> String? {
    guard let start = text.range(of: "```") else { return nil }
    let afterStart = text[start.upperBound...]
    guard let end = afterStart.range(of: "```") else { return nil }
    var body = String(afterStart[..<end.lowerBound])
    if body.lowercased().hasPrefix("json") {
      body = String(body.dropFirst(4))
    }
    return body.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func firstJSONObjectSubstring(in text: String) -> String? {
    guard let start = text.firstIndex(of: "{") else { return nil }
    var depth = 0
    var inString = false
    var isEscaped = false
    var index = start
    while index < text.endIndex {
      let character = text[index]
      if inString {
        if isEscaped {
          isEscaped = false
        } else if character == "\\" {
          isEscaped = true
        } else if character == "\"" {
          inString = false
        }
      } else if character == "\"" {
        inString = true
      } else if character == "{" {
        depth += 1
      } else if character == "}" {
        depth -= 1
        if depth == 0 {
          return String(text[start...index])
        }
      }
      index = text.index(after: index)
    }
    return nil
  }

  private static func firstString(in object: [String: Any], keys: [String]) -> String? {
    for key in keys {
      if let value = object[key] as? String {
        return value
      }
    }
    return nil
  }

  private static func firstDouble(in object: [String: Any], keys: [String]) -> Double? {
    for key in keys {
      if let value = object[key] as? Double {
        return value
      }
      if let value = object[key] as? NSNumber {
        return value.doubleValue
      }
      if let value = object[key] as? String,
         let parsed = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
        return parsed
      }
    }
    return nil
  }

  private static func firstBool(in object: [String: Any], keys: [String]) -> Bool? {
    for key in keys {
      if let value = object[key] as? Bool {
        return value
      }
      if let value = object[key] as? NSNumber {
        return value.boolValue
      }
      if let value = object[key] as? String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["true", "yes", "1"].contains(normalized) { return true }
        if ["false", "no", "0"].contains(normalized) { return false }
      }
    }
    return nil
  }
}

enum UgotMCPToolPlanningPromptBuilder {
  static func build(request: UgotMCPToolPlanningRequest) -> String {
    let tools = request.tools
      .map(toolSummary)
      .joined(separator: "\n")
      .trimmedForPrompt(limit: 10_000)
    return """
    You are a model-agnostic MCP tool router for the mobile chat host.

    Decide whether the user's latest message should call exactly one MCP tool from connector "\(request.connectorTitle)".
    Use semantic intent, not keyword matching. The user may write in any language.

    Return ONLY one JSON object with this schema:
    {
      "tool_name": "exact listed tool name or null",
      "arguments": { "schema_parameter": "value" },
      "entity_reference": "visible user/profile/place/name to resolve later, or null",
      "confidence": 0.0,
      "requires_tool": false
    }

    Rules:
    - Use only tools listed below.
    - App-only/internal widget tools are intentionally omitted. Never invent or request hidden app-only tools.
    - If no listed tool is clearly needed, return {"tool_name": null, "arguments": {}, "entity_reference": null, "confidence": 0, "requires_tool": false}.
    - If the user requests an action that would require a tool but none of the listed tools can do it, return tool_name null and requires_tool true.
    - For read-only display requests, prefer the most specific read-only display tool.
    - For mutation/settings tools, choose them only when the user explicitly asks to set, change, save, delete, clear, or select something.
    - Never choose a destructive or clearing tool for an informational question.
    - Do not invent opaque IDs. If a required argument looks like an ID but the user gave a visible name, leave that ID out of arguments and put the visible name in entity_reference.
    - Fill arguments only from the user's message or safe schema defaults. Do not fabricate birth data, gender, date, or time.

    Available MCP tools:
    \(tools)

    User message:
    \(request.prompt.trimmedForPrompt(limit: 2_000))
    """
  }

  static func toolSummary(_ tool: [String: Any]) -> String {
    let name = tool["name"] as? String ?? "unknown"
    let title =
      (tool["title"] as? String) ??
      ((tool["annotations"] as? [String: Any])?["title"] as? String) ??
      name
    let description = (tool["description"] as? String)?.oneLineForPrompt(limit: 520) ?? ""
    let annotations = tool["annotations"] as? [String: Any] ?? [:]
    let readOnly = (annotations["readOnlyHint"] as? Bool).map(String.init) ?? "unknown"
    let destructive = (annotations["destructiveHint"] as? Bool).map(String.init) ?? "unknown"
    let schema = tool["inputSchema"] as? [String: Any] ?? [:]
    let required = (schema["required"] as? [String] ?? []).joined(separator: ", ")
    let properties = (schema["properties"] as? [String: Any] ?? [:])
      .sorted { $0.key < $1.key }
      .map { key, raw -> String in
        guard let property = raw as? [String: Any] else { return key }
        let type = property["type"] as? String ?? "any"
        let desc = (property["description"] as? String)?.oneLineForPrompt(limit: 140) ?? ""
        let hasDefault = property["default"] == nil ? "" : " default"
        return "\(key):\(type)\(hasDefault)\(desc.isEmpty ? "" : " - \(desc)")"
      }
      .joined(separator: "; ")
      .trimmedForPrompt(limit: 1_000)
    return """
    - name: \(name)
      title: \(title)
      readOnly: \(readOnly)
      destructive: \(destructive)
      required: [\(required)]
      parameters: \(properties)
      description: \(description)
    """
  }
}

enum UgotMCPToolApprovalPolicy: String, CaseIterable, Codable, Identifiable {
  case allow
  case ask
  case deny

  var id: String { rawValue }

  var title: String {
    switch self {
    case .allow: return "자동 허용"
    case .ask: return "매번 승인"
    case .deny: return "차단"
    }
  }

  var detail: String {
    switch self {
    case .allow: return "AI가 이 도구를 바로 실행할 수 있어요."
    case .ask: return "실행 전에 승인 모달을 띄워요."
    case .deny: return "AI가 이 도구를 실행하지 못해요."
    }
  }

  var symbol: String {
    switch self {
    case .allow: return "checkmark.shield"
    case .ask: return "hand.raised"
    case .deny: return "nosign"
    }
  }
}

struct UgotMCPToolDescriptor: Identifiable, Hashable {
  let connectorId: String
  let name: String
  let title: String
  let summary: String
  let isReadOnly: Bool
  let isDestructive: Bool
  let hasWidget: Bool
  let requiredParameters: [String]

  var id: String { "\(connectorId)::\(name)" }

  var defaultApprovalPolicy: UgotMCPToolApprovalPolicy {
    (isDestructive || !isReadOnly) ? .ask : .allow
  }

  init(connectorId: String, tool: [String: Any]) {
    self.connectorId = connectorId
    let rawName = tool["name"] as? String ?? "unknown_tool"
    name = rawName
    title = Self.displayTitle(for: tool, fallbackName: rawName)
    summary = (tool["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    isReadOnly = Self.isReadOnly(tool: tool)
    isDestructive = Self.isDestructive(tool: tool)
    hasWidget = UgotMCPClient.widgetResourceURI(from: tool) != nil
    if let schema = tool["inputSchema"] as? [String: Any],
       let required = schema["required"] as? [String] {
      requiredParameters = required.sorted()
    } else {
      requiredParameters = []
    }
  }

  private static func displayTitle(for tool: [String: Any], fallbackName: String) -> String {
    if let title = tool["title"] as? String, !title.isEmpty { return title }
    if let annotations = tool["annotations"] as? [String: Any],
       let title = annotations["title"] as? String,
       !title.isEmpty {
      return title
    }
    return fallbackName
      .replacingOccurrences(of: "_", with: " ")
      .replacingOccurrences(of: "-", with: " ")
      .split(separator: " ")
      .map { $0.prefix(1).uppercased() + $0.dropFirst() }
      .joined(separator: " ")
  }

  private static func isDestructive(tool: [String: Any]) -> Bool {
    if let annotations = tool["annotations"] as? [String: Any],
       let destructive = annotations["destructiveHint"] as? Bool {
      return destructive
    }
    let name = ((tool["name"] as? String) ?? "").lowercased()
    return ["delete", "remove", "clear", "reset"].contains { name.contains($0) }
  }

  private static func isReadOnly(tool: [String: Any]) -> Bool {
    if let annotations = tool["annotations"] as? [String: Any],
       let readOnly = annotations["readOnlyHint"] as? Bool {
      return readOnly
    }
    return false
  }
}

struct UgotMCPPendingToolApproval: Codable, Equatable {
  let sessionId: String
  let connectorId: String
  let toolName: String
  let toolTitle: String
  let argumentsJson: String
  let userPrompt: String?
  let requestedAt: Date

  var arguments: [String: Any] {
    guard let data = argumentsJson.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return [:]
    }
    return object
  }
}

enum UgotMCPToolApprovalStore {
  private static let policyPrefix = "ugot.mcp.toolApprovalPolicy"
  private static let pendingPrefix = "ugot.mcp.pendingToolApproval"
  private static let defaults = UserDefaults.standard

  static func policy(
    connectorId: String,
    toolName: String,
    defaultPolicy: UgotMCPToolApprovalPolicy
  ) -> UgotMCPToolApprovalPolicy {
    guard let rawValue = defaults.string(forKey: policyKey(connectorId: connectorId, toolName: toolName)),
          let policy = UgotMCPToolApprovalPolicy(rawValue: rawValue) else {
      return defaultPolicy
    }
    return policy
  }

  static func policy(connectorId: String, descriptor: UgotMCPToolDescriptor) -> UgotMCPToolApprovalPolicy {
    policy(connectorId: connectorId, toolName: descriptor.name, defaultPolicy: descriptor.defaultApprovalPolicy)
  }

  static func setPolicy(_ policy: UgotMCPToolApprovalPolicy, connectorId: String, toolName: String) {
    defaults.set(policy.rawValue, forKey: policyKey(connectorId: connectorId, toolName: toolName))
  }

  static func pendingApproval(sessionId: String, connectorIds: Set<String>) -> UgotMCPPendingToolApproval? {
    for connectorId in connectorIds.sorted() {
      let key = pendingKey(sessionId: sessionId, connectorId: connectorId)
      guard let data = defaults.data(forKey: key),
            let pending = try? JSONDecoder().decode(UgotMCPPendingToolApproval.self, from: data) else {
        continue
      }
      return pending
    }
    return nil
  }

  static func pendingConnectorId(sessionId: String, connectorIds: Set<String>) -> String? {
    pendingApproval(sessionId: sessionId, connectorIds: connectorIds)?.connectorId
  }

  static func savePending(
    sessionId: String,
    connectorId: String,
    toolName: String,
    toolTitle: String,
    arguments: [String: Any],
    userPrompt: String?
  ) {
    let data = (try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])) ?? Data("{}".utf8)
    let pending = UgotMCPPendingToolApproval(
      sessionId: sessionId,
      connectorId: connectorId,
      toolName: toolName,
      toolTitle: toolTitle,
      argumentsJson: String(data: data, encoding: .utf8) ?? "{}",
      userPrompt: userPrompt,
      requestedAt: Date()
    )
    if let encoded = try? JSONEncoder().encode(pending) {
      defaults.set(encoded, forKey: pendingKey(sessionId: sessionId, connectorId: connectorId))
    }
  }

  static func clearPending(sessionId: String, connectorId: String) {
    defaults.removeObject(forKey: pendingKey(sessionId: sessionId, connectorId: connectorId))
  }

  private static func policyKey(connectorId: String, toolName: String) -> String {
    "\(policyPrefix).\(stableKey(connectorId)).\(stableKey(toolName))"
  }

  private static func pendingKey(sessionId: String, connectorId: String) -> String {
    "\(pendingPrefix).\(stableKey(sessionId)).\(stableKey(connectorId))"
  }

  private static func stableKey(_ value: String) -> String {
    Data(value.utf8).base64EncodedString()
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "=", with: "")
  }
}

private enum UgotMCPToolMetadataCache {
  private static let ttl: TimeInterval = 300
  private static let persistentTTL: TimeInterval = 86_400
  private static let persistentPrefix = "ugot.mcp.toolMetadataCache.v3"
  private static let lock = NSLock()
  private static var values: [String: (timestamp: Date, tools: [[String: Any]])] = [:]

  static func tools(
    connectorId: String,
    loader: () async throws -> [[String: Any]]
  ) async throws -> [[String: Any]] {
    let now = Date()
    if let tools = lock.withLock({ () -> [[String: Any]]? in
      guard let cached = values[connectorId], now.timeIntervalSince(cached.timestamp) < ttl else {
        return nil
      }
      return cached.tools
    }) {
      return tools
    }

    if let cached = persistedTools(connectorId: connectorId, now: now) {
      lock.withLock {
        values[connectorId] = (Date(), cached)
      }
      return cached
    }

    let loaded = try await loader()
    lock.withLock {
      values[connectorId] = (Date(), loaded)
    }
    persistTools(loaded, connectorId: connectorId)
    return loaded
  }

  private static func persistedTools(connectorId: String, now: Date) -> [[String: Any]]? {
    guard let data = UserDefaults.standard.data(forKey: persistentKey(connectorId)),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let timestamp = object["timestamp"] as? TimeInterval,
          now.timeIntervalSince(Date(timeIntervalSince1970: timestamp)) < persistentTTL,
          let tools = object["tools"] as? [[String: Any]],
          !tools.isEmpty else {
      return nil
    }
    return tools
  }

  private static func persistTools(_ tools: [[String: Any]], connectorId: String) {
    guard JSONSerialization.isValidJSONObject(tools) else { return }
    let payload: [String: Any] = [
      "timestamp": Date().timeIntervalSince1970,
      "tools": tools,
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
    UserDefaults.standard.set(data, forKey: persistentKey(connectorId))
  }

  private static func persistentKey(_ connectorId: String) -> String {
    let safeId = Data(connectorId.utf8).base64EncodedString()
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "=", with: "")
    return "\(persistentPrefix).\(safeId)"
  }
}

private struct UgotMCPToolCatalog {
  let allTools: [[String: Any]]
  let modelVisibleTools: [[String: Any]]
  let modelVisibleToolSearchIndex: UgotMCPToolSearchIndex

  init(
    tools: [[String: Any]],
    sourceName: String?,
    sourceDescription: String?
  ) {
    self.allTools = tools
    self.modelVisibleTools = UgotMCPToolVisibility.modelVisibleTools(from: tools)
    self.modelVisibleToolSearchIndex = UgotMCPToolSearchIndex(
      tools: modelVisibleTools,
      sourceName: sourceName,
      sourceDescription: sourceDescription
    )
  }
}

private enum UgotMCPToolCatalogCache {
  private static let ttl: TimeInterval = 300
  private static let lock = NSLock()
  private static var values: [String: (timestamp: Date, catalog: UgotMCPToolCatalog)] = [:]

  static func catalog(
    connectorId: String,
    sourceName: String?,
    sourceDescription: String?,
    loader: () async throws -> [[String: Any]]
  ) async throws -> UgotMCPToolCatalog {
    let now = Date()
    if let catalog = lock.withLock({ () -> UgotMCPToolCatalog? in
      guard let cached = values[connectorId], now.timeIntervalSince(cached.timestamp) < ttl else {
        return nil
      }
      return cached.catalog
    }) {
      return catalog
    }

    let tools = try await UgotMCPToolMetadataCache.tools(connectorId: connectorId, loader: loader)
    let catalog = UgotMCPToolCatalog(
      tools: tools,
      sourceName: sourceName,
      sourceDescription: sourceDescription
    )
    lock.withLock {
      values[connectorId] = (Date(), catalog)
    }
    return catalog
  }
}

private enum UgotMCPToolVisibility {
  static func modelVisibleTools(from tools: [[String: Any]]) -> [[String: Any]] {
    tools.filter { !isAppOnly($0) }
  }

  static func isAppOnly(_ tool: [String: Any]) -> Bool {
    if let meta = tool["_meta"] as? [String: Any] {
      if visibilityIsAppOnly(meta["ui/visibility"]) {
        return true
      }
      if let ui = meta["ui"] as? [String: Any],
         visibilityIsAppOnly(ui["visibility"]) {
        return true
      }
    }
    if isModelSideReasoningOnly(tool) {
      return true
    }
    return false
  }

  private static func visibilityIsAppOnly(_ value: Any?) -> Bool {
    let rawValues: [String]
    if let string = value as? String {
      rawValues = [string]
    } else if let strings = value as? [String] {
      rawValues = strings
    } else if let values = value as? [Any] {
      rawValues = values.compactMap { $0 as? String }
    } else {
      return false
    }

    let normalized = Set(rawValues.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
    return normalized.contains("app") && !normalized.contains("model")
  }

  private static func isModelSideReasoningOnly(_ tool: [String: Any]) -> Bool {
    let document = UgotMCPToolSearchIndex.document(for: tool)
    return document.contains("model side reasoning only") ||
      document.contains("model side context only") ||
      document.contains("internal reasoning only")
  }
}


private enum UgotMCPPromptEntityExtractor {
  static func entityText(from prompt: String) -> String? {
    let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if let quoted = firstQuotedSpan(in: trimmed) {
      return quoted
    }
    if let patterned = firstPatternTarget(in: trimmed) {
      return patterned
    }
    return lastMeaningfulToken(in: trimmed)
  }

  private static func firstQuotedSpan(in text: String) -> String? {
    let quotePairs: [(Character, Character)] = [("\"", "\""), ("'", "'"), ("“", "”"), ("‘", "’")]
    for (open, close) in quotePairs {
      guard let start = text.firstIndex(of: open) else { continue }
      let rest = text[text.index(after: start)...]
      guard let end = rest.firstIndex(of: close) else { continue }
      let value = cleanCandidate(String(rest[..<end]))
      if let value { return value }
    }
    return nil
  }

  private static func firstPatternTarget(in text: String) -> String? {
    let patterns = [
      #"(?i)(?:default\s+(?:saved\s+)?user|default\s+profile)\s+(?:to|as)?\s*([\p{L}\p{N}._-]{1,40})"#,
      #"(?i)(?:set|change|make|select)\s+(?:the\s+)?(?:default\s+(?:saved\s+)?user|default\s+profile)\s+(?:to|as)?\s*([\p{L}\p{N}._-]{1,40})"#,
      #"([\p{L}\p{N}._-]{1,40})(?:을|를)?\s*(?:기본\s*사용자|기본\s*프로필|대표\s*사용자)\s*(?:로|으로)?\s*(?:설정|변경|바꿔|해)"#,
      #"(?:기본\s*사용자|기본\s*프로필|대표\s*사용자)(?:를|을)?\s*([\p{L}\p{N}._-]{1,40})\s*(?:로|으로)?\s*(?:설정|변경|바꿔|해)"#,
      #"([\p{L}\p{N}._-]{1,40})\s*(?:로|으로)\s*(?:설정|변경|바꿔|해)"#,
    ]
    for pattern in patterns {
      guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
      let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
      guard let match = regex.firstMatch(in: text, range: nsRange), match.numberOfRanges > 1,
            let range = Range(match.range(at: 1), in: text) else {
        continue
      }
      if let value = cleanCandidate(String(text[range])) {
        return value
      }
    }
    return nil
  }

  private static func lastMeaningfulToken(in text: String) -> String? {
    text
      .replacingOccurrences(of: "[^\\p{L}\\p{N}._-]+", with: " ", options: .regularExpression)
      .split(separator: " ")
      .compactMap { cleanCandidate(String($0)) }
      .last
  }

  private static func cleanCandidate(_ raw: String) -> String? {
    var value = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    guard !value.isEmpty else { return nil }

    for suffix in koreanCaseSuffixes where value.count > suffix.count {
      if value.hasSuffix(suffix) {
        value.removeLast(suffix.count)
        break
      }
    }
    value = value.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    guard !value.isEmpty else { return nil }

    let key = value.lowercased()
    guard !stopwords.contains(key) else { return nil }
    guard key.range(of: #"[\p{L}\p{N}]"#, options: .regularExpression) != nil else { return nil }
    return value
  }

  private static let koreanCaseSuffixes = [
    "으로", "에게", "한테", "부터", "까지", "처럼", "보다", "으로는",
    "로", "을", "를", "은", "는", "이", "가", "의", "도", "만", "요",
  ]

  private static let stopwords: Set<String> = [
    "a", "an", "the", "to", "for", "of", "with", "as", "by",
    "default", "user", "profile", "person", "member", "saved",
    "set", "change", "update", "select", "save", "delete", "clear", "remove", "make",
    "기본", "사용자", "기본사용자", "프로필", "기본프로필", "대표", "대표사용자",
    "로", "으로", "을", "를", "은", "는", "이", "가",
    "저장", "저장목록", "저장된", "사람", "대상", "계정",
    "설정", "설정해", "설정해줘", "변경", "변경해", "변경해줘",
    "바꿔", "바꿔줘", "바꿔주세요", "해", "해줘", "해주세요",
  ]
}

private struct UgotMCPToolPlan {
  let tool: [String: Any]
  let name: String
  let title: String
  let arguments: [String: Any]
  let score: Int
  let entityReference: String?

  func with(arguments: [String: Any]) -> UgotMCPToolPlan {
    UgotMCPToolPlan(
      tool: tool,
      name: name,
      title: title,
      arguments: arguments,
      score: score,
      entityReference: entityReference
    )
  }
}

private enum UgotMCPToolPlanner {
  static let minimumSearchScoreForPlanning = 8
  private static let minimumDirectMetadataMutationScore = 36
  private static let minimumDirectMetadataMutationMargin = 8

  static func toolsForModelPlanning(
    prompt: String,
    tools: [[String: Any]],
    searchIndex: UgotMCPToolSearchIndex? = nil,
    limit: Int = 18
  ) -> [[String: Any]] {
    let eligibleTools = searchIndex?.eligibleTools(query: prompt) ?? tools
    let searched = (searchIndex ?? UgotMCPToolSearchIndex(tools: tools)).search(query: prompt, limit: limit)
    guard !searched.isEmpty else {
      return Array(eligibleTools.prefix(limit))
    }

    var selected = searched.map(\.tool)
    let selectedNames = Set(selected.compactMap { $0["name"] as? String })
    let remaining = eligibleTools.filter { tool in
      guard let name = tool["name"] as? String else { return false }
      return !selectedNames.contains(name)
    }
    selected.append(contentsOf: remaining.prefix(max(0, limit - selected.count)))
    return Array(selected.prefix(limit))
  }

  static func plan(
    prompt: String,
    tools: [[String: Any]],
    searchIndex: UgotMCPToolSearchIndex? = nil,
    decision: UgotMCPToolPlanningDecision?
  ) -> UgotMCPToolPlan? {
    if let decision,
       decision.shouldUseTool,
       let plan = planFromDecision(decision, tools: tools) {
      return plan
    }
    return planFromMetadataSearch(prompt: prompt, tools: tools, searchIndex: searchIndex)
  }

  private static func planFromDecision(
    _ decision: UgotMCPToolPlanningDecision,
    tools: [[String: Any]]
  ) -> UgotMCPToolPlan? {
    guard let requestedName = decision.toolName?.trimmingCharacters(in: .whitespacesAndNewlines),
          !requestedName.isEmpty,
          let tool = tools.first(where: { (($0["name"] as? String) ?? "").caseInsensitiveCompare(requestedName) == .orderedSame }),
          let name = tool["name"] as? String else {
      return nil
    }

    let sanitized = sanitizedArguments(decision.arguments, for: tool)
    let normalized = normalizeOpaqueArguments(
      sanitized,
      for: tool,
      existingEntityReference: decision.entityReference
    )
    let arguments = argumentsWithDefaults(normalized.arguments, for: tool)
    let score = max(0, min(100, Int((decision.confidence * 100).rounded())))
    return UgotMCPToolPlan(
      tool: tool,
      name: name,
      title: displayTitle(for: tool, fallbackName: name),
      arguments: arguments,
      score: score,
      entityReference: normalized.entityReference
    )
  }

  private static func planFromMetadataSearch(
    prompt: String,
    tools: [[String: Any]],
    searchIndex: UgotMCPToolSearchIndex?
  ) -> UgotMCPToolPlan? {
    let searched = (searchIndex ?? UgotMCPToolSearchIndex(tools: tools)).search(query: prompt, limit: 6)
    let ranked = searched.enumerated().compactMap { index, result -> UgotMCPToolPlan? in
      guard result.score >= minimumSearchScoreForPlanning,
            let name = result.tool["name"] as? String,
            !name.isEmpty else {
        return nil
      }
      let isReadOnlyTool = isReadOnly(tool: result.tool)
      if !isReadOnlyTool {
        // Mutating/data-only tools can still be metadata-routed when the match
        // is very strong. This avoids a slow extra LLM planner turn for clear
        // commands like “set default user to YW”, while approval policy still
        // gates execution before any mutation happens.
        guard isHighConfidenceMetadataMutationResult(
          result,
          at: index,
          allResults: searched
        ) else {
          return nil
        }
      }

      let seededArguments = metadataSeedArguments(prompt: prompt, for: result.tool)
      let arguments = argumentsWithDefaults(seededArguments, for: result.tool)
      let missing = missingRequiredArguments(for: result.tool, arguments: arguments)
      if isReadOnlyTool {
        guard missing.isEmpty else { return nil }
      } else {
        // Missing opaque IDs can be resolved by `preparePlanForExecution`
        // through the connector's own read-only resolver/list tools. Other
        // required values must not be fabricated by metadata search.
        guard missing.allSatisfy(isOpaqueReferenceParameter) else { return nil }
      }
      let entityReference = missing.contains(where: isOpaqueReferenceParameter)
        ? UgotMCPPromptEntityExtractor.entityText(from: prompt)
        : nil
      return UgotMCPToolPlan(
        tool: result.tool,
        name: name,
        title: displayTitle(for: result.tool, fallbackName: name),
        arguments: arguments,
        score: result.score,
        entityReference: entityReference
      )
    }
    return ranked.sorted { lhs, rhs in
      if lhs.score != rhs.score { return lhs.score > rhs.score }
      return hasWidget(tool: lhs.tool) && !hasWidget(tool: rhs.tool)
    }.first
  }

  private static func isHighConfidenceMetadataMutationResult(
    _ result: UgotMCPToolSearchResult,
    at index: Int,
    allResults: [UgotMCPToolSearchResult]
  ) -> Bool {
    guard result.score >= minimumDirectMetadataMutationScore else { return false }
    guard index == 0 else { return false }
    let runnerUpScore = allResults.dropFirst().first?.score ?? 0
    return result.score - runnerUpScore >= minimumDirectMetadataMutationMargin ||
      result.score >= minimumDirectMetadataMutationScore + minimumDirectMetadataMutationMargin
  }

  private static func metadataSeedArguments(prompt: String, for tool: [String: Any]) -> [String: Any] {
    guard let properties = inputProperties(for: tool),
          let required = (tool["inputSchema"] as? [String: Any])?["required"] as? [String],
          !required.isEmpty,
          let entity = metadataEntityText(from: prompt) else {
      return [:]
    }

    var out: [String: Any] = [:]
    for key in required where out[key] == nil {
      guard let property = properties[key] as? [String: Any] else { continue }
      let type = (property["type"] as? String)?.lowercased()
      guard type == nil || type == "string" else { continue }
      let lower = key.lowercased()
      guard lower == "search" ||
        lower == "query" ||
        lower == "q" ||
        lower == "name" ||
        lower.contains("name") ||
        lower.contains("search") ||
        lower.contains("query") else {
        continue
      }
      out[key] = entity
    }
    return out
  }

  private static func metadataEntityText(from prompt: String) -> String? {
    UgotMCPPromptEntityExtractor.entityText(from: prompt)
  }

  private static func sanitizedArguments(_ raw: [String: Any], for tool: [String: Any]) -> [String: Any] {
    guard let properties = inputProperties(for: tool) else { return [:] }
    var out: [String: Any] = [:]
    for (key, value) in raw {
      guard properties[key] != nil, !(value is NSNull) else { continue }
      if let dict = value as? [String: Any], dict["$resolve"] != nil {
        continue
      }
      out[key] = value
    }
    return out
  }

  private static func normalizeOpaqueArguments(
    _ arguments: [String: Any],
    for tool: [String: Any],
    existingEntityReference: String?
  ) -> (arguments: [String: Any], entityReference: String?) {
    var out = arguments
    var entityReference = existingEntityReference?.trimmingCharacters(in: .whitespacesAndNewlines)
    for key in out.keys where isOpaqueReferenceParameter(key) {
      guard let value = out[key] else { continue }
      if let string = value as? String {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, !isLikelyOpaqueIdentifier(trimmed) {
          if entityReference?.isEmpty != false {
            entityReference = trimmed
          }
          out.removeValue(forKey: key)
        }
      }
    }
    return (out, entityReference?.isEmpty == false ? entityReference : nil)
  }

  private static func argumentsWithDefaults(_ arguments: [String: Any], for tool: [String: Any]) -> [String: Any] {
    guard let properties = inputProperties(for: tool) else { return arguments }
    var out = arguments
    for (key, rawProperty) in properties where out[key] == nil {
      guard let property = rawProperty as? [String: Any] else { continue }
      if let value = property["default"], !(value is NSNull) {
        out[key] = value
      }
    }
    return out
  }

  private static func missingRequiredArguments(for tool: [String: Any], arguments: [String: Any]) -> [String] {
    guard let schema = tool["inputSchema"] as? [String: Any],
          let required = schema["required"] as? [String],
          !required.isEmpty else {
      return []
    }
    return required.filter { name in
      guard let value = arguments[name], !(value is NSNull) else { return true }
      if let string = value as? String {
        return string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }
      return false
    }
  }

  private static func inputProperties(for tool: [String: Any]) -> [String: Any]? {
    (tool["inputSchema"] as? [String: Any])?["properties"] as? [String: Any]
  }

  private static func displayTitle(for tool: [String: Any], fallbackName: String) -> String {
    if let title = tool["title"] as? String, !title.isEmpty { return title }
    if let annotations = tool["annotations"] as? [String: Any],
       let title = annotations["title"] as? String,
       !title.isEmpty {
      return title
    }
    return fallbackName
      .replacingOccurrences(of: "_", with: " ")
      .replacingOccurrences(of: "-", with: " ")
      .split(separator: " ")
      .map { $0.prefix(1).uppercased() + $0.dropFirst() }
      .joined(separator: " ")
  }

  private static func hasWidget(tool: [String: Any]) -> Bool {
    UgotMCPClient.widgetResourceURI(from: tool) != nil
  }

  private static func isReadOnly(tool: [String: Any]) -> Bool {
    if let annotations = tool["annotations"] as? [String: Any],
       let readOnly = annotations["readOnlyHint"] as? Bool {
      return readOnly
    }
    return false
  }

  private static func isOpaqueReferenceParameter(_ rawName: String) -> Bool {
    let name = rawName.lowercased()
    return name == "id" ||
      name.hasSuffix("_id") ||
      name.hasSuffix("id") ||
      name.contains("uuid") ||
      name.contains("identifier")
  }

  private static func isLikelyOpaqueIdentifier(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.range(of: #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#, options: .regularExpression) != nil {
      return true
    }
    if trimmed.range(of: #"^[0-9a-fA-F]{24}$"#, options: .regularExpression) != nil {
      return true
    }
    if trimmed.range(of: #"^[A-Za-z]+_[A-Za-z0-9_-]{8,}$"#, options: .regularExpression) != nil {
      return true
    }
    let compact = trimmed.replacingOccurrences(of: "[^A-Za-z0-9_-]+", with: "", options: .regularExpression)
    return compact.count >= 16 && compact == trimmed
  }
}

final class UgotMCPConnectorAction {
  private let connector: GalleryConnector
  private let mcpClient: UgotMCPRuntimeClient
  private let sessionId: String
  private let toolPlanningProvider: UgotMCPActionRunner.ToolPlanningProvider?

  var connectorId: String { connector.id }
  var connectorTitle: String { connector.title }
  var connectorSummary: String { connector.summary }

  init(
    connector: GalleryConnector,
    accessToken: String,
    sessionId: String,
    toolPlanningProvider: UgotMCPActionRunner.ToolPlanningProvider? = nil
  ) {
    self.connector = connector
    self.sessionId = sessionId
    self.toolPlanningProvider = toolPlanningProvider
    self.mcpClient = UgotMCPRuntimeClient.make(
      connectorId: connector.id,
      endpoint: URL(string: connector.endpoint)!,
      accessToken: accessToken
    )
  }

  private func loadCatalog() async throws -> UgotMCPToolCatalog {
    try await UgotMCPToolCatalogCache.catalog(
      connectorId: connector.id,
      sourceName: nil,
      sourceDescription: nil
    ) {
      try await mcpClient.initialize()
      return try await mcpClient.listTools()
    }
  }

  func warmToolCatalog() async throws {
    _ = try await loadCatalog()
  }

  func planningCandidate(prompt: String) async throws -> UgotMCPConnectorToolSearchCandidate? {
    let catalog = try await loadCatalog()
    let planningTools = catalog.modelVisibleTools
    guard !planningTools.isEmpty else { return nil }
    let searchResults = catalog.modelVisibleToolSearchIndex.search(query: prompt, limit: 6)
    let toolSearchScore = searchResults.first?.score ?? 0
    let sourceSearchScore = connectorSourceSearchScore(prompt: prompt)
    let searchScore = max(toolSearchScore, sourceSearchScore)
    guard searchScore >= UgotMCPToolPlanner.minimumSearchScoreForPlanning else {
      return nil
    }
    let topTools = UgotMCPToolPlanner.toolsForModelPlanning(
      prompt: prompt,
      tools: planningTools,
      searchIndex: catalog.modelVisibleToolSearchIndex,
      limit: 8
    )
    return UgotMCPConnectorToolSearchCandidate(
      connectorId: connector.id,
      connectorTitle: connector.title,
      connectorSummary: connector.summary,
      searchScore: searchScore,
      topTools: topTools
    )
  }

  func run(
    prompt: String,
    emitNoToolFailure: Bool = true
  ) async throws -> UgotMCPActionResponse? {
    let catalog = try await loadCatalog()
    let tools = catalog.allTools
    if let pending = UgotMCPToolApprovalStore.pendingApproval(
      sessionId: sessionId,
      connectorIds: [connector.id]
    ) {
      return UgotMCPActionResponse(
        message: "",
        snapshot: nil,
        approvalRequest: UgotMCPToolApprovalRequest(
          sessionId: pending.sessionId,
          connectorId: pending.connectorId,
          connectorTitle: connector.title,
          toolName: pending.toolName,
          toolTitle: pending.toolTitle,
          argumentsPreview: pending.argumentsJson,
          userPrompt: pending.userPrompt
        )
      )
    }

    let planningTools = catalog.modelVisibleTools
    guard !planningTools.isEmpty else {
      if emitNoToolFailure {
        return UgotMCPActionResponse(
          message: "이 connector에는 대화에서 직접 실행할 수 있는 MCP 도구가 없어요.",
          snapshot: nil
        )
      }
      return nil
    }

    let topSearchScore = max(
      catalog.modelVisibleToolSearchIndex.topScore(query: prompt),
      connectorSourceSearchScore(prompt: prompt)
    )
    guard topSearchScore >= UgotMCPToolPlanner.minimumSearchScoreForPlanning else {
      return nil
    }

    if let planned = UgotMCPToolPlanner.plan(
      prompt: prompt,
      tools: planningTools,
      searchIndex: catalog.modelVisibleToolSearchIndex,
      decision: nil
    ) {
      return try await executePlannedTool(planned, prompt: prompt, allTools: tools)
    }

    let modelPlanningTools = UgotMCPToolPlanner.toolsForModelPlanning(
      prompt: prompt,
      tools: planningTools,
      searchIndex: catalog.modelVisibleToolSearchIndex
    )
    let decision = await toolPlanningProvider?(UgotMCPToolPlanningRequest(
      prompt: prompt,
      connectorId: connector.id,
      connectorTitle: connector.title,
      tools: modelPlanningTools
    ))
    guard let planned = UgotMCPToolPlanner.plan(
      prompt: prompt,
      tools: modelPlanningTools,
      decision: decision
    ) else {
      if decision?.requiresTool == true, emitNoToolFailure {
        return UgotMCPActionResponse(
          message: """
          실행할 수 있는 MCP 도구를 찾지 못해서 아무 작업도 하지 않았어요.

          도구 승인 목록에서 connector와 도구가 켜져 있는지 확인하거나, 대상을 더 구체적으로 말해 주세요.
          """,
          snapshot: nil
        )
      }
      return nil
    }
    return try await executePlannedTool(planned, prompt: prompt, allTools: tools)
  }

  private func connectorSourceSearchScore(prompt: String) -> Int {
    UgotMCPToolSearchIndex.searchScore(
      query: prompt,
      document: "\(connector.title) \(connector.summary)"
    ).score
  }

  private func executePlannedTool(
    _ planned: UgotMCPToolPlan,
    prompt: String,
    allTools tools: [[String: Any]]
  ) async throws -> UgotMCPActionResponse {
    let plan = try await preparePlanForExecution(planned, prompt: prompt, tools: tools)
    let missingArguments = missingRequiredArguments(for: plan.tool, arguments: plan.arguments)
    if !missingArguments.isEmpty {
      return UgotMCPActionResponse(
        message: """
        \(plan.title) 도구를 실행하려면 \(missingArguments.joined(separator: ", ")) 값이 더 필요해요.

        예: “기본사용자를 Yw로 바꿔”처럼 대상 이름을 함께 말하거나, 먼저 저장목록에서 대상을 선택해 주세요.
        """,
        snapshot: nil
      )
    }
    let descriptor = UgotMCPToolDescriptor(connectorId: connector.id, tool: plan.tool)
    let policy = UgotMCPToolApprovalStore.policy(connectorId: connector.id, descriptor: descriptor)
    switch policy {
    case .deny:
      return UgotMCPActionResponse(
        message: """
        \(plan.title) 도구는 현재 차단되어 있어요.

        상단 슬라이더 → 도구 승인 → \(connector.title)에서 정책을 바꿀 수 있어요.
        """,
        snapshot: nil
      )
    case .ask:
      let argumentsPreview = compactArguments(plan.arguments)
      UgotMCPToolApprovalStore.savePending(
        sessionId: sessionId,
        connectorId: connector.id,
        toolName: plan.name,
        toolTitle: plan.title,
        arguments: plan.arguments,
        userPrompt: prompt
      )
      return UgotMCPActionResponse(
        message: "",
        snapshot: nil,
        approvalRequest: UgotMCPToolApprovalRequest(
          sessionId: sessionId,
          connectorId: connector.id,
          connectorTitle: connector.title,
          toolName: plan.name,
          toolTitle: plan.title,
          argumentsPreview: argumentsPreview,
          userPrompt: prompt
        )
      )
    case .allow:
      return try await executeTool(
        toolName: plan.name,
        title: plan.title,
        arguments: plan.arguments,
        tools: tools
      )
    }
  }

  private func preparePlanForExecution(
    _ plan: UgotMCPToolPlan,
    prompt: String,
    tools: [[String: Any]]
  ) async throws -> UgotMCPToolPlan {
    let missing = missingRequiredArguments(for: plan.tool, arguments: plan.arguments)
    guard !missing.isEmpty else { return plan }

    var arguments = plan.arguments
    var didResolve = false
    for parameterName in missing where isOpaqueReferenceParameter(parameterName) {
      guard arguments[parameterName] == nil else { continue }
      if let resolved = try await resolveOpaqueReference(
        parameterName: parameterName,
        prompt: prompt,
        entityReference: plan.entityReference,
        targetToolName: plan.name,
        tools: tools
      ) {
        arguments[parameterName] = resolved
        didResolve = true
      }
    }

    return didResolve ? plan.with(arguments: arguments) : plan
  }

  private func resolveOpaqueReference(
    parameterName: String,
    prompt: String,
    entityReference: String?,
    targetToolName: String,
    tools: [[String: Any]]
  ) async throws -> Any? {
    let trimmedEntityReference = entityReference?.trimmingCharacters(in: .whitespacesAndNewlines)
    let searchText = trimmedEntityReference?.isEmpty == false
      ? trimmedEntityReference
      : entitySearchText(from: prompt)
    guard let searchText else { return nil }
    guard let resolver = resolverTool(
      parameterName: parameterName,
      targetToolName: targetToolName,
      searchText: searchText,
      tools: tools
    ) else {
      return nil
    }
    let result = try await mcpClient.callTool(name: resolver.name, arguments: resolver.arguments)
    return extractResolvedValue(
      from: result,
      preferredKeys: preferredResolverKeys(for: parameterName)
    )
  }

  private func resolverTool(
    parameterName: String,
    targetToolName: String,
    searchText: String,
    tools: [[String: Any]]
  ) -> (name: String, arguments: [String: Any])? {
    let parameterTerms = parameterName
      .replacingOccurrences(of: "_", with: " ")
      .replacingOccurrences(of: "-", with: " ")
    let query = "\(searchText) \(parameterTerms) find search lookup list saved registered profile user"
    let candidates = UgotMCPToolSearchIndex(tools: tools).search(query: query, limit: 8)

    let ranked = candidates.compactMap { result -> (tool: [String: Any], name: String, arguments: [String: Any], score: Int)? in
      guard let name = result.tool["name"] as? String,
            name != targetToolName,
            !isDestructiveTool(result.tool) else {
        return nil
      }
      guard let searchParameter = fillableSearchParameter(in: result.tool) else {
        return nil
      }
      let document = UgotMCPToolSearchIndex.document(for: result.tool)
      let resolverWords = ["find", "search", "lookup", "resolve", "list", "get", "saved", "registered", "profile", "user"]
      guard resolverWords.contains(where: { document.contains($0) }) else {
        return nil
      }

      var arguments: [String: Any] = [searchParameter: searchText]
      if let exactParameter = optionalBooleanParameter(namedLike: ["exact"], in: result.tool) {
        arguments[exactParameter] = true
      }
      if let limitParameter = optionalNumericParameter(namedLike: ["limit", "max"], in: result.tool) {
        arguments[limitParameter] = 5
      }
      if let langParameter = optionalStringParameter(namedLike: ["lang", "locale"], in: result.tool) {
        arguments[langParameter] = "ko"
      }

      var score = result.score
      let compactName = compactIdentifier(name)
      if compactName.contains("find") || compactName.contains("search") || compactName.contains("lookup") {
        score += 20
      }
      if compactName.contains("saved") || compactName.contains("profile") || compactName.contains("user") {
        score += 10
      }
      return (result.tool, name, arguments, score)
    }

    return ranked.sorted { $0.score > $1.score }.first.map { ($0.name, $0.arguments) }
  }

  private func entitySearchText(from prompt: String) -> String? {
    UgotMCPPromptEntityExtractor.entityText(from: prompt)
  }

  private func extractResolvedValue(from value: Any, preferredKeys: [String]) -> Any? {
    if let dict = value as? [String: Any] {
      for key in preferredKeys {
        if let exact = dict[key], !(exact is NSNull) {
          return scalarResolvedValue(exact)
        }
      }

      let normalizedPreferred = preferredKeys.map(compactIdentifier)
      for (key, raw) in dict {
        if normalizedPreferred.contains(compactIdentifier(key)),
           let scalar = scalarResolvedValue(raw) {
          return scalar
        }
      }

      for priorityKey in [
        "structuredContent",
        "structured_content",
        "best_match",
        "bestMatch",
        "match",
        "profile",
        "user",
        "saved_user",
        "savedUser",
        "users",
        "matches",
        "items",
        "nearby_matches",
        "nearbyMatches",
        "result",
        "data"
      ] {
        if let nested = dict[priorityKey],
           let resolved = extractResolvedValue(from: nested, preferredKeys: preferredKeys) {
          return resolved
        }
      }

      for (key, raw) in dict where key != "content" {
        guard raw is [String: Any] || raw is [Any] else { continue }
        if let resolved = extractResolvedValue(from: raw, preferredKeys: preferredKeys) {
          return resolved
        }
      }
      return nil
    }

    if let array = value as? [Any] {
      for item in array {
        if let resolved = extractResolvedValue(from: item, preferredKeys: preferredKeys) {
          return resolved
        }
      }
      return nil
    }

    return scalarResolvedValue(value)
  }

  private func scalarResolvedValue(_ value: Any) -> Any? {
    if let string = value as? String, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return string
    }
    if let number = value as? NSNumber {
      return number
    }
    return nil
  }

  private func preferredResolverKeys(for parameterName: String) -> [String] {
    let camel = snakeToCamel(parameterName)
    var keys = [parameterName, camel]
    if parameterName.lowercased().contains("saved") && parameterName.lowercased().contains("user") {
      keys += ["saved_user_id", "savedUserId", "user_id", "userId", "id"]
    } else {
      keys += ["id"]
    }
    var seen = Set<String>()
    return keys.filter { seen.insert($0).inserted }
  }

  private func snakeToCamel(_ value: String) -> String {
    let parts = value.split(separator: "_")
    guard let first = parts.first else { return value }
    return ([String(first)] + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }).joined()
  }

  private func missingRequiredArguments(for tool: [String: Any], arguments: [String: Any]) -> [String] {
    guard let schema = tool["inputSchema"] as? [String: Any],
          let required = schema["required"] as? [String],
          !required.isEmpty else {
      return []
    }
    return required.filter { name in
      guard let value = arguments[name], !(value is NSNull) else { return true }
      if let string = value as? String {
        return string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }
      return false
    }
  }

  private func isOpaqueReferenceParameter(_ rawName: String) -> Bool {
    let name = rawName.lowercased()
    return name == "id" ||
      name.hasSuffix("_id") ||
      name.hasSuffix("id") ||
      name.contains("uuid") ||
      name.contains("identifier")
  }

  private func fillableSearchParameter(in tool: [String: Any]) -> String? {
    guard let properties = inputProperties(for: tool) else { return nil }
    let preferred = ["search", "query", "name", "q", "term", "keyword"]
    for wanted in preferred {
      if let key = properties.keys.first(where: { $0.lowercased() == wanted }) {
        return key
      }
    }
    return properties.keys.first { key in
      let lower = key.lowercased()
      return lower.contains("search") || lower.contains("query") || lower.contains("name")
    }
  }

  private func optionalBooleanParameter(namedLike names: [String], in tool: [String: Any]) -> String? {
    optionalParameter(namedLike: names, type: "boolean", in: tool)
  }

  private func optionalNumericParameter(namedLike names: [String], in tool: [String: Any]) -> String? {
    optionalParameter(namedLike: names, types: ["integer", "number"], in: tool)
  }

  private func optionalStringParameter(namedLike names: [String], in tool: [String: Any]) -> String? {
    optionalParameter(namedLike: names, type: "string", in: tool)
  }

  private func optionalParameter(namedLike names: [String], type: String, in tool: [String: Any]) -> String? {
    optionalParameter(namedLike: names, types: [type], in: tool)
  }

  private func optionalParameter(namedLike names: [String], types: Set<String>, in tool: [String: Any]) -> String? {
    guard let properties = inputProperties(for: tool) else { return nil }
    return properties.keys.first { key in
      let lower = key.lowercased()
      guard names.contains(where: { lower.contains($0) }) else { return false }
      guard let property = properties[key] as? [String: Any],
            let rawType = property["type"] as? String else {
        return true
      }
      return types.contains(rawType.lowercased())
    }
  }

  private func inputProperties(for tool: [String: Any]) -> [String: Any]? {
    (tool["inputSchema"] as? [String: Any])?["properties"] as? [String: Any]
  }

  private func isDestructiveTool(_ tool: [String: Any]) -> Bool {
    if let annotations = tool["annotations"] as? [String: Any],
       let destructive = annotations["destructiveHint"] as? Bool {
      return destructive
    }
    let document = UgotMCPToolSearchIndex.document(for: tool)
    return ["delete", "remove", "clear", "reset", "unset"].contains { document.contains($0) }
  }

  private func compactIdentifier(_ value: String) -> String {
    value
      .lowercased()
      .replacingOccurrences(of: "[^\\p{L}\\p{N}]+", with: "", options: .regularExpression)
  }

  func runApprovedPending() async throws -> UgotMCPActionResponse? {
    let tools = try await loadCatalog().allTools
    guard let pending = UgotMCPToolApprovalStore.pendingApproval(
      sessionId: sessionId,
      connectorIds: [connector.id]
    ) else {
      return nil
    }
    UgotMCPToolApprovalStore.clearPending(sessionId: sessionId, connectorId: connector.id)
    return try await executeTool(
      toolName: pending.toolName,
      title: pending.toolTitle,
      arguments: pending.arguments,
      tools: tools
    )
  }

  private func executeTool(
    toolName: String,
    title: String,
    arguments: [String: Any],
    tools: [[String: Any]]
  ) async throws -> UgotMCPActionResponse {
    let result = try await mcpClient.callTool(name: toolName, arguments: arguments)
    let artifactContext = UgotAgentVFS.shared.ingestMCPResult(
      sessionId: sessionId,
      connectorId: connector.id,
      toolName: toolName,
      result: result
    )
    let widgetResource =
      (try? await mcpClient.resolveWidgetResource(tools: tools, toolName: toolName, result: result)) ??
      widgetResource(fromToolResult: result)
    let message = renderToolResult(result, toolName: toolName)
    let descriptor = tools
      .first(where: { ($0["name"] as? String) == toolName })
      .map { UgotMCPToolDescriptor(connectorId: connector.id, tool: $0) }
    let observation = UgotAgentToolObservation(
      connectorId: connector.id,
      connectorTitle: connector.title,
      toolName: toolName,
      toolTitle: descriptor?.title ?? title,
      argumentsPreview: compactArguments(arguments),
      outputText: message.isEmpty ? "도구가 결과 텍스트 없이 성공 상태를 반환했어요." : message,
      hasWidget: widgetResource != nil,
      didMutate: !(descriptor?.isReadOnly ?? false),
      status: "success"
    )
    guard let widgetResource else {
      // Data-only tools, e.g. preference/default-user mutations, should not go
      // through the widget WebView path. Returning a plain assistant result keeps
      // the app stable and avoids rendering an empty MCP view.
      return UgotMCPActionResponse(message: message, snapshot: nil, observation: observation)
    }
    return UgotMCPActionResponse(
      message: message,
      snapshot: makeSnapshot(
        title: title,
        toolName: toolName,
        toolInput: arguments,
        message: message,
        result: result,
        artifactContext: artifactContext,
        widgetResource: widgetResource,
        tools: tools
      ),
      observation: observation
    )
  }

  private func compactArguments(_ arguments: [String: Any]) -> String {
    guard !arguments.isEmpty,
          let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]),
          let json = String(data: data, encoding: .utf8) else {
      return "`{}`"
    }
    if json.count <= 320 {
      return "`\(json)`"
    }
    return "`\(String(json.prefix(320)))…`"
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
    return "MCP에서 \(toolName)을 실행했어요."
  }

  private func makeSnapshot(
    title: String,
    toolName: String,
    toolInput: [String: Any],
    message: String,
    result: [String: Any],
    artifactContext: String,
    widgetResource: UgotMCPWidgetResource?,
    tools: [[String: Any]] = []
  ) -> McpWidgetSnapshot {
    let compactMessage = trimForWidget(message)
    let compactArtifacts = compactArtifactContext(artifactContext)
    let compactOutput = compactToolOutput(
      result,
      message: compactMessage,
      artifactContext: compactArtifacts
    )
    let modelContext = modelContextMarkdown(
      title: title,
      toolName: toolName,
      message: compactMessage,
      result: result,
      artifactContext: compactArtifacts
    )
    var state: [String: Any] = [
      "kind": "mcp",
      "connectorId": connector.id,
      "endpoint": connector.endpoint,
      "toolName": toolName,
      "toolInput": toolInput,
      "toolOutput": compactOutput,
      "rawResult": toolResultForWidget(result),
      "contentMarkdown": compactMessage,
      "modelContext": modelContext,
    ]
    if !compactArtifacts.isEmpty {
      state["agentVfsContext"] = compactArtifacts
    }
    if let targetDate = toolInput["target_date"] {
      state["targetDate"] = targetDate
    }
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
      connectorId: connector.id,
      title: title,
      summary: firstSummaryLine(from: compactMessage),
      widgetStateJson: json
    )
  }

  private func compactToolDefinition(_ tool: [String: Any]) -> [String: Any] {
    var compact: [String: Any] = [:]
    for key in ["name", "title", "description", "inputSchema", "annotations", "_meta"] {
      if let value = tool[key] {
        compact[key] = UgotMCPClient.compactForWidget(value, maxStringLength: 2_000, maxArrayCount: 30)
      }
    }
    return compact
  }

  private func compactToolOutput(
    _ result: [String: Any],
    message: String,
    artifactContext: String
  ) -> [String: Any] {
    var compact: [String: Any] = [
      "contentMarkdown": message,
      "generatedAt": ISO8601DateFormatter().string(from: Date()),
    ]
    if !artifactContext.isEmpty {
      compact["agentVfsContext"] = artifactContext
    }
    if let structured = result["structuredContent"],
       let summary = markdownSummary(from: structured) {
      compact["structuredSummary"] = trimForWidget(summary)
    }
    let resourceReferences = embeddedResourceSummaries(in: result)
    if !resourceReferences.isEmpty {
      compact["embeddedResources"] = resourceReferences
    }
    return compact
  }

  private func modelContextMarkdown(
    title: String,
    toolName: String,
    message: String,
    result: [String: Any],
    artifactContext: String
  ) -> String {
    var sections: [String] = [
      "Widget title: \(title)",
      "Tool: \(toolName)",
    ]

    if !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      sections.append(message)
    }

    if let structured = result["structuredContent"] ?? result["structured_content"] {
      let compatibility = UgotMCPCompatibilityContextRenderer.markdown(from: structured)
      if let compatibility {
        sections.append(compatibility)
      }
      if compatibility == nil,
         let summary = markdownSummary(from: structured),
         !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
         !message.contains(summary) {
        sections.append("Structured summary:\n\(trimForWidget(summary, maxLength: 1_500))")
      }
      let keys = topLevelKeys(from: structured)
      if !keys.isEmpty {
        let joinedKeys = keys.joined(separator: ", ")
        sections.append("Structured data keys: \(joinedKeys)")
      }
    }

    let resourceReferences = embeddedResourceSummaries(in: result)
    if !resourceReferences.isEmpty {
      let lines = resourceReferences.map(resourceReferenceLine)
      sections.append("Embedded resources available to the widget:\n\(lines.joined(separator: "\n"))")
    }

    if !artifactContext.isEmpty {
      sections.append("Agent workspace files:\n\(artifactContext)")
    }

    return sections
      .joined(separator: "\n\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func embeddedResourceSummaries(in result: [String: Any]) -> [[String: Any]] {
    let content = result["content"] as? [[String: Any]] ?? []
    return content.compactMap { item -> [String: Any]? in
      if let resource = item["resource"] as? [String: Any] {
        return embeddedResourceSummary(resource)
      }
      if item["uri"] != nil || item["mimeType"] != nil || item["mime_type"] != nil {
        return embeddedResourceSummary(item)
      }
      return nil
    }
  }

  private func embeddedResourceSummary(_ resource: [String: Any]) -> [String: Any]? {
    let uri = resource["uri"] as? String
    let mimeType = resource["mimeType"] as? String ?? resource["mime_type"] as? String
    let text = itemText(resource)
    guard uri != nil || mimeType != nil || !text.isEmpty else { return nil }

    var summary: [String: Any] = [:]
    if let uri { summary["uri"] = uri }
    if let mimeType { summary["mimeType"] = mimeType }
    if !text.isEmpty {
      summary["textLength"] = text.count
      if let keys = jsonTopLevelKeys(from: text), !keys.isEmpty {
        summary["jsonKeys"] = keys
      } else {
        summary["textPreview"] = trimForWidget(text, maxLength: 500)
      }
    }
    return summary
  }

  private func resourceReferenceLine(_ resource: [String: Any]) -> String {
    let uri = resource["uri"] as? String ?? "embedded-resource"
    let mimeType = resource["mimeType"] as? String ?? "unknown"
    let textLength = resource["textLength"].map { ", \(String(describing: $0)) chars" } ?? ""
    let keys = (resource["jsonKeys"] as? [String])?.joined(separator: ", ")
    let keySuffix = keys.map { ", keys: \($0)" } ?? ""
    let preview = (resource["textPreview"] as? String).map { "\n  Preview: \($0)" } ?? ""
    return "- \(uri) (\(mimeType)\(textLength)\(keySuffix))\(preview)"
  }

  private func toolResultForWidget(_ result: [String: Any]) -> [String: Any] {
    var out: [String: Any] = [:]
    let structured = result["structuredContent"] ?? result["structured_content"]
    let isCompatibilityResult = structured.flatMap(UgotMCPCompatibilityContextRenderer.groupResult(from:)) != nil

    if !isCompatibilityResult,
       let content = result["content"] as? [[String: Any]] {
      let compactContent = content.compactMap(compactContentItemForWidget)
      if !compactContent.isEmpty {
        out["content"] = compactContent
      }
    }
    if let structured = result["structuredContent"] {
      out["structuredContent"] = UgotMCPClient.compactForWidget(structured, maxStringLength: 120_000, maxArrayCount: 160)
    }
    if let structured = result["structured_content"] {
      out["structured_content"] = UgotMCPClient.compactForWidget(structured, maxStringLength: 120_000, maxArrayCount: 160)
    }
    if let meta = result["_meta"] {
      out["_meta"] = UgotMCPClient.compactForWidget(meta, maxStringLength: 12_000, maxArrayCount: 80)
    }
    if let isError = result["isError"] {
      out["isError"] = isError
    }
    if out.isEmpty,
       let compact = UgotMCPClient.compactForWidget(result, maxStringLength: 120_000, maxArrayCount: 160) as? [String: Any] {
      return compact
    }
    return out
  }

  private func compactContentItemForWidget(_ item: [String: Any]) -> [String: Any]? {
    if let text = item["text"] as? String {
      var copy = item
      copy["text"] = trimForWidget(text, maxLength: 220_000)
      return copy
    }

    if let resource = item["resource"] as? [String: Any] {
      let mimeType = (resource["mimeType"] as? String)?.lowercased() ?? ""
      let text = itemText(resource)
      if mimeType.contains("html") || text.localizedCaseInsensitiveContains("<html") {
        return nil
      }
      var copy = item
      copy["resource"] = UgotMCPClient.compactForWidget(resource, maxStringLength: 120_000, maxArrayCount: 120)
      return copy
    }

    let mimeType = (item["mimeType"] as? String)?.lowercased() ?? ""
    let text = itemText(item)
    if mimeType.contains("html") || text.localizedCaseInsensitiveContains("<html") {
      return nil
    }
    return UgotMCPClient.compactForWidget(item, maxStringLength: 120_000, maxArrayCount: 120) as? [String: Any]
  }

  private func firstSummaryLine(from message: String) -> String {
    message
      .split(separator: "\n", omittingEmptySubsequences: true)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .first { !$0.isEmpty }
      .map { String($0.prefix(80)) } ?? "MCP 결과"
  }

  private func widgetResource(fromToolResult result: [String: Any]) -> UgotMCPWidgetResource? {
    let content = result["content"] as? [[String: Any]] ?? []
    for item in content {
      if let resource = item["resource"] as? [String: Any] {
        let mimeType = resource["mimeType"] as? String
        let uri = resource["uri"] as? String ?? "inline://mcp-widget"
        let text = itemText(resource)
        if !text.isEmpty, UgotMCPClient.isSupportedWidgetMime(mimeType) || text.localizedCaseInsensitiveContains("<html") {
          return UgotMCPWidgetResource(uri: uri, mimeType: mimeType, html: text, csp: nil, permissions: nil)
        }
      }

      let mimeType = item["mimeType"] as? String
      let uri = item["uri"] as? String ?? "inline://mcp-widget"
      let text = itemText(item)
      if !text.isEmpty, UgotMCPClient.isSupportedWidgetMime(mimeType) || text.localizedCaseInsensitiveContains("<html") {
        return UgotMCPWidgetResource(uri: uri, mimeType: mimeType, html: text, csp: nil, permissions: nil)
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
    var trimmed = text
      .replacingOccurrences(of: "\\n", with: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    trimmed = stripRawDataSections(from: trimmed)
    guard !trimmed.isEmpty else { return nil }
    if trimmed.lowercased().contains("already loaded"),
       let firstBullet = trimmed.range(of: "\n- ") {
      trimmed = String(trimmed[firstBullet.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if let parsed = parseJsonLikeText(trimmed),
       let summary = markdownSummary(from: parsed) {
      return summary
    }
    if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
      return "MCP 결과를 불러왔어요."
    }
    return trimmed
  }

  private func stripRawDataSections(from text: String) -> String {
    guard let marker = text.range(of: "\\n?\\[Raw [^\\]]+ Data\\][\\s\\S]*", options: .regularExpression) else {
      return text
    }
    return String(text[..<marker.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func trimForWidget(_ text: String, maxLength: Int = 4_000) -> String {
    let normalized = text.replacingOccurrences(of: "\\n", with: "\n")
    if normalized.count <= maxLength {
      return normalized
    }
    return String(normalized.prefix(maxLength)) + "\n\n…"
  }

  private func compactArtifactContext(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != "Available agent files: none" else { return "" }
    return trimForWidget(trimmed, maxLength: 2_400)
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

  private func jsonTopLevelKeys(from text: String) -> [String]? {
    parseJsonLikeText(text).map(topLevelKeys)
  }

  private func topLevelKeys(from value: Any) -> [String] {
    if let dict = value as? [String: Any] {
      return Array(dict.keys.sorted().prefix(24))
    }
    if let array = value as? [Any],
       let dict = array.first as? [String: Any] {
      return Array(dict.keys.sorted().prefix(24)).map { "items[].\($0)" }
    }
    return []
  }

  private func markdownSummary(from value: Any) -> String? {
    if let compatibility = UgotMCPCompatibilityContextRenderer.markdown(from: value) {
      return compatibility
    }
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

    for key in ["structuredContent", "structured_content", "result", "data", "content"] {
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


}

private extension String {
  func oneLineForPrompt(limit: Int) -> String {
    replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmedForPrompt(limit: limit)
  }

  func trimmedForPrompt(limit: Int) -> String {
    guard count > limit else { return self }
    let headCount = max(0, limit / 2)
    let tailCount = max(0, limit - headCount - 20)
    return "\(prefix(headCount))\n…[trimmed]…\n\(suffix(tailCount))"
  }
}
