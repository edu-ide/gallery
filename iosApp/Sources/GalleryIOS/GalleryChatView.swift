import SwiftUI
import GallerySharedCore

struct GalleryChatView: View {
  let model: GalleryModel
  let connectors: [GalleryConnector]
  let entryHint: UnifiedChatEntryHint

  private let sessionId: String
  private let sessionStore = GallerySessionStore()
  @State private var sessionState: UnifiedChatSessionState

  init(model: GalleryModel, connectors: [GalleryConnector], entryHint: UnifiedChatEntryHint) {
    self.model = model
    self.connectors = connectors
    self.entryHint = entryHint
    let computedSessionId = UnifiedChatPersistedSessionKt.buildUnifiedChatSessionId(
      taskId: model.taskId,
      modelName: model.name,
      entryHint: entryHint
    )
    self.sessionId = computedSessionId
    let initialState = UnifiedChatSessionStateKt.createUnifiedChatSessionState(
      modelName: model.name,
      modelDisplayName: model.shortName,
      taskId: model.taskId,
      modelCapabilities: model.capabilities,
      entryHint: entryHint,
      visibleConnectorIds: connectors.map(\.id),
      initialDraft: model.recommendedPrompt
    )
    let store = GallerySessionStore()
    if let persisted = store.load(id: computedSessionId) {
      _sessionState = State(initialValue: initialState.restoring(persisted))
    } else {
      _sessionState = State(initialValue: initialState)
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      statusHeader
      Divider()
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(sessionState.messages, id: \.id) { message in
              MessageBubble(message: message)
                .id(message.id)
            }
            if let snapshot = sessionState.widgetHostState.activeSnapshot {
              WidgetPreview(snapshot: snapshot, fullscreen: sessionState.widgetHostState.displayMode == .fullscreen)
            }
          }
          .padding()
        }
        .onChange(of: sessionState.messages.count) { _, _ in
          if let last = sessionState.messages.last {
            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
          }
        }
      }
      Divider()
      connectorBar
      composer
    }
    .navigationTitle(model.shortName)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Menu {
          Button("Show route hint") { sessionState = sessionState.appendSystemMessage(text: sessionState.route()) }
          Button("Show widget card") { activateDemoWidget(fullscreen: false) }
          Button("Show fullscreen widget") { activateDemoWidget(fullscreen: true) }
          if sessionState.widgetHostState.activeSnapshot != nil {
            Button("Close widget", role: .destructive) { sessionState = sessionState.closeWidget() }
          }
        } label: {
          Image(systemName: "ellipsis.circle")
        }
      }
    }
    .onChange(of: sessionState.messages.count) { _, _ in persistSession() }
    .onChange(of: sessionState.connectorBarState.activeConnectorIds.count) { _, _ in persistSession() }
    .onDisappear { persistSession() }
  }

  private var statusHeader: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(sessionState.modelName)
          .font(.subheadline.weight(.semibold))
        Spacer()
        Text(sessionState.connectorLauncherLabel())
          .font(.caption.weight(.semibold))
          .padding(.horizontal, 10)
          .padding(.vertical, 6)
          .background(Color.accentColor.opacity(0.12), in: Capsule())
      }
      HStack(spacing: 8) {
        CapabilityPill(title: "text", enabled: true, symbol: "text.bubble")
        CapabilityPill(title: "image", enabled: supports(.image), symbol: "photo")
        CapabilityPill(title: "audio", enabled: supports(.audio), symbol: "waveform")
        CapabilityPill(title: "skills", enabled: sessionState.currentEntryHint().activateSkills, symbol: "wand.and.stars")
      }
      Text(sessionState.route())
        .font(.caption2.monospaced())
        .foregroundStyle(.secondary)
        .lineLimit(2)
    }
    .padding(.horizontal)
    .padding(.vertical, 12)
    .background(Color(.systemBackground))
  }

  private var connectorBar: some View {
    let policy = sessionState.chromePolicy()

    return VStack(alignment: .leading, spacing: 8) {
      if policy.showConnectorLauncherInComposer {
        HStack {
          Text(sessionState.connectorLauncherLabel())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
          Spacer()
          if policy.showStandaloneAudioRecordButtonInComposer {
            Label("audio", systemImage: "mic")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 8) {
            ForEach(connectors) { connector in
              Button {
                sessionState = sessionState.toggleConnector(connectorId: connector.id)
                let status = isActive(connector.id) ? "enabled" : "disabled"
                sessionState = sessionState.appendSystemMessage(text: "\(connector.title) connector \(status).")
              } label: {
                Label(connector.title, systemImage: connector.symbol)
                  .font(.caption.weight(.semibold))
                  .padding(.horizontal, 10)
                  .padding(.vertical, 8)
                  .background(isActive(connector.id) ? Color.accentColor.opacity(0.16) : Color(.secondarySystemBackground), in: Capsule())
                  .overlay(Capsule().stroke(isActive(connector.id) ? Color.accentColor : Color.clear))
              }
              .buttonStyle(.plain)
            }
          }
        }
      }
    }
    .padding(.horizontal)
    .padding(.vertical, 10)
    .background(Color(.systemBackground))
  }

  private var composer: some View {
    VStack(spacing: 10) {
      HStack(alignment: .bottom, spacing: 10) {
        if supports(.image) {
          Image(systemName: "photo")
            .font(.title3)
            .foregroundStyle(.secondary)
            .frame(width: 34, height: 34)
        }
        TextField(
          "Ask anything",
          text: Binding(
            get: { sessionState.draft },
            set: { sessionState = sessionState.updateDraft(draft: $0) }
          ),
          axis: .vertical
        )
        .lineLimit(1...4)
        .textFieldStyle(.roundedBorder)
        Button {
          sessionState = sessionState.submitDraft(responsePrefix: "Stub response")
        } label: {
          Image(systemName: "arrow.up.circle.fill")
            .font(.title2)
        }
        .disabled(sessionState.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding()
    .background(.bar)
  }

  private func persistSession() {
    if let persisted = sessionState.persistedSession(id: sessionId) {
      sessionStore.save(persisted)
    } else {
      sessionStore.delete(id: sessionId)
    }
  }

  private func supports(_ capability: UnifiedChatCapability) -> Bool {
    sessionState.modelCapabilities.supportsUnifiedChatCapability(requiredCapability: capability)
  }

  private func isActive(_ connectorId: String) -> Bool {
    sessionState.connectorBarState.activeConnectorIds.contains(connectorId)
  }

  private func activateDemoWidget(fullscreen: Bool) {
    let snapshot = McpWidgetSnapshot(
      connectorId: sessionState.connectorBarState.activeConnectorIds.first ?? "github",
      title: fullscreen ? "Fullscreen MCP Widget" : "Inline MCP Widget",
      summary: "This is a SwiftUI placeholder for future MCP Apps rendering.",
      widgetStateJson: "{\"route\":\"\(sessionState.route())\"}"
    )
    sessionState = sessionState.activateWidget(snapshot: snapshot, fullscreen: fullscreen)
  }
}

private struct CapabilityPill: View {
  let title: String
  let enabled: Bool
  let symbol: String

  var body: some View {
    Label(title, systemImage: symbol)
      .font(.caption2.weight(.semibold))
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .foregroundStyle(enabled ? Color.accentColor : Color.secondary)
      .background(enabled ? Color.accentColor.opacity(0.12) : Color(.secondarySystemBackground), in: Capsule())
  }
}

private struct MessageBubble: View {
  let message: UnifiedChatMessage

  var body: some View {
    HStack {
      if message.role == .user { Spacer(minLength: 40) }
      Text(message.text)
        .font(.body)
        .padding(12)
        .background(message.role == .user ? Color.accentColor.opacity(0.18) : Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
      if message.role != .user { Spacer(minLength: 40) }
    }
  }
}

private struct WidgetPreview: View {
  let snapshot: McpWidgetSnapshot
  let fullscreen: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(snapshot.title, systemImage: fullscreen ? "arrow.up.left.and.arrow.down.right" : "macwindow")
        .font(.headline)
      Text(snapshot.summary)
        .font(.subheadline)
        .foregroundStyle(.secondary)
      Text(snapshot.widgetStateJson)
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .lineLimit(2)
    }
    .padding()
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.orange.opacity(0.13), in: RoundedRectangle(cornerRadius: 18))
    .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.orange.opacity(0.4)))
  }
}

#Preview {
  NavigationStack {
    GalleryChatView(
      model: GalleryModel.samples[0],
      connectors: GalleryConnector.samples,
      entryHint: UnifiedChatEntryHint(activateImage: true, activateAudio: false, activateSkills: false, activateMcpConnectorIds: ["github"])
    )
  }
}
