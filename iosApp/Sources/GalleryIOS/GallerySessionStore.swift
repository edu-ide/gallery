import Foundation
import GallerySharedCore

struct GallerySessionSummary: Identifiable {
  let id: String
  let title: String
  let modelName: String
  let taskId: String
  let updatedAt: Date
  let messageCount: Int
  let activeConnectorIds: [String]
  let entryHint: UnifiedChatEntryHint
}

struct GallerySessionStore {
  private static let ioQueue = DispatchQueue(label: "com.ugot.galleryios.session-store.io", qos: .utility)

  private let directory: URL

  init(fileManager: FileManager = .default) {
    let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
      ?? fileManager.temporaryDirectory
    directory = appSupport.appendingPathComponent("GalleryIOS/UnifiedChatSessions", isDirectory: true)
    try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  static func makeSessionId(taskId: String, modelName: String, entryHint: UnifiedChatEntryHint) -> String {
    UnifiedChatPersistedSessionKt.buildUnifiedChatSessionId(
      taskId: taskId,
      modelName: modelName,
      entryHint: entryHint
    )
  }

  static func makeNewSessionId(taskId: String, modelName: String, entryHint: UnifiedChatEntryHint) -> String {
    "\(makeSessionId(taskId: taskId, modelName: modelName, entryHint: entryHint))::session=\(UUID().uuidString)"
  }

  func load(id: String) -> UnifiedChatPersistedSession? {
    let url = fileURL(id: id)
    return load(url: url)
  }

  func listSessions() -> [GallerySessionSummary] {
    let urls = (try? FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.contentModificationDateKey],
      options: [.skipsHiddenFiles]
    )) ?? []

    return urls
      .filter { $0.pathExtension == "json" }
      .compactMap(loadSummary(url:))
      .sorted { $0.updatedAt > $1.updatedAt }
  }

  func save(_ session: UnifiedChatPersistedSession) {
    let url = fileURL(id: session.id)
    let json = UnifiedChatPersistedSessionKt.encodeUnifiedChatPersistedSession(session: session)
    let tempURL = url.appendingPathExtension("tmp")
    do {
      try json.write(to: tempURL, atomically: true, encoding: .utf8)
      if FileManager.default.fileExists(atPath: url.path) {
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
      } else {
        try FileManager.default.moveItem(at: tempURL, to: url)
      }
    } catch {
      try? FileManager.default.removeItem(at: tempURL)
    }
  }

  func delete(id: String) {
    try? FileManager.default.removeItem(at: fileURL(id: id))
  }

  func saveInBackground(_ session: UnifiedChatPersistedSession) {
    Self.ioQueue.async {
      save(session)
    }
  }

  func deleteInBackground(id: String) {
    Self.ioQueue.async {
      delete(id: id)
    }
  }

  private func parseSessionKey(id: String) -> UnifiedChatSessionKey? {
    if let key = UnifiedChatPersistedSessionKt.parseUnifiedChatSessionId(id: id) {
      return key
    }
    let parts = id.components(separatedBy: "::")
    if parts.count > 3 {
      let baseId = parts.prefix(3).joined(separator: "::")
      return UnifiedChatPersistedSessionKt.parseUnifiedChatSessionId(id: baseId)
    }
    return nil
  }

  private func load(url: URL) -> UnifiedChatPersistedSession? {
    guard let data = try? Data(contentsOf: url),
          let json = String(data: data, encoding: .utf8) else {
      return nil
    }
    return UnifiedChatPersistedSessionKt.decodeUnifiedChatPersistedSession(jsonValue: json)
  }

  private func loadSummary(url: URL) -> GallerySessionSummary? {
    guard let object = loadSummaryObject(url: url),
          let id = object["id"] as? String,
          let title = object["title"] as? String,
          let key = parseSessionKey(id: id) else {
      return nil
    }

    let agentSkillIds = (object["activeAgentSkillIds"] as? [Any])?.compactMap { $0 as? String } ?? []
    let connectorIds = (object["activeConnectorIds"] as? [Any])?.compactMap { $0 as? String } ?? []
    let messageCount = (object["messagesJson"] as? [Any])?.count ?? 0
    let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    let entryHint = UnifiedChatEntryHint(
      activateImage: key.entryHint.activateImage,
      activateAudio: key.entryHint.activateAudio,
      activateSkills: !agentSkillIds.isEmpty,
      activateAgentSkillIds: agentSkillIds,
      activateMcpConnectorIds: connectorIds
    )

    return GallerySessionSummary(
      id: id,
      title: title,
      modelName: key.modelName,
      taskId: key.taskId,
      updatedAt: modified,
      messageCount: messageCount,
      activeConnectorIds: connectorIds,
      entryHint: entryHint
    )
  }

  private func loadSummaryObject(url: URL) -> [String: Any]? {
    if let object = loadSummaryObjectFromPrefix(url: url) {
      return object
    }
    guard let data = try? Data(contentsOf: url) else {
      return nil
    }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }

  private func loadSummaryObjectFromPrefix(url: URL) -> [String: Any]? {
    guard let handle = try? FileHandle(forReadingFrom: url) else {
      return nil
    }
    defer { try? handle.close() }

    let prefixData = handle.readData(ofLength: 1_048_576)
    guard !prefixData.isEmpty else { return nil }

    let prefix = String(decoding: prefixData, as: UTF8.self)
    let summaryCutRange = ["\"messagesJson\"", "\"widgetSnapshots\""]
      .compactMap { prefix.range(of: $0) }
      .min { $0.lowerBound < $1.lowerBound }
    guard let summaryCutRange else {
      return nil
    }

    var head = String(prefix[..<summaryCutRange.lowerBound])
    while head.last?.isWhitespace == true {
      head.removeLast()
    }
    if head.last == "," {
      head.removeLast()
    }
    let summaryJson = head + "}"
    guard let data = summaryJson.data(using: .utf8) else {
      return nil
    }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }

  private func fileURL(id: String) -> URL {
    directory.appendingPathComponent(UnifiedChatPersistedSessionKt.unifiedChatSessionFileName(id: id))
  }
}

