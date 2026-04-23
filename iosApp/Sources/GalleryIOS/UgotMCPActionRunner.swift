import Foundation
import GallerySharedCore

struct UgotMCPConnectorStatusEvent: Sendable {
  enum Status: String, Sendable {
    case checking
    case ready
    case failed
  }

  let connectorId: String
  let connectorTitle: String
  let status: Status
  let detail: String
}

enum UgotMCPActionRunner {
  typealias ToolPlanningProvider = (UgotMCPToolPlanningRequest) async -> UgotMCPToolPlanningDecision?
  typealias ConnectorStatusHandler = (UgotMCPConnectorStatusEvent) async -> Void

  static func runIfNeeded(
    prompt: String,
    activeSkillIds: Set<String>,
    activeConnectorIds: Set<String>,
    sessionId: String,
    requireToolObservation: Bool = false,
    toolPlanningProvider: ToolPlanningProvider? = nil,
    connectorStatusHandler: ConnectorStatusHandler? = nil
  ) async -> GalleryChatActionResult? {
    let activeConnectors = GalleryConnector.samples.filter { activeConnectorIds.contains($0.id) }
    guard !activeConnectors.isEmpty else { return nil }

    do {
      guard let accessToken = try await UgotAuthStore.validAccessToken() else {
        let message = "UGOT 세션이 만료됐어요. 다시 로그인해 주세요."
        return GalleryChatActionResult(
          message: message,
          toolObservation: hostObservation(
            connectorTitle: "MCP",
            toolName: "mcp.auth",
            toolTitle: "MCP 로그인 확인",
            outputText: message,
            status: "auth_required"
          )
        )
      }
      let clients = activeConnectors.map { connector in
        UgotMCPConnectorAction(
          connector: connector,
          accessToken: accessToken,
          sessionId: sessionId,
          toolPlanningProvider: toolPlanningProvider,
          connectorStatusHandler: connectorStatusHandler
        )
      }

      let orderedClients = try await orderedClients(
        clients,
        prompt: prompt,
        sessionId: sessionId,
        activeConnectorIds: activeConnectorIds,
        requireToolObservation: requireToolObservation
      )
      guard !orderedClients.isEmpty else {
        return requireToolObservation ? noMatchingToolResult(
          prompt: prompt,
          connectorTitle: activeConnectors.map(\.title).joined(separator: ", ")
        ) : nil
      }
      var connectorErrors: [String] = []
      for client in orderedClients {
        do {
          if let response = try await client.run(
            prompt: prompt,
            emitNoToolFailure: false
          ) {
            return GalleryChatActionResult(
              message: response.message,
              widgetSnapshot: response.snapshot,
              approvalRequest: response.approvalRequest,
              toolObservations: response.observations
            )
          }
        } catch {
          connectorErrors.append("\(client.connectorTitle): \(error.localizedDescription)")
          continue
        }
      }
      if requireToolObservation, !connectorErrors.isEmpty {
        return GalleryChatActionResult(
          message: "활성 MCP 커넥터에 연결하지 못했어요.",
          toolObservation: hostObservation(
            connectorTitle: activeConnectors.map(\.title).joined(separator: ", "),
            toolName: "mcp.connector_status",
            toolTitle: "MCP 커넥터 연결",
            argumentsPreview: compactHostArguments(["prompt": prompt]),
            outputText: connectorErrors.joined(separator: "\n"),
            status: "connector_error"
          )
        )
      }
      // No MCP tool matched this turn. For optional connector availability, fall
      // back to normal model chat. For a tool-required turn, return a canonical
      // observation so the agent loop cannot finish from thinking without an
      // observed tool/search result.
      return requireToolObservation ? noMatchingToolResult(
        prompt: prompt,
        connectorTitle: activeConnectors.map(\.title).joined(separator: ", ")
      ) : nil
    } catch {
      let message = "MCP 호출에 실패했어요.\n\n\(error.localizedDescription)"
      return GalleryChatActionResult(
        message: message,
        toolObservation: hostObservation(
          connectorTitle: "MCP",
          toolName: "mcp.call",
          toolTitle: "MCP 호출",
          outputText: message,
          status: "error"
        )
      )
    }
  }

  private static func noMatchingToolResult(prompt: String, connectorTitle: String) -> GalleryChatActionResult {
    let normalizedTitle = connectorTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? "활성 MCP 커넥터"
      : connectorTitle
    let message = "MCP 도구 실행이 필요한 요청인데 실행 가능한 도구를 확정하지 못했어요. 일반 대화로 처리하면 거짓 답변이 될 수 있어서 중단했어요."
    return GalleryChatActionResult(
      message: message,
      toolObservation: hostObservation(
        connectorTitle: normalizedTitle,
        toolName: "mcp.tool_search",
        toolTitle: "도구 검색",
        argumentsPreview: compactHostArguments(["prompt": prompt]),
        outputText: message,
        status: "no_matching_tool"
      )
    )
  }

  private static func hostObservation(
    connectorTitle: String,
    toolName: String,
    toolTitle: String,
    argumentsPreview: String = "`{}`",
    outputText: String,
    status: String
  ) -> UgotAgentToolObservation {
    UgotAgentToolObservation.hostObservation(
      connectorTitle: connectorTitle,
      toolName: toolName,
      toolTitle: toolTitle,
      argumentsPreview: argumentsPreview,
      outputText: outputText,
      status: status
    )
  }

