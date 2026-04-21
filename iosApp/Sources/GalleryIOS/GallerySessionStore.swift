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
  private let directory: URL

  init(fileManager: FileManager = .default) {
    let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
      ?? fileManager.temporaryDirectory
    directory = appSupport.appendingPathComponent("GalleryIOS/UnifiedChatSessions", isDirectory: true)
    try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
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
      .compactMap { url -> GallerySessionSummary? in
        guard let session = load(url: url),
              let key = UnifiedChatPersistedSessionKt.parseUnifiedChatSessionId(id: session.id) else {
          return nil
        }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        return GallerySessionSummary(
          id: session.id,
          title: session.title,
          modelName: key.modelName,
          taskId: key.taskId,
          updatedAt: modified,
          messageCount: session.messagesJson.count,
          activeConnectorIds: session.activeConnectorIds,
          entryHint: key.entryHint
        )
      }
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

  private func load(url: URL) -> UnifiedChatPersistedSession? {
    guard let data = try? Data(contentsOf: url),
          let json = String(data: data, encoding: .utf8) else {
      return nil
    }
    return UnifiedChatPersistedSessionKt.decodeUnifiedChatPersistedSession(jsonValue: json)
  }

  private func fileURL(id: String) -> URL {
    directory.appendingPathComponent(UnifiedChatPersistedSessionKt.unifiedChatSessionFileName(id: id))
  }
}

extension UnifiedChatSessionState {
  func persistedSession(id: String, title: String? = nil) -> UnifiedChatPersistedSession? {
    let encodedMessages = messages.map { message in
      let envelope = UnifiedChatPersistedMessageEnvelope(
        type: message.role.persistedType,
        side: message.role.persistedSide,
        content: message.text,
        isMarkdown: true,
        latencyMs: nil,
        accelerator: nil,
        hideSenderLabel: nil,
        inProgress: nil,
        connectorId: nil,
        title: nil,
        summary: nil,
        snapshot: nil,
        disableBubbleShape: nil
      )
      return UnifiedChatPersistedMessageKt.encodeUnifiedChatPersistedMessageEnvelope(envelope: envelope)
    }
    let snapshots = widgetHostState.activeSnapshot.map { [$0] } ?? []

    if encodedMessages.isEmpty && connectorBarState.activeConnectorIds.isEmpty && snapshots.isEmpty {
      return nil
    }

    return UnifiedChatPersistedSession(
      id: id,
      title: title ?? derivedTitle,
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
    let nextIndex = Int32(restoredMessages.count)
    let restoredWidgetState: McpWidgetHostState = {
      if let snapshot = persisted.widgetSnapshots.first {
        return widgetHostState.activate(snapshot: snapshot, fullscreen: false)
      }
      return widgetHostState.close()
    }()

    return doCopy(
      modelName: modelName,
      modelDisplayName: modelDisplayName,
      taskId: taskId,
      modelCapabilities: modelCapabilities,
      entryHint: entryHint,
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