extension UnifiedChatSessionState {
  func persistedSession(
    id: String,
    title: String? = nil,
    widgetSnapshotsByMessageId: [String: McpWidgetSnapshot] = [:]
  ) -> UnifiedChatPersistedSession? {
    let orderedWidgetSnapshots = messages.compactMap { widgetSnapshotsByMessageId[$0.id] }
    let encodedMessages = messages.map { message in
      let widgetSnapshot = widgetSnapshotsByMessageId[message.id]
      let envelope = UnifiedChatPersistedMessageEnvelope(
        type: widgetSnapshot == nil ? message.role.persistedType : .mcpWidgetCard,
        side: message.role.persistedSide,
        content: message.text,
        isMarkdown: true,
        latencyMs: nil,
        accelerator: nil,
        hideSenderLabel: nil,
        inProgress: nil,
        connectorId: widgetSnapshot?.connectorId,
        title: widgetSnapshot?.title,
        summary: widgetSnapshot?.summary,
        snapshot: nil,
        disableBubbleShape: widgetSnapshot == nil ? nil : true
      )
      return UnifiedChatPersistedMessageKt.encodeUnifiedChatPersistedMessageEnvelope(envelope: envelope)
    }
    let snapshots = orderedWidgetSnapshots.isEmpty
      ? (widgetHostState.activeSnapshot.map { [$0] } ?? [])
      : orderedWidgetSnapshots

    if encodedMessages.isEmpty && agentSkillState.activeSkillIds.isEmpty && connectorBarState.activeConnectorIds.isEmpty && snapshots.isEmpty {
      return nil
    }

    return UnifiedChatPersistedSession(
      id: id,
      title: title ?? derivedTitle,
      activeAgentSkillIds: Array(agentSkillState.activeSkillIds).sorted(),
      activeConnectorIds: Array(connectorBarState.activeConnectorIds).sorted(),
      messagesJson: encodedMessages,
      widgetSnapshots: snapshots
    )
  }

  func restoring(_ persisted: UnifiedChatPersistedSession) -> UnifiedChatSessionState {
    let restoredMessages = persisted.messagesJson.enumerated().compactMap { index, json in
      UnifiedChatPersistedMessageKt.decodeUnifiedChatPersistedMessageEnvelope(jsonValue: json)?
        .toUnifiedMessage(id: "r\(index)")
    }
    let restoredWidgetSnapshots = persisted.restoredWidgetSnapshotsByMessageId()
    let nextIndex = Int32(restoredMessages.count)
    let restoredWidgetState: McpWidgetHostState = {
      if let latestSnapshot = restoredMessages.reversed().compactMap({ restoredWidgetSnapshots[$0.id] }).first
        ?? persisted.widgetSnapshots.last {
        return widgetHostState.activate(snapshot: latestSnapshot, fullscreen: false)
      }
      return widgetHostState.close()
    }()

    return doCopy(
      modelName: modelName,
      modelDisplayName: modelDisplayName,
      taskId: taskId,
      modelCapabilities: modelCapabilities,
      entryHint: entryHint,
      agentSkillState: AgentSkillState(
        visibleSkillIds: agentSkillState.visibleSkillIds,
        activeSkillIds: Set(persisted.activeAgentSkillIds)
      ),
      connectorBarState: ConnectorBarState(
        visibleConnectorIds: connectorBarState.visibleConnectorIds,
        activeConnectorIds: Set(persisted.activeConnectorIds)
      ),
      messages: restoredMessages.isEmpty ? messages : restoredMessages,
      draft: draft,
      widgetHostState: restoredWidgetState,
      nextMessageIndex: nextIndex
    )
  }