  private static func compactHostArguments(_ arguments: [String: Any]) -> String {
    guard JSONSerialization.isValidJSONObject(arguments),
          let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]),
          let json = String(data: data, encoding: .utf8) else {
      return "`{}`"
    }
    return json.count <= 320 ? "`\(json)`" : "`\(String(json.prefix(320)))…`"
  }

  private static func orderedClients(
    _ clients: [UgotMCPConnectorAction],
    prompt: String,
    sessionId: String,
    activeConnectorIds: Set<String>,
    requireToolObservation: Bool
  ) async throws -> [UgotMCPConnectorAction] {
    if let pendingConnectorId = UgotMCPToolApprovalStore.pendingConnectorId(
      sessionId: sessionId,
      connectorIds: activeConnectorIds
    ), let pendingClient = clients.first(where: { $0.connectorId == pendingConnectorId }) {
      return [pendingClient] + clients.filter { $0.connectorId != pendingConnectorId }
    }

    let minimumConnectorEvidenceScore = requireToolObservation
      ? UgotMCPToolPlanner.minimumSearchScoreForPlanning
      : UgotMCPToolPlanner.minimumOptionalSearchScoreForPlanning

    let sourceRanked = clients
      .map { client in
        (
          client: client,
          score: UgotMCPToolSearchIndex.searchScore(
            query: prompt,
            document: "\(client.connectorTitle) \(client.connectorSummary)"
          ).score
        )
      }
      .sorted { lhs, rhs in
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.client.connectorTitle != rhs.client.connectorTitle { return lhs.client.connectorTitle < rhs.client.connectorTitle }
        return lhs.client.connectorId < rhs.client.connectorId
      }
    if clients.count > 1 {
      if let best = sourceRanked.first,
         best.score >= minimumConnectorEvidenceScore {
        let secondScore = sourceRanked.dropFirst().first?.score ?? 0
        if best.score - secondScore >= 6 {
          // If connector-level metadata clearly identifies one connector, do not
          // probe unrelated connectors for this turn.
          return [best.client]
        }
      }
    } else if let only = sourceRanked.first,
              only.score >= minimumConnectorEvidenceScore {
      return [only.client]
    } else if requireToolObservation {
      return clients
    } else {
      let candidates = try? await clients[0].planningCandidate(prompt: prompt)
      if let candidates,
         candidates.searchScore >= minimumConnectorEvidenceScore {
        return clients
      }
      return []
    }

    var candidates: [UgotMCPConnectorToolSearchCandidate] = []
    await withTaskGroup(of: UgotMCPConnectorToolSearchCandidate?.self) { group in
      for client in clients {
        group.addTask {
          guard let candidate = try? await client.planningCandidate(prompt: prompt),
                candidate.searchScore >= minimumConnectorEvidenceScore else {
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
    // Metadata search is an optimization, not the source of truth. However, for
    // optional connector turns, a zero-candidate search is evidence that the
    // active connector should not inspect a generic ambiguous follow-up;
    // otherwise the planner model may pick an unrelated available tool. When a
    // tool observation is explicitly required, fail closed by trying the active
    // connectors and surfacing a no-match/error observation instead of falling
    // back to ordinary chat.
    guard !candidates.isEmpty else { return requireToolObservation ? clients : [] }

    let byConnectorId = Dictionary(uniqueKeysWithValues: clients.map { ($0.connectorId, $0) })
    let metadataOrderedIds = candidates
      .sorted { lhs, rhs in
        if lhs.searchScore != rhs.searchScore { return lhs.searchScore > rhs.searchScore }
        if lhs.connectorTitle != rhs.connectorTitle { return lhs.connectorTitle < rhs.connectorTitle }
        return lhs.connectorId < rhs.connectorId
      }
      .map(\.connectorId)
    return orderedClients(
      ids: metadataOrderedIds,
      lookup: byConnectorId,
      fallback: requireToolObservation ? clients : []
    )
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
        let message = "UGOT 세션이 만료됐어요. 다시 로그인해 주세요."
        return GalleryChatActionResult(
          message: message,
          toolObservation: hostObservation(
            connectorTitle: "MCP",
            toolName: "mcp.auth",
            toolTitle: "MCP 로그인 확인",
            outputText: message,
            status: "auth_required"
          )
        )
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
        toolObservations: response.observations
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
  let observations: [UgotAgentToolObservation]

  var observation: UgotAgentToolObservation? { observations.last }

  init(
    message: String,
    snapshot: McpWidgetSnapshot?,
    approvalRequest: UgotMCPToolApprovalRequest? = nil,
    observation: UgotAgentToolObservation? = nil,
    observations: [UgotAgentToolObservation] = []
  ) {
    self.message = message
    self.snapshot = snapshot
    self.approvalRequest = approvalRequest
    self.observations = observations + [observation].compactMap { $0 }
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
  let previousObservations: [UgotAgentToolObservation]
  let stepIndex: Int
  let maxSteps: Int
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
  let intentEffect: String?
  let confidence: Double
  let requiresTool: Bool

  var shouldUseTool: Bool {
    guard let toolName, !toolName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return false
    }
    return confidence >= 0.55
  }

  static func parse(from rawText: String) -> UgotMCPToolPlanningDecision? {
    guard let sharedDecision = AgentToolPlanningPromptKt.parseAgentToolPlanningDecision(rawText: rawText) else {
      return nil
    }
    return UgotMCPToolPlanningDecision(sharedDecision: sharedDecision)
  }

  private init(sharedDecision: AgentToolPlanningDecision) {
    self.toolName = sharedDecision.toolName
    self.arguments = Self.argumentsObject(from: sharedDecision.argumentsJson)
    self.entityReference = sharedDecision.entityReference
    self.intentEffect = sharedDecision.intentEffect
    self.confidence = sharedDecision.confidence
    self.requiresTool = sharedDecision.requiresTool
  }

  private static func argumentsObject(from json: String) -> [String: Any] {
    guard let data = json.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return [:]
    }
    return object
  }
}

enum UgotMCPToolPlanningPromptBuilder {
  static func build(request: UgotMCPToolPlanningRequest) -> String {
    AgentToolPlanningPromptKt.buildAgentToolPlanningPrompt(
      request: AgentToolPlanningRequest(
        userPrompt: request.prompt,
        connectorId: request.connectorId,
        connectorTitle: request.connectorTitle,
        tools: request.tools.map(planningDescriptor),
        previousObservations: request.previousObservations.map(loopObservation),
        stepIndex: Int32(request.stepIndex),
        maxSteps: Int32(request.maxSteps)
      )
    )
  }

  private static func planningDescriptor(_ tool: [String: Any]) -> AgentToolPlanningDescriptor {
    let name = tool["name"] as? String ?? "unknown"
    let title =
      (tool["title"] as? String) ??
      ((tool["annotations"] as? [String: Any])?["title"] as? String) ??
      name
    let description = (tool["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let annotations = tool["annotations"] as? [String: Any] ?? [:]
    let schema = tool["inputSchema"] as? [String: Any] ?? [:]
    let required = (schema["required"] as? [String] ?? []).sorted()

    return AgentToolPlanningDescriptor(
      name: name,
      title: title,
      description: description,
      isReadOnly: annotationBool(annotations["readOnlyHint"]).map(KotlinBoolean.init(bool:)),
      isDestructive: annotationBool(annotations["destructiveHint"]).map(KotlinBoolean.init(bool:)),
      hasWidget: UgotMCPClient.widgetResourceURI(from: tool) != nil,
      requiredParameters: required,
      parametersSummary: parameterSummary(from: schema)
    )
  }

  private static func loopObservation(_ observation: UgotAgentToolObservation) -> AgentToolLoopObservation {
    AgentToolLoopObservation(
      connectorId: observation.connectorId,
      connectorTitle: observation.connectorTitle,
      toolName: observation.toolName,
      toolTitle: observation.toolTitle,
      argumentsPreview: observation.argumentsPreview,
      outputText: observation.outputText,
      hasWidget: observation.hasWidget,
      didMutate: observation.didMutate,
      status: observation.status
    )
  }

  private static func parameterSummary(from schema: [String: Any]) -> String {
    (schema["properties"] as? [String: Any] ?? [:])
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
  }

  private static func annotationBool(_ raw: Any?) -> Bool? {
    if let value = raw as? Bool { return value }
    if let value = raw as? NSNumber { return value.boolValue }
    if let value = raw as? String {
      let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      if ["true", "yes", "1"].contains(normalized) { return true }
      if ["false", "no", "0"].contains(normalized) { return false }
    }
    return nil
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
       let destructive = annotationBool(annotations["destructiveHint"]) {
      return destructive
    }
    let name = ((tool["name"] as? String) ?? "").lowercased()
    return ["delete", "remove", "clear", "reset"].contains { name.contains($0) }
  }

  private static func isReadOnly(tool: [String: Any]) -> Bool {
    if let annotations = tool["annotations"] as? [String: Any],
       let readOnly = annotationBool(annotations["readOnlyHint"]) {
      return readOnly
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

  private static func annotationBool(_ raw: Any?) -> Bool? {
    if let value = raw as? Bool { return value }
    if let value = raw as? NSNumber { return value.boolValue }
    if let value = raw as? String {
      let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      if ["true", "yes", "1"].contains(normalized) { return true }
      if ["false", "no", "0"].contains(normalized) { return false }
    }
    return nil
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
  // Bump when routing-relevant MCP metadata semantics change. Tool
  // descriptions/search keywords are part of the planner contract; keeping an
  // older persisted catalog can make the host route to a stale/wrong tool even
  // after the MCP server was fixed.
  private static let persistentPrefix = "ugot.mcp.toolMetadataCache.v5"
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

    if let attachedArgument = firstAttachedArgumentTarget(in: trimmed) {
      return attachedArgument
    }
    if let quoted = firstQuotedSpan(in: trimmed) {
      return quoted
    }
    if let patterned = firstPatternTarget(in: trimmed) {
      return patterned
    }
    return lastMeaningfulToken(in: trimmed)
  }

  private static func firstAttachedArgumentTarget(in text: String) -> String? {
    if let selectedLine = firstRegexCapture(pattern: #"(?im)^\s*-?\s*selected\s+arguments\s*:\s*([^\n]{1,800})"#, in: text),
       let value = firstEntityLikeArgumentValue(in: selectedLine) {
      return value
    }
    if let jsonValue = firstRegexCapture(
      pattern: #"(?i)["'](?:target|target_name|targetName|entity|entity_reference|entityReference|name)["']\s*:\s*["']([^"']{1,80})["']"#,
      in: text
    ) {
      return jsonValue
    }
    return nil
  }

  private static func firstRegexCapture(pattern: String, in text: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, range: nsRange),
          match.numberOfRanges > 1,
          let range = Range(match.range(at: 1), in: text) else {
      return nil
    }
    return cleanCandidate(String(text[range]))
  }

  private static func firstEntityLikeArgumentValue(in argumentList: String) -> String? {
    let pairs = argumentList.split(separator: ",").map(String.init)
    let preferredKeys = Set([
      "target", "targetname", "entity", "entityreference", "name", "profile", "user",
    ])
    for pair in pairs {
      let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
      guard parts.count == 2 else { continue }
      let key = parts[0]
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        .replacingOccurrences(of: "[^\\p{L}\\p{N}]+", with: "", options: .regularExpression)
      guard preferredKeys.contains(key) else { continue }
      if let value = cleanCandidate(parts[1]) {
        return value
      }
    }
    return nil
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
      #"(?i)(?:set|change|make|select)\s+(?:the\s+)?(?:target|profile|user|entity|item)\s+(?:to|as)?\s*([\p{L}\p{N}._-]{1,40})"#,
      #"(?i)(?:target|profile|user|entity|item)\s+(?:to|as)\s*([\p{L}\p{N}._-]{1,40})"#,
      #"([\p{L}\p{N}._-]{1,40})\s*(?:로|으로)\s*(?:설정|설정해|설정할|변경|변경해|변경할|바꿔|바꿀|바꾸|지정|선택|해)"#,
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
    "default", "user", "profile", "target", "person", "member",
    "set", "change", "update", "select", "save", "delete", "clear", "remove", "make",
    "기본", "사용자", "프로필", "타깃", "타겟", "대표",
    "로", "으로", "을", "를", "은", "는", "이", "가",
    "사람", "대상", "계정",
    "설정", "설정해", "설정해줘", "설정할", "변경", "변경해", "변경해줘", "변경할",
    "바꿔", "바꿔줘", "바꿔주세요", "바꿀", "바꾸", "지정", "선택", "해", "해줘", "해주세요",
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
  // Optional connector turns should not route a generic chat continuation to a
  // tool planner from a weak metadata hit. Tool-required turns still use the
  // lower threshold and fail closed if no valid plan can be executed.
  static let minimumOptionalSearchScoreForPlanning = 30
  private static let deterministicFallbackScore = 30
  private static let deterministicFallbackMargin = 8

  static func toolsForModelPlanning(
    prompt: String,
    tools: [[String: Any]],
    searchIndex: UgotMCPToolSearchIndex? = nil,
    limit: Int = 18
  ) -> [[String: Any]] {
    let intent = UgotMCPToolIntent(prompt: prompt)
    let eligibleTools = (searchIndex?.eligibleTools(query: prompt) ?? tools)
      .filter { !intent.isIncompatiblePrimaryTool(tool: $0) }
      .filter { !intent.prefersReadOnlyTool || isReadOnly(tool: $0) }
      .filter { !intent.requiresPlannerBeforeToolExecution || !isReadOnly(tool: $0) }
    let searched = (searchIndex ?? UgotMCPToolSearchIndex(tools: tools)).search(query: prompt, limit: limit)
    guard !searched.isEmpty else {
      return Array(eligibleTools.prefix(limit))
    }

    let selected = searched
      .map(\.tool)
      .filter { !intent.prefersReadOnlyTool || isReadOnly(tool: $0) }
      .filter { !intent.requiresPlannerBeforeToolExecution || !isReadOnly(tool: $0) }
    // The model planner is not the retrieval layer. Once metadata search has a
    // non-empty candidate set, expose only those candidates to the model;
    // appending "remaining eligible" tools lets a small local model switch to a
    // semantically unrelated tool just because it appears in the catalog.
    return Array(selected.prefix(limit))
  }

  static func plan(
    prompt: String,
    tools: [[String: Any]],
    decision: UgotMCPToolPlanningDecision?
  ) -> UgotMCPToolPlan? {
    let intent = UgotMCPToolIntent(prompt: prompt)
    guard let decision, decision.shouldUseTool else { return nil }
    return planFromDecision(decision, tools: tools, intent: intent, prompt: prompt)
  }

  static func fallbackPlanFromSearch(
    prompt: String,
    tools: [[String: Any]],
    searchIndex: UgotMCPToolSearchIndex
  ) -> UgotMCPToolPlan? {
    let toolNames = Set(tools.compactMap { $0["name"] as? String })
    let results = searchIndex.search(query: prompt, limit: 4)
      .filter { result in
        guard let name = result.tool["name"] as? String else { return false }
        return toolNames.contains(name)
      }
    guard let first = results.first,
          let name = first.tool["name"] as? String,
          first.score >= deterministicFallbackScore else {
      return nil
    }
    if let second = results.dropFirst().first,
       first.score - second.score < deterministicFallbackMargin {
      return nil
    }

    let intent = UgotMCPToolIntent(prompt: prompt)
    let tool = first.tool
    guard !intent.isIncompatiblePrimaryTool(tool: tool),
          !intent.requiresStateChangingTool || intent.isPreferredPrimaryTool(tool: tool),
          !intent.prefersReadOnlyTool || isReadOnly(tool: tool),
          !intent.requiresPlannerBeforeToolExecution || !isReadOnly(tool: tool) else {
      return nil
    }

    let promptArguments = schemaArguments(from: prompt, for: tool)
    let normalized = normalizeOpaqueArguments(
      promptArguments,
      for: tool,
      existingEntityReference: UgotMCPPromptEntityExtractor.entityText(from: prompt)
    )

    return UgotMCPToolPlan(
      tool: tool,
      name: name,
      title: displayTitle(for: tool, fallbackName: name),
      arguments: argumentsWithDefaults(normalized.arguments, for: tool),
      score: min(100, first.score),
      entityReference: normalized.entityReference
    )
  }

  private static func planFromDecision(
    _ decision: UgotMCPToolPlanningDecision,
    tools: [[String: Any]],
    intent: UgotMCPToolIntent,
    prompt: String
  ) -> UgotMCPToolPlan? {
    guard let requestedName = decision.toolName?.trimmingCharacters(in: .whitespacesAndNewlines),
          !requestedName.isEmpty,
          let tool = resolveDecisionTool(requestedName, tools: tools),
          let name = tool["name"] as? String else {
      return nil
    }
    guard !intent.isIncompatiblePrimaryTool(tool: tool),
          !intent.requiresStateChangingTool || intent.isPreferredPrimaryTool(tool: tool) else {
      return nil
    }
    guard !intent.prefersReadOnlyTool || isReadOnly(tool: tool) else {
      return nil
    }
    guard !intent.requiresPlannerBeforeToolExecution || !isReadOnly(tool: tool) else {
      return nil
    }
    guard isCompatibleWithDeclaredEffect(decision.intentEffect, tool: tool) else {
      return nil
    }

    let sanitized = sanitizedArguments(decision.arguments, for: tool)
    let promptArguments = schemaArguments(from: prompt, for: tool)
    let merged = mergeMissingArguments(sanitized, fallback: promptArguments)
    let normalized = normalizeOpaqueArguments(
      merged,
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

  private static func resolveDecisionTool(_ requestedName: String, tools: [[String: Any]]) -> [String: Any]? {
    let requestedKey = compactToolLookupKey(requestedName)
    guard !requestedKey.isEmpty else { return nil }

    if let exactName = tools.first(where: { tool in
      ((toolName(tool) ?? "").caseInsensitiveCompare(requestedName) == .orderedSame)
    }) {
      return exactName
    }

    if let aliasMatch = tools.first(where: { tool in
      toolLookupAliases(tool).contains(requestedKey)
    }) {
      return aliasMatch
    }

    let ranked = UgotMCPToolSearchIndex(
      tools: tools,
      queryExpansionProvider: .none
    ).search(query: requestedName, limit: 2)
    guard let first = ranked.first,
          first.score >= 12 else {
      return nil
    }
    if let second = ranked.dropFirst().first, first.score - second.score < 4 {
      return nil
    }
    return first.tool
  }

  private static func toolName(_ tool: [String: Any]) -> String? {
    tool["name"] as? String
  }

  private static func toolLookupAliases(_ tool: [String: Any]) -> Set<String> {
    var aliases: [String] = []
    if let name = tool["name"] as? String {
      aliases.append(name)
      aliases.append(name.replacingOccurrences(of: "_", with: " "))
      aliases.append(name.replacingOccurrences(of: "-", with: " "))
    }
    if let title = tool["title"] as? String {
      aliases.append(title)
    }
    let display = displayTitle(for: tool, fallbackName: (tool["name"] as? String) ?? "")
    aliases.append(display)
    for metaKey in ["_meta", "meta", "annotations"] {
      guard let meta = tool[metaKey] as? [String: Any] else { continue }
      for key in ["title", "displayTitle", "ui/title", "openai/toolInvocation/invoking", "openai/toolInvocation/invoked"] {
        if let value = meta[key] as? String {
          aliases.append(value)
        }
      }
    }
    return Set(aliases.map(compactToolLookupKey).filter { !$0.isEmpty })
  }

  private static func compactToolLookupKey(_ value: String) -> String {
    value
      .lowercased()
      .replacingOccurrences(of: "[^\\p{L}\\p{N}]+", with: "", options: .regularExpression)
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

  static func schemaArguments(from prompt: String, for tool: [String: Any]) -> [String: Any] {
    guard let properties = inputProperties(for: tool), !properties.isEmpty else { return [:] }
    let keyLookup = schemaArgumentKeyLookup(properties)
    var out: [String: Any] = [:]
    for pair in promptKeyValuePairs(from: prompt) {
      let lookupKey = compactArgumentLookupKey(pair.key)
      guard let schemaKey = keyLookup[lookupKey],
            out[schemaKey] == nil,
            let property = properties[schemaKey] as? [String: Any],
            let value = coercePromptArgument(pair.value, property: property) else {
        continue
      }
      out[schemaKey] = value
    }
    return out
  }

  static func mergeMissingArguments(_ base: [String: Any], fallback: [String: Any]) -> [String: Any] {
    guard !fallback.isEmpty else { return base }
    var out = base
    for (key, value) in fallback where isMissingArgumentValue(out[key]) {
      out[key] = value
    }
    return out
  }

  private static func promptKeyValuePairs(from prompt: String) -> [(key: String, value: String)] {
    var pairs: [(key: String, value: String)] = []

    for selectedArguments in regexCaptures(
      pattern: #"(?im)^\s*[-*]?\s*selected\s+arguments\s*[:：]\s*([^\n]{1,1600})"#,
      in: prompt
    ) {
      pairs.append(contentsOf: commaSeparatedKeyValuePairs(from: selectedArguments))
    }

    pairs.append(
      contentsOf: regexCapturePairs(
        pattern: #"(?m)^\s*[-*]?\s*([A-Za-z_][A-Za-z0-9_.-]{0,80})\s*[:：=]\s*([^\n]{0,1200})"#,
        in: prompt
      )
    )
    pairs.append(
      contentsOf: regexCapturePairs(
        pattern: #"(?m)["']([A-Za-z_][A-Za-z0-9_.-]{0,80})["']\s*:\s*(?:"([^"\n]{0,1200})"|'([^'\n]{0,1200})'|([^,\n}\]]{1,400}))"#,
        in: prompt
      )
    )

    return pairs
  }

  private static func commaSeparatedKeyValuePairs(from text: String) -> [(key: String, value: String)] {
    text
      .split(separator: ",")
      .compactMap { segment -> (key: String, value: String)? in
        let raw = String(segment)
        let separators = ["=", ":", "："]
        guard let separator = separators
          .compactMap({ raw.range(of: $0) })
          .min(by: { $0.lowerBound < $1.lowerBound }) else {
          return nil
        }
        let key = String(raw[..<separator.lowerBound])
        let value = String(raw[separator.upperBound...])
        return (key, value)
      }
  }

  private static func regexCaptures(pattern: String, in text: String) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
    return regex.matches(in: text, range: nsRange).compactMap { match in
      guard match.numberOfRanges > 1,
            let range = Range(match.range(at: 1), in: text) else {
        return nil
      }
      return String(text[range])
    }
  }

  private static func regexCapturePairs(pattern: String, in text: String) -> [(key: String, value: String)] {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
    return regex.matches(in: text, range: nsRange).compactMap { match in
      guard match.numberOfRanges > 2,
            let keyRange = Range(match.range(at: 1), in: text) else {
        return nil
      }
      let value: String?
      if match.numberOfRanges > 3 {
        value = (2..<match.numberOfRanges).compactMap { index -> String? in
          guard match.range(at: index).location != NSNotFound,
                let valueRange = Range(match.range(at: index), in: text) else {
            return nil
          }
          return String(text[valueRange])
        }.first
      } else if let valueRange = Range(match.range(at: 2), in: text) {
        value = String(text[valueRange])
      } else {
        value = nil
      }
      guard let value else { return nil }
      return (String(text[keyRange]), value)
    }
  }

  private static func schemaArgumentKeyLookup(_ properties: [String: Any]) -> [String: String] {
    var lookup: [String: String] = [:]
    for key in properties.keys {
      lookup[compactArgumentLookupKey(key)] = key
    }
    return lookup
  }

  private static func compactArgumentLookupKey(_ value: String) -> String {
    value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacingOccurrences(of: "[^\\p{L}\\p{N}]+", with: "", options: .regularExpression)
  }

  private static func coercePromptArgument(_ raw: String, property: [String: Any]) -> Any? {
    guard let cleaned = cleanPromptArgumentValue(raw) else { return nil }
    let type = (property["type"] as? String)?.lowercased()
    switch type {
    case "boolean":
      switch cleaned.lowercased() {
      case "true", "yes", "y", "1", "on": return true
      case "false", "no", "n", "0", "off": return false
      default: return nil
      }
    case "integer":
      return Int(cleaned)
    case "number":
      return Double(cleaned)
    case "array", "object":
      guard let data = cleaned.data(using: .utf8),
            let value = try? JSONSerialization.jsonObject(with: data) else {
        return nil
      }
      return value
    default:
      return cleaned
    }
  }

  private static func cleanPromptArgumentValue(_ raw: String) -> String? {
    var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    while value.hasSuffix(",") || value.hasSuffix(";") {
      value.removeLast()
      value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let quotePairs: [(String, String)] = [
      ("\"", "\""),
      ("'", "'"),
      ("`", "`"),
      ("“", "”"),
      ("‘", "’"),
    ]
    for (open, close) in quotePairs where value.hasPrefix(open) && value.hasSuffix(close) && value.count >= open.count + close.count {
      value.removeFirst(open.count)
      value.removeLast(close.count)
      value = value.trimmingCharacters(in: .whitespacesAndNewlines)
      break
    }
    guard !value.isEmpty else { return nil }

    let lowered = value.lowercased()
    guard !["null", "nil", "none", "n/a", "na", "tbd", "unknown"].contains(lowered) else {
      return nil
    }
    guard !(value.hasPrefix("<") && value.hasSuffix(">")) else { return nil }
    return value
  }

  private static func isMissingArgumentValue(_ value: Any?) -> Bool {
    guard let value, !(value is NSNull) else { return true }
    if let string = value as? String {
      return string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    if let array = value as? [Any] {
      return array.isEmpty
    }
    if let dict = value as? [String: Any] {
      return dict.isEmpty
    }
    return false
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

  private static func isReadOnly(tool: [String: Any]) -> Bool {
    if let annotations = tool["annotations"] as? [String: Any],
       let readOnly = annotationBool(annotations["readOnlyHint"]) {
      return readOnly
    }
    return inferredReadOnlyFromToolName(tool)
  }

  private static func isCompatibleWithDeclaredEffect(_ rawEffect: String?, tool: [String: Any]) -> Bool {
    guard let rawEffect else { return true }
    let effect = rawEffect
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacingOccurrences(of: "_", with: "-")
    guard !effect.isEmpty, effect != "none", effect != "no-tool" else {
      return false
    }

    if ["read", "readonly", "read-only", "view", "display", "search", "summarize"].contains(effect) {
      return isReadOnly(tool: tool)
    }
    if ["write", "mutate", "mutation", "setting", "settings", "set", "update", "create", "send"].contains(effect) {
      return !isReadOnly(tool: tool) && !isDestructive(tool: tool)
    }
    if ["destructive", "delete", "remove", "clear", "reset"].contains(effect) {
      return !isReadOnly(tool: tool) && isDestructive(tool: tool)
    }
    return true
  }

  private static func isDestructive(tool: [String: Any]) -> Bool {
    if let annotations = tool["annotations"] as? [String: Any],
       let destructive = annotationBool(annotations["destructiveHint"]) {
      return destructive
    }
    let name = ((tool["name"] as? String) ?? "").lowercased()
    return ["delete", "remove", "clear", "reset"].contains { name.contains($0) }
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

  private static func annotationBool(_ raw: Any?) -> Bool? {
    if let value = raw as? Bool { return value }
    if let value = raw as? NSNumber { return value.boolValue }
    if let value = raw as? String {
      let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      if ["true", "yes", "1"].contains(normalized) { return true }
      if ["false", "no", "0"].contains(normalized) { return false }
    }
    return nil
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
  private let connectorStatusHandler: UgotMCPActionRunner.ConnectorStatusHandler?
  private let catalogStatusLock = NSLock()
  private var didEmitCatalogChecking = false
  private var didEmitCatalogResult = false

  var connectorId: String { connector.id }
  var connectorTitle: String { connector.title }
  var connectorSummary: String { connector.summary }

  init(
    connector: GalleryConnector,
    accessToken: String,
    sessionId: String,
    toolPlanningProvider: UgotMCPActionRunner.ToolPlanningProvider? = nil,
    connectorStatusHandler: UgotMCPActionRunner.ConnectorStatusHandler? = nil
  ) {
    self.connector = connector
    self.sessionId = sessionId
    self.toolPlanningProvider = toolPlanningProvider
    self.connectorStatusHandler = connectorStatusHandler
    self.mcpClient = UgotMCPRuntimeClient.make(
      connectorId: connector.id,
      endpoint: URL(string: connector.endpoint)!,
      accessToken: accessToken
    )
  }

  private func loadCatalog() async throws -> UgotMCPToolCatalog {
    if shouldEmitCatalogChecking() {
      await emitConnectorStatus(.checking, detail: "연결과 도구 목록을 확인 중이에요.")
    }
    do {
      let catalog = try await UgotMCPToolCatalogCache.catalog(
        connectorId: connector.id,
        sourceName: nil,
        sourceDescription: nil
      ) {
        try await mcpClient.initialize()
        return try await mcpClient.listTools()
      }
      if shouldEmitCatalogResult() {
        await emitConnectorStatus(.ready, detail: "연결됨 · 실행 가능 도구 \(catalog.modelVisibleTools.count)개")
      }
      return catalog
    } catch {
      if shouldEmitCatalogResult() {
        await emitConnectorStatus(.failed, detail: error.localizedDescription)
      }
      throw error
    }
  }

  private func shouldEmitCatalogChecking() -> Bool {
    catalogStatusLock.lock()
    defer { catalogStatusLock.unlock() }
    guard !didEmitCatalogChecking else { return false }
    didEmitCatalogChecking = true
    return true
  }

  private func shouldEmitCatalogResult() -> Bool {
    catalogStatusLock.lock()
    defer { catalogStatusLock.unlock() }
    guard !didEmitCatalogResult else { return false }
    didEmitCatalogResult = true
    return true
  }

  private func emitConnectorStatus(_ status: UgotMCPConnectorStatusEvent.Status, detail: String) async {
    await connectorStatusHandler?(UgotMCPConnectorStatusEvent(
      connectorId: connector.id,
      connectorTitle: connector.title,
      status: status,
      detail: detail
    ))
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
        let message = "이 connector에는 대화에서 직접 실행할 수 있는 MCP 도구가 없어요."
        return UgotMCPActionResponse(
          message: message,
          snapshot: nil,
          observation: UgotAgentToolObservation.hostObservation(
            connectorId: connector.id,
            connectorTitle: connector.title,
            toolName: "mcp.tool_catalog",
            toolTitle: "도구 목록",
            outputText: message,
            status: "no_model_visible_tools"
          )
        )
      }
      return nil
    }

    return try await runToolLoop(
      prompt: prompt,
      catalog: catalog,
      emitNoToolFailure: emitNoToolFailure
    )
  }

  private static let maxAgentToolLoopSteps = 4

  private func runToolLoop(
    prompt: String,
    catalog: UgotMCPToolCatalog,
    emitNoToolFailure: Bool
  ) async throws -> UgotMCPActionResponse? {
    let allTools = catalog.allTools
    let planningTools = catalog.modelVisibleTools
    var observations: [UgotAgentToolObservation] = []
    var loopState = AgentToolLoopStateMachineKt.createAgentToolLoopState(maxSteps: Int32(Self.maxAgentToolLoopSteps))

    while loopState.canPlan {
      let availablePlanningTools = planningToolsForStep(
        planningTools,
        observations: observations,
        attemptedToolNames: Set(loopState.attemptedToolNames)
      )
      let stepSearchIndex = UgotMCPToolSearchIndex(tools: availablePlanningTools)
      // Search/ranking must use only the original user utterance. Previous
      // observations can contain tool names, schema field names, and error text
      // such as "birth_date" that are not user-provided evidence. Feeding that
      // back into retrieval makes the router re-select the failed tool.
      let stepPlanningTools = UgotMCPToolPlanner.toolsForModelPlanning(
        prompt: prompt,
        tools: availablePlanningTools,
        searchIndex: stepSearchIndex
      )
      let deterministicPlan = UgotMCPToolPlanner.fallbackPlanFromSearch(
        prompt: prompt,
        tools: stepPlanningTools,
        searchIndex: stepSearchIndex
      )
      let decision: UgotMCPToolPlanningDecision?
      if deterministicPlan == nil {
        decision = await toolPlanningProvider?(UgotMCPToolPlanningRequest(
          prompt: prompt,
          connectorId: connector.id,
          connectorTitle: connector.title,
          tools: stepPlanningTools,
          previousObservations: observations,
          stepIndex: Int(loopState.nextStepIndex),
          maxSteps: Self.maxAgentToolLoopSteps
        ))
      } else {
        decision = nil
      }
      let planned = deterministicPlan ?? UgotMCPToolPlanner.plan(
        prompt: prompt,
        tools: stepPlanningTools,
        decision: decision
      )

      guard let planned else {
        return noPlanResponse(
          prompt: prompt,
          observations: observations,
          decisionRequiresTool: decision?.requiresTool == true,
          emitNoToolFailure: emitNoToolFailure,
          stepIndex: Int(loopState.nextStepIndex)
        )
      }

      let signature = toolCallSignature(toolName: planned.name, arguments: planned.arguments)
      let callPolicy = AgentToolLoopStateMachineKt.agentToolLoopCanRunCall(
        state: loopState,
        toolName: planned.name,
        callSignature: signature
      )
      guard callPolicy.allowed else {
        let message = "\(planned.title) 도구가 같은 인자로 반복 계획되어 loop를 중단했어요."
        observations.append(makeObservation(
          toolName: "mcp.tool_replan",
          title: "도구 재계획",
          arguments: [
            "step": Int(loopState.nextStepIndex),
            "repeated_tool": planned.name,
            "reason": callPolicy.reason,
          ],
          tool: nil,
          outputText: message,
          hasWidget: false,
          didMutateOverride: false,
          status: "duplicate_tool_plan"
        ))
        return UgotMCPActionResponse(message: message, snapshot: nil, observations: observations)
      }

      loopState = AgentToolLoopStateMachineKt.agentToolLoopRecordCall(
        state: loopState,
        toolName: planned.name,
        callSignature: signature
      )
      let stepResponse = try await executePlannedTool(planned, prompt: prompt, allTools: allTools)
      let newObservations = stepResponse.observations
      observations.append(contentsOf: newObservations)
      loopState = AgentToolLoopStateMachineKt.agentToolLoopRecordObservations(
        state: loopState,
        observations: newObservations.map(loopObservation)
      )

      let nextAction = AgentToolLoopStateMachineKt.agentToolLoopNextActionAfterToolResponse(
        state: loopState,
        latestObservation: newObservations.last.map { loopObservation($0) },
        plannedTool: loopToolDescriptor(for: planned),
        hasApprovalRequest: stepResponse.approvalRequest != nil,
        hasWidget: stepResponse.snapshot != nil,
        newObservationCount: Int32(newObservations.count)
      )
      if nextAction.shouldStop {
        return response(stepResponse, replacingObservations: observations)
      }
    }

    let message = "도구 실행 단계 제한에 도달해서 추가 호출을 중단했어요."
    observations.append(makeObservation(
      toolName: "mcp.tool_loop",
      title: "도구 실행 loop",
      arguments: [
        "max_steps": Self.maxAgentToolLoopSteps,
      ],
      tool: nil,
      outputText: message,
      hasWidget: false,
      didMutateOverride: false,
      status: "step_limit"
    ))
    return UgotMCPActionResponse(message: message, snapshot: nil, observations: observations)
  }

  private func planningSearchPrompt(
    userPrompt: String,
    observations: [UgotAgentToolObservation]
  ) -> String {
    guard !observations.isEmpty else { return userPrompt }
    let compactObservations = observations
      .suffix(5)
      .map { "\($0.toolName) status=\($0.status) mutate=\($0.didMutate ? "yes" : "no") output=\($0.outputText.oneLineForPrompt(limit: 240))" }
      .joined(separator: "\n")
    return """
    \(userPrompt)

    Previous MCP observations:
    \(compactObservations)
    """
  }

  private func planningToolsForStep(
    _ tools: [[String: Any]],
    observations: [UgotAgentToolObservation],
    attemptedToolNames: Set<String>
  ) -> [[String: Any]] {
    guard let last = observations.last,
          shouldAvoidPreviouslyAttemptedTool(after: last),
          !attemptedToolNames.isEmpty else {
      return tools
    }
    let alternativeTools = tools.filter { tool in
      guard let name = tool["name"] as? String else { return false }
      return !attemptedToolNames.contains(name)
    }
    return alternativeTools.isEmpty ? tools : alternativeTools
  }

  private func shouldAvoidPreviouslyAttemptedTool(after observation: UgotAgentToolObservation) -> Bool {
    AgentToolLoopStateMachineKt.agentToolLoopShouldAvoidPreviouslyAttemptedTool(
      latestObservation: loopObservation(observation)
    )
  }

  private func noPlanResponse(
    prompt: String,
    observations: [UgotAgentToolObservation],
    decisionRequiresTool: Bool,
    emitNoToolFailure: Bool,
    stepIndex: Int
  ) -> UgotMCPActionResponse? {
    if !observations.isEmpty {
      if decisionRequiresTool {
        let message = "이전 도구 결과를 관찰했지만, 안전하게 이어서 실행할 다음 MCP 도구를 확정하지 못했어요."
        var out = observations
        out.append(makeObservation(
          toolName: "mcp.tool_replan",
          title: "도구 재계획",
          arguments: [
            "step": stepIndex,
            "prompt": prompt,
          ],
          tool: nil,
          outputText: message,
          hasWidget: false,
          didMutateOverride: false,
          status: "no_matching_tool"
        ))
        return UgotMCPActionResponse(message: message, snapshot: nil, observations: out)
      }
      return UgotMCPActionResponse(message: "도구 실행 결과를 확인했어요.", snapshot: nil, observations: observations)
    }

    guard decisionRequiresTool && emitNoToolFailure else { return nil }
    let message = """
    실행할 수 있는 MCP 도구를 찾지 못해서 아무 작업도 하지 않았어요.

    도구 승인 목록에서 connector와 도구가 켜져 있는지 확인하거나, 대상을 더 구체적으로 말해 주세요.
    """
    return UgotMCPActionResponse(
      message: message,
      snapshot: nil,
      observation: UgotAgentToolObservation.hostObservation(
        connectorId: connector.id,
        connectorTitle: connector.title,
        toolName: "mcp.tool_search",
        toolTitle: "도구 검색",
        argumentsPreview: compactArguments(["prompt": prompt]),
        outputText: message,
        status: "no_matching_tool"
      )
    )
  }

  private func response(
    _ response: UgotMCPActionResponse,
    replacingObservations observations: [UgotAgentToolObservation]
  ) -> UgotMCPActionResponse {
    UgotMCPActionResponse(
      message: response.message,
      snapshot: response.snapshot,
      approvalRequest: response.approvalRequest,
      observations: observations
    )
  }

  private func loopObservation(_ observation: UgotAgentToolObservation) -> AgentToolLoopObservation {
    AgentToolLoopObservation(
      connectorId: observation.connectorId,
      connectorTitle: observation.connectorTitle,
      toolName: observation.toolName,
      toolTitle: observation.toolTitle,
      argumentsPreview: observation.argumentsPreview,
      outputText: observation.outputText,
      hasWidget: observation.hasWidget,
      didMutate: observation.didMutate,
      status: observation.status
    )
  }

  private func loopToolDescriptor(for plan: UgotMCPToolPlan) -> AgentToolLoopToolDescriptor {
    AgentToolLoopToolDescriptor(
      name: plan.name,
      title: plan.title,
      isReadOnly: isReadOnlyTool(plan.tool),
      isDestructive: isDestructiveTool(plan.tool),
      hasWidget: UgotMCPClient.widgetResourceURI(from: plan.tool) != nil
    )
  }

  private func toolCallSignature(toolName: String, arguments: [String: Any]) -> String {
    guard JSONSerialization.isValidJSONObject(arguments),
          let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]),
          let json = String(data: data, encoding: .utf8) else {
      return "\(toolName)::{}"
    }
    return "\(toolName)::\(json)"
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
    let prepared = try await preparePlanForExecution(planned, prompt: prompt, tools: tools)
    let plan = prepared.plan
    let prefixObservations = prepared.observations
    let missingArguments = missingRequiredArguments(for: plan.tool, arguments: plan.arguments)
    if !missingArguments.isEmpty {
      let message = """
      \(plan.title) 도구를 실행하려면 \(missingArguments.joined(separator: ", ")) 값이 더 필요해요.

      예: “기본사용자를 Yw로 바꿔”처럼 대상 이름을 함께 말하거나, 먼저 저장목록에서 대상을 선택해 주세요.
      """
      return UgotMCPActionResponse(
        message: message,
        snapshot: nil,
        observation: makeObservation(
          toolName: plan.name,
          title: plan.title,
          arguments: plan.arguments,
          tool: plan.tool,
          outputText: message,
          hasWidget: false,
          didMutateOverride: false,
          status: "missing_arguments"
        ),
        observations: prefixObservations
      )
    }
    let descriptor = UgotMCPToolDescriptor(connectorId: connector.id, tool: plan.tool)
    let policy = UgotMCPToolApprovalStore.policy(connectorId: connector.id, descriptor: descriptor)
    switch policy {
    case .deny:
      let message = """
      \(plan.title) 도구는 현재 차단되어 있어요.

      상단 슬라이더 → 도구 승인 → \(connector.title)에서 정책을 바꿀 수 있어요.
      """
      return UgotMCPActionResponse(
        message: message,
        snapshot: nil,
        observation: makeObservation(
          toolName: plan.name,
          title: plan.title,
          arguments: plan.arguments,
          tool: plan.tool,
          outputText: message,
          hasWidget: false,
          didMutateOverride: false,
          status: "blocked"
        ),
        observations: prefixObservations
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
        ),
        observations: prefixObservations
      )
    case .allow:
      do {
        let response = try await executeTool(
          toolName: plan.name,
          title: plan.title,
          arguments: plan.arguments,
          tools: tools
        )
        guard !prefixObservations.isEmpty else { return response }
        return UgotMCPActionResponse(
          message: response.message,
          snapshot: response.snapshot,
          approvalRequest: response.approvalRequest,
          observations: prefixObservations + response.observations
        )
      } catch {
        let message = "\(plan.title) 도구 호출에 실패했어요. \(error.localizedDescription)"
        return UgotMCPActionResponse(
          message: message,
          snapshot: nil,
          observation: makeObservation(
            toolName: plan.name,
            title: plan.title,
            arguments: plan.arguments,
            tool: plan.tool,
            outputText: message,
            hasWidget: false,
            didMutateOverride: false,
            status: "error"
          ),
          observations: prefixObservations
        )
      }
    }
  }

  private struct PreparedMCPToolPlan {
    let plan: UgotMCPToolPlan
    let observations: [UgotAgentToolObservation]
  }

  private func preparePlanForExecution(
    _ plan: UgotMCPToolPlan,
    prompt: String,
    tools: [[String: Any]]
  ) async throws -> PreparedMCPToolPlan {
    let promptArguments = UgotMCPToolPlanner.schemaArguments(from: prompt, for: plan.tool)
    let seededPlan = plan.with(
      arguments: UgotMCPToolPlanner.mergeMissingArguments(plan.arguments, fallback: promptArguments)
    )
    let missing = missingRequiredArguments(for: seededPlan.tool, arguments: seededPlan.arguments)
    guard !missing.isEmpty else {
      return PreparedMCPToolPlan(plan: seededPlan, observations: [])
    }

    var arguments = seededPlan.arguments
    var observations: [UgotAgentToolObservation] = []
    for parameterName in missing where isOpaqueReferenceParameter(parameterName) {
      guard arguments[parameterName] == nil else { continue }
      let resolved = await resolveOpaqueReference(
        parameterName: parameterName,
        prompt: prompt,
        entityReference: seededPlan.entityReference,
        targetToolName: seededPlan.name,
        tools: tools
      )
      observations.append(contentsOf: resolved.observations)
      if let value = resolved.value {
        arguments[parameterName] = value
      }
    }

    return PreparedMCPToolPlan(plan: seededPlan.with(arguments: arguments), observations: observations)
  }

  private func resolveOpaqueReference(
    parameterName: String,
    prompt: String,
    entityReference: String?,
    targetToolName: String,
    tools: [[String: Any]]
  ) async -> (value: Any?, observations: [UgotAgentToolObservation]) {
    let trimmedEntityReference = entityReference?.trimmingCharacters(in: .whitespacesAndNewlines)
    let searchText = trimmedEntityReference?.isEmpty == false
      ? trimmedEntityReference
      : entitySearchText(from: prompt)
    guard let searchText else { return (nil, []) }
    let resolvers = resolverTools(
      parameterName: parameterName,
      targetToolName: targetToolName,
      searchText: searchText,
      tools: tools
    )
    guard !resolvers.isEmpty else { return (nil, []) }

    var observations: [UgotAgentToolObservation] = []
    for resolver in resolvers.prefix(3) {
      do {
        let result = try await mcpClient.callTool(name: resolver.name, arguments: resolver.arguments)
        let value = extractResolvedValue(
          from: result,
          preferredKeys: preferredResolverKeys(for: parameterName)
        )
        let output = renderToolResult(result, toolName: resolver.name)
        observations.append(
          makeObservation(
            toolName: resolver.name,
            title: resolver.name,
            arguments: resolver.arguments,
            tool: resolver.tool,
            outputText: output.isEmpty
              ? (value == nil ? "참조 값을 찾지 못했어요." : "참조 값을 찾았어요.")
              : output,
            hasWidget: false,
            didMutateOverride: false,
            status: value == nil ? "no_resolved_value" : "success"
          )
        )
        if let value {
          return (value, observations)
        }
      } catch {
        observations.append(
          makeObservation(
            toolName: resolver.name,
            title: resolver.name,
            arguments: resolver.arguments,
            tool: resolver.tool,
            outputText: "참조 조회 도구 호출에 실패했어요. \(error.localizedDescription)",
            hasWidget: false,
            didMutateOverride: false,
            status: "error"
          )
        )
      }
    }
    return (nil, observations)
  }

  private func resolverTools(
    parameterName: String,
    targetToolName: String,
    searchText: String,
    tools: [[String: Any]]
  ) -> [(tool: [String: Any], name: String, arguments: [String: Any])] {
    let parameterTerms = parameterName
      .replacingOccurrences(of: "_", with: " ")
      .replacingOccurrences(of: "-", with: " ")
    let query = "\(searchText) \(parameterTerms) find search lookup resolve list get"
    let candidates = UgotMCPToolSearchIndex(tools: tools).search(query: query, limit: 8)

    let ranked = candidates.compactMap { result -> (tool: [String: Any], name: String, arguments: [String: Any], score: Int)? in
      guard let name = result.tool["name"] as? String,
            name != targetToolName,
            isReadOnlyTool(result.tool),
            UgotMCPClient.widgetResourceURI(from: result.tool) == nil,
            !isDestructiveTool(result.tool) else {
        return nil
      }
      guard let searchParameter = fillableSearchParameter(in: result.tool) else {
        return nil
      }
      let document = UgotMCPToolSearchIndex.document(for: result.tool)
      let resolverWords = ["find", "search", "lookup", "resolve", "list", "get"]
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
      return (result.tool, name, arguments, score)
    }

    return ranked
      .sorted { $0.score > $1.score }
      .map { ($0.tool, $0.name, $0.arguments) }
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
    keys += ["id"]
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

  private func isReadOnlyTool(_ tool: [String: Any]) -> Bool {
    if let annotations = tool["annotations"] as? [String: Any],
       let readOnly = annotationBool(annotations["readOnlyHint"]) {
      return readOnly
    }
    return inferredReadOnlyFromToolName(tool)
  }

  private func isDestructiveTool(_ tool: [String: Any]) -> Bool {
    if let annotations = tool["annotations"] as? [String: Any],
       let destructive = annotationBool(annotations["destructiveHint"]) {
      return destructive
    }
    let document = UgotMCPToolSearchIndex.document(for: tool)
    return ["delete", "remove", "clear", "reset", "unset"].contains { document.contains($0) }
  }

  private func inferredReadOnlyFromToolName(_ tool: [String: Any]) -> Bool {
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

  private func annotationBool(_ raw: Any?) -> Bool? {
    if let value = raw as? Bool { return value }
    if let value = raw as? NSNumber { return value.boolValue }
    if let value = raw as? String {
      let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      if ["true", "yes", "1"].contains(normalized) { return true }
      if ["false", "no", "0"].contains(normalized) { return false }
    }
    return nil
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
    let tool = tools.first(where: { ($0["name"] as? String) == toolName })
    let toolDeclaresWidget = tool.flatMap { UgotMCPClient.widgetResourceURI(from: $0) } != nil
    let observation = makeObservation(
      toolName: toolName,
      title: title,
      arguments: arguments,
      tool: tool,
      outputText: message.isEmpty ? "도구가 결과 텍스트 없이 성공 상태를 반환했어요." : message,
      hasWidget: widgetResource != nil || toolDeclaresWidget,
      status: "success"
    )
    guard let widgetResource else {
      // Data-only tools, e.g. preference mutations, should not go
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

  private func makeObservation(
    toolName: String,
    title: String,
    arguments: [String: Any],
    tool: [String: Any]?,
    outputText: String,
    hasWidget: Bool,
    didMutateOverride: Bool? = nil,
    status: String
  ) -> UgotAgentToolObservation {
    let descriptor = tool.map { UgotMCPToolDescriptor(connectorId: connector.id, tool: $0) }
    return UgotAgentToolObservation(
      connectorId: connector.id,
      connectorTitle: connector.title,
      toolName: toolName,
      toolTitle: descriptor?.title ?? title,
      argumentsPreview: compactArguments(arguments),
      outputText: outputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? "도구가 결과 텍스트 없이 상태 \(status)를 반환했어요."
        : outputText,
      hasWidget: hasWidget,
      didMutate: didMutateOverride ?? (status == "success" && !(descriptor?.isReadOnly ?? false)),
      status: status
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
      if let summary = markdownSummary(from: structured),
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

    if let content = result["content"] as? [[String: Any]] {
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
