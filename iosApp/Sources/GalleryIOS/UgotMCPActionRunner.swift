import Foundation
import GallerySharedCore

enum UgotMCPActionRunner {
  static func runIfNeeded(
    prompt: String,
    activeSkillIds: Set<String>,
    activeConnectorIds: Set<String>,
    sessionId: String
  ) async -> GalleryChatActionResult? {
    let activeConnectors = GalleryConnector.samples.filter { activeConnectorIds.contains($0.id) }
    guard !activeConnectors.isEmpty else { return nil }

    do {
      guard let accessToken = try await UgotAuthStore.validAccessToken() else {
        return GalleryChatActionResult(message: "UGOT 세션이 만료됐어요. 다시 로그인해 주세요.")
      }
      for connector in activeConnectors {
        let client = UgotMCPConnectorAction(
          connector: connector,
          accessToken: accessToken,
          sessionId: sessionId
        )
        if let response = try await client.run(prompt: prompt) {
          return GalleryChatActionResult(
            message: response.message,
            widgetSnapshot: response.snapshot,
            approvalRequest: response.approvalRequest
          )
        }
      }
      return nil
    } catch {
      return GalleryChatActionResult(message: "MCP 호출에 실패했어요.\n\n\(error.localizedDescription)")
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
        approvalRequest: response.approvalRequest
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

  init(
    message: String,
    snapshot: McpWidgetSnapshot?,
    approvalRequest: UgotMCPToolApprovalRequest? = nil
  ) {
    self.message = message
    self.snapshot = snapshot
    self.approvalRequest = approvalRequest
  }
}

struct UgotMCPToolApprovalRequest: Identifiable, Equatable {
  let sessionId: String
  let connectorId: String
  let connectorTitle: String
  let toolName: String
  let toolTitle: String
  let argumentsPreview: String

  var id: String { "\(sessionId)::\(connectorId)::\(toolName)" }
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
  let isDestructive: Bool
  let hasWidget: Bool
  let requiredParameters: [String]

  var id: String { "\(connectorId)::\(name)" }

  var defaultApprovalPolicy: UgotMCPToolApprovalPolicy {
    isDestructive ? .ask : .allow
  }

  init(connectorId: String, tool: [String: Any]) {
    self.connectorId = connectorId
    let rawName = tool["name"] as? String ?? "unknown_tool"
    name = rawName
    title = Self.displayTitle(for: tool, fallbackName: rawName)
    summary = (tool["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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
}

struct UgotMCPPendingToolApproval: Codable, Equatable {
  let sessionId: String
  let connectorId: String
  let toolName: String
  let toolTitle: String
  let argumentsJson: String
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
    arguments: [String: Any]
  ) {
    let data = (try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])) ?? Data("{}".utf8)
    let pending = UgotMCPPendingToolApproval(
      sessionId: sessionId,
      connectorId: connectorId,
      toolName: toolName,
      toolTitle: toolTitle,
      argumentsJson: String(data: data, encoding: .utf8) ?? "{}",
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

private struct UgotMCPToolPlan {
  let tool: [String: Any]
  let name: String
  let title: String
  let arguments: [String: Any]
  let score: Int
}

private enum UgotMCPToolPlanner {
  static func plan(prompt: String, tools: [[String: Any]]) -> UgotMCPToolPlan? {
    let signals = PromptSignals(prompt: prompt)
    guard signals.shouldConsiderTools else { return nil }

    let ranked = tools.compactMap { tool -> UgotMCPToolPlan? in
      guard let name = tool["name"] as? String, !name.isEmpty else { return nil }
      guard !isBlocked(tool: tool, signals: signals) else { return nil }
      let score = score(tool: tool, signals: signals)
      guard score >= 7 else { return nil }
      return UgotMCPToolPlan(
        tool: tool,
        name: name,
        title: displayTitle(for: tool, fallbackName: name),
        arguments: arguments(for: tool, signals: signals),
        score: score
      )
    }
    return ranked.sorted { lhs, rhs in
      if lhs.score != rhs.score { return lhs.score > rhs.score }
      return hasWidget(tool: lhs.tool) && !hasWidget(tool: rhs.tool)
    }.first
  }

  private static func score(tool: [String: Any], signals: PromptSignals) -> Int {
    let haystack = searchableText(for: tool)
    let compactHaystack = haystack
      .replacingOccurrences(of: "[^\\p{L}\\p{N}]+", with: "", options: .regularExpression)
    let name = ((tool["name"] as? String) ?? "").lowercased()
    let compactName = name.replacingOccurrences(of: "[^\\p{L}\\p{N}]+", with: "", options: .regularExpression)
    let guidance = ToolGuidance(tool: tool, searchableText: haystack)
    var score = 0

    if signals.normalized.contains(compactName) || compactHaystack.contains(signals.normalized) {
      score += 20
    }

    for term in signals.weightedTerms {
      if haystack.contains(term.value) {
        score += term.weight
      }
    }

    for token in signals.tokens where token.count >= 3 {
      if haystack.contains(token) {
        score += 2
      }
    }

    if signals.isListIntent, containsAny(haystack, ["list", "view", "get", "registered", "saved", "profile", "profiles", "user", "users"]) {
      score += 6
    }
    if signals.isCurrentDayIntent, containsAny(haystack, ["today", "daily", "day", "date", "current"]) {
      score += 6
    }
    if signals.isGenericTodayFortuneIntent {
      if compactName.contains("showtodayfortune") {
        score += 42
      } else if containsAny(haystack, ["today fortune", "fortune for today", "today's fortune", "show today"]) {
        score += 24
      } else if compactName.contains("showsajudaily") {
        score += 5
      }
    }
    if signals.isShowIntent, containsAny(haystack, ["show", "view", "display", "open", "get"]) {
      score += 3
    }
    if hasWidget(tool: tool), signals.isShowIntent || signals.isListIntent || signals.isCurrentDayIntent {
      score += 2
    }
    // Prefer generic resolver tools when the prompt asks for a current-day/list result
    // without enough explicit target fields. This reads MCP tool metadata guidance
    // instead of pinning behavior to one connector or one tool name.
    if signals.needsGenericTargetResolution, guidance.isGenericTargetResolver {
      score += 14
    }
    if signals.isListIntent,
       guidance.isGenericTargetResolver,
       !containsAny(haystack, ["list", "registered", "profiles", "users", "saved users"]) {
      score -= 10
    }
    if !signals.hasExplicitTargetData, guidance.requiresKnownTarget {
      score -= 14
    }
    if signals.needsGenericTargetResolution, guidance.saysUseAnotherToolFirst {
      score -= 12
    }
    if !signals.hasExplicitTargetData,
       guidance.targetLikeParameterCount >= 3,
       guidance.requiresKnownTarget,
       !guidance.isGenericTargetResolver {
      score -= 8
    }
    if !missingRequiredParameters(tool: tool, signals: signals).isEmpty {
      score -= 40
    }
    if isDestructive(tool: tool), !signals.isMutationIntent {
      score -= 20
    }
    return score
  }

  private static func arguments(for tool: [String: Any], signals: PromptSignals) -> [String: Any] {
    guard let schema = tool["inputSchema"] as? [String: Any],
          let properties = schema["properties"] as? [String: Any] else {
      return [:]
    }

    var arguments: [String: Any] = [:]
    for (rawName, rawProperty) in properties {
      guard let property = rawProperty as? [String: Any] else { continue }
      let name = rawName.lowercased()
      if let value = property["default"], !(value is NSNull) {
        arguments[rawName] = value
      } else if name == "lang" || name == "locale" {
        arguments[rawName] = "ko"
      } else if name == "sort", let enumValues = property["enum"] as? [String], enumValues.contains("default") {
        arguments[rawName] = "default"
      } else if name == "sort" {
        arguments[rawName] = "default"
      } else if (name.contains("date") || name == "day") && signals.isCurrentDayIntent {
        arguments[rawName] = todayString()
      }
    }
    return arguments
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

  private static func searchableText(for tool: [String: Any]) -> String {
    [
      tool["name"] as? String,
      tool["title"] as? String,
      tool["description"] as? String,
      (tool["annotations"] as? [String: Any])?["title"] as? String,
    ]
      .compactMap { $0 }
      .joined(separator: " ")
      .lowercased()
      .replacingOccurrences(of: "_", with: " ")
      .replacingOccurrences(of: "-", with: " ")
  }

  private static func hasWidget(tool: [String: Any]) -> Bool {
    UgotMCPClient.widgetResourceURI(from: tool) != nil
  }

  private static func isDestructive(tool: [String: Any]) -> Bool {
    if let annotations = tool["annotations"] as? [String: Any],
       let destructive = annotations["destructiveHint"] as? Bool {
      return destructive
    }
    let name = ((tool["name"] as? String) ?? "").lowercased()
    return containsAny(name, ["delete", "remove", "clear", "reset"])
  }

  private static func isBlocked(tool: [String: Any], signals: PromptSignals) -> Bool {
    // Destructive MCP tools must not be selected by metadata similarity alone.
    // Example: `clear_default_user` contains "default/current/saved user" words,
    // so a generic "오늘의 운세 뭐야" prompt used to outscore the intended
    // `show_today_fortune` path. Keep destructive tools opt-in only.
    if isDestructive(tool: tool), !signals.isDestructiveMutationIntent {
      return true
    }
    return false
  }

  private static func containsAny(_ text: String, _ terms: [String]) -> Bool {
    terms.contains { text.contains($0) }
  }

  private static func todayString() -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "Asia/Seoul") ?? .current
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: Date())
  }

  private static func missingRequiredParameters(tool: [String: Any], signals: PromptSignals) -> [String] {
    guard let schema = tool["inputSchema"] as? [String: Any],
          let required = schema["required"] as? [String],
          !required.isEmpty else {
      return []
    }
    return required.filter { !canFill(parameterName: $0, tool: tool, signals: signals) }
  }

  private static func canFill(parameterName rawName: String, tool: [String: Any], signals: PromptSignals) -> Bool {
    let name = rawName.lowercased()
    if parameterDefaultValue(parameterName: rawName, tool: tool) != nil { return true }
    if name == "lang" || name == "locale" || name == "sort" { return true }
    if (name.contains("date") || name == "day") && (signals.isCurrentDayIntent || signals.hasDateLikeValue) { return true }
    if name.contains("time") && signals.hasTimeLikeValue { return true }
    if name.contains("gender") || name.contains("sex") { return signals.hasGenderLikeValue }
    return false
  }

  private static func parameterDefaultValue(parameterName rawName: String, tool: [String: Any]) -> Any? {
    guard let schema = tool["inputSchema"] as? [String: Any],
          let properties = schema["properties"] as? [String: Any],
          let property = properties[rawName] as? [String: Any],
          let value = property["default"],
          !(value is NSNull) else {
      return nil
    }
    return value
  }

  private struct ToolGuidance {
    let isGenericTargetResolver: Bool
    let requiresKnownTarget: Bool
    let saysUseAnotherToolFirst: Bool
    let targetLikeParameterCount: Int

    init(tool: [String: Any], searchableText: String) {
      let text = searchableText
      isGenericTargetResolver =
        text.contains("use this for generic") ||
        text.contains("prefer the user") ||
        text.contains("default saved") ||
        text.contains("default profile") ||
        text.contains("profile selection") ||
        text.contains("birth input") ||
        text.contains("missing target") ||
        text.contains("target or default")

      requiresKnownTarget =
        text.contains("only when") ||
        text.contains("already known") ||
        text.contains("concrete saved") ||
        text.contains("specific person") ||
        text.contains("explicit target")

      saysUseAnotherToolFirst =
        text.contains("use ") && text.contains(" first") &&
        (text.contains("generic request") || text.contains("ambiguous"))

      if let schema = tool["inputSchema"] as? [String: Any],
         let properties = schema["properties"] as? [String: Any] {
        targetLikeParameterCount = properties.keys.filter(Self.isTargetLikeParameter).count
      } else {
        targetLikeParameterCount = 0
      }
    }

    private static func isTargetLikeParameter(_ rawName: String) -> Bool {
      let name = rawName.lowercased()
      return name.contains("birth") ||
        name.contains("gender") ||
        name.contains("sex") ||
        name == "name" ||
        name.hasSuffix("_name") ||
        name.contains("target")
    }
  }

  private struct WeightedTerm {
    let value: String
    let weight: Int
  }

  private struct PromptSignals {
    let original: String
    let lowercased: String
    let normalized: String
    let tokens: [String]
    let weightedTerms: [WeightedTerm]
    let isListIntent: Bool
    let isCurrentDayIntent: Bool
    let isFortuneIntent: Bool
    let isShowIntent: Bool
    let isMutationIntent: Bool
    let isDestructiveMutationIntent: Bool
    let hasDateLikeValue: Bool
    let hasTimeLikeValue: Bool
    let hasGenderLikeValue: Bool

    init(prompt: String) {
      original = prompt
      lowercased = prompt.lowercased()
      normalized = lowercased.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
      tokens = lowercased
        .replacingOccurrences(of: "[^\\p{L}\\p{N}_-]+", with: " ", options: .regularExpression)
        .split(separator: " ")
        .map(String.init)

      isListIntent = Self.hasAny(normalized, ["목록", "리스트", "list", "profiles", "registered", "saved"])
      isCurrentDayIntent = Self.hasAny(normalized, ["오늘", "금일", "today", "daily", "current"])
      isFortuneIntent = Self.hasAny(normalized, ["운세", "사주", "fortune", "saju", "iljin", "ilji"])
      isShowIntent = Self.hasAny(normalized, ["보여", "열어", "조회", "불러", "알려", "뭐야", "뭔가", "뭔지", "어때", "show", "view", "open", "display", "get"])
      isDestructiveMutationIntent = Self.hasAny(normalized, ["삭제", "지워", "초기화", "해제", "취소", "clear", "delete", "remove", "reset", "unset"])
      isMutationIntent = isDestructiveMutationIntent || Self.hasAny(normalized, ["저장해", "설정", "변경", "save", "set", "update"])
      hasDateLikeValue = Self.matches(lowercased, pattern: "\\b\\d{4}[-./년 ]\\d{1,2}[-./월 ]\\d{1,2}\\b") ||
        Self.matches(lowercased, pattern: "\\b\\d{6,8}\\b")
      hasTimeLikeValue = Self.matches(lowercased, pattern: "\\b\\d{1,2}:\\d{2}\\b") ||
        Self.hasAny(normalized, ["오전", "오후", "am", "pm", "시생", "출생시"])
      hasGenderLikeValue = Self.hasAny(normalized, ["남자", "남성", "여자", "여성", "male", "female"])

      var terms: [WeightedTerm] = []
      if isListIntent {
        terms += ["list", "view", "get", "saved", "registered", "profile", "profiles", "user", "users"]
          .map { WeightedTerm(value: $0, weight: 4) }
      }
      if isCurrentDayIntent {
        terms += ["today", "daily", "current", "date", "day"].map { WeightedTerm(value: $0, weight: 4) }
      }
      if isShowIntent {
        terms += ["show", "view", "open", "display", "get"].map { WeightedTerm(value: $0, weight: 3) }
      }
      if isMutationIntent {
        terms += ["save", "delete", "remove", "set", "update", "clear"].map { WeightedTerm(value: $0, weight: 3) }
      }
      weightedTerms = terms
    }

    var hasExplicitTargetData: Bool {
      hasDateLikeValue && hasTimeLikeValue && hasGenderLikeValue
    }

    var needsGenericTargetResolution: Bool {
      isCurrentDayIntent && !isListIntent && !hasExplicitTargetData
    }

    var isGenericTodayFortuneIntent: Bool {
      isCurrentDayIntent && isFortuneIntent && !isListIntent && !hasExplicitTargetData
    }

    var shouldConsiderTools: Bool {
      isFortuneIntent || isListIntent || isGenericTodayFortuneIntent || isMutationIntent ||
        tokens.contains { $0.contains("_") || $0.contains("-") }
    }

    private static func hasAny(_ text: String, _ terms: [String]) -> Bool {
      terms.contains { text.contains($0) }
    }

    private static func matches(_ text: String, pattern: String) -> Bool {
      text.range(of: pattern, options: .regularExpression) != nil
    }
  }
}

final class UgotMCPConnectorAction {
  private let connector: GalleryConnector
  private let mcpClient: UgotMCPClient
  private let sessionId: String

  init(connector: GalleryConnector, accessToken: String, sessionId: String) {
    self.connector = connector
    self.sessionId = sessionId
    self.mcpClient = UgotMCPClient(
      connectorId: connector.id,
      endpoint: URL(string: connector.endpoint)!,
      accessToken: accessToken
    )
  }

  func run(prompt: String) async throws -> UgotMCPActionResponse? {
    try await mcpClient.initialize()
    let tools = try await mcpClient.listTools()
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
          argumentsPreview: pending.argumentsJson
        )
      )
    }

    guard let plan = UgotMCPToolPlanner.plan(prompt: prompt, tools: tools) else {
      return nil
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
        arguments: plan.arguments
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
          argumentsPreview: argumentsPreview
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

  func runApprovedPending() async throws -> UgotMCPActionResponse? {
    try await mcpClient.initialize()
    let tools = try await mcpClient.listTools()
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
      )
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