  private var derivedTitle: String {
    if let firstUser = messages.first(where: { $0.role == .user && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
      return String(firstUser.text.split(separator: "\n", omittingEmptySubsequences: false).first ?? "New chat").prefixString(60)
    }
    if let firstAssistant = messages.first(where: { $0.role == .assistant && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
      return String(firstAssistant.text.split(separator: "\n", omittingEmptySubsequences: false).first ?? "New chat").prefixString(60)
    }
    return "New chat"
  }
}

extension UnifiedChatPersistedSession {
  func restoredWidgetSnapshotsByMessageId() -> [String: McpWidgetSnapshot] {
    var result: [String: McpWidgetSnapshot] = [:]
    var topLevelSnapshotIndex = 0

    for (index, json) in messagesJson.enumerated() {
      guard let envelope = UnifiedChatPersistedMessageKt.decodeUnifiedChatPersistedMessageEnvelope(jsonValue: json) else {
        continue
      }

      let messageId = "r\(index)"
      if let snapshot = envelope.snapshot {
        result[messageId] = snapshot
        continue
      }

      if envelope.type == .mcpWidgetCard, topLevelSnapshotIndex < widgetSnapshots.count {
        result[messageId] = widgetSnapshots[topLevelSnapshotIndex]
        topLevelSnapshotIndex += 1
      }
    }

    return result
  }
}

extension UnifiedChatSessionState {
  func latestWidgetAnchorMessageId(widgetSnapshotsByMessageId: [String: McpWidgetSnapshot]) -> String? {
    messages.reversed().first { widgetSnapshotsByMessageId[$0.id] != nil }?.id
  }
}

private extension UnifiedChatPersistedMessageEnvelope {
  func toUnifiedMessage(id: String) -> UnifiedChatMessage? {
    let textValue = (content ?? title ?? summary ?? "").removingRuntimeDisplayPrefix()
    switch type {
    case .text:
      return UnifiedChatMessage(id: id, role: side.unifiedRole, text: textValue)
    case .thinking:
      return UnifiedChatMessage(id: id, role: .assistant, text: textValue)
    case .info, .warning, .error:
      return UnifiedChatMessage(id: id, role: .system, text: textValue)
    case .mcpWidgetCard:
      return UnifiedChatMessage(id: id, role: side.unifiedRole, text: textValue)
    default:
      return nil
    }
  }
}

private extension UnifiedChatMessageRole {
  var persistedType: UnifiedChatPersistedMessageType {
    switch self {
    case .user, .assistant:
      return .text
    case .system:
      return .info
    default:
      return .info
    }
  }

  var persistedSide: String {
    switch self {
    case .user:
      return "USER"
    case .assistant:
      return "AGENT"
    case .system:
      return "SYSTEM"
    default:
      return "SYSTEM"
    }
  }
}

private extension Optional where Wrapped == String {
  var unifiedRole: UnifiedChatMessageRole {
    switch self ?? "SYSTEM" {
    case "USER":
      return .user
    case "AGENT":
      return .assistant
    default:
      return .system
    }
  }
}

private extension String {
  func removingRuntimeDisplayPrefix() -> String {
    let knownPrefixes = ["[litert-lm-ios]", "[stub]", "[litert-lm]", "[LiteRT-LM iOS]"]
    let trimmedLeading = drop(while: { $0.isWhitespace || $0.isNewline })
    for prefix in knownPrefixes {
      if trimmedLeading.hasPrefix(prefix) {
        return trimmedLeading
          .dropFirst(prefix.count)
          .drop(while: { $0.isWhitespace || $0.isNewline })
          .description
      }
    }
    return self
  }

  func prefixString(_ count: Int) -> String {
    String(prefix(count))
  }
}
