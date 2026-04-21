import SwiftUI
import GallerySharedCore

struct GalleryChatView: View {
  let model: GalleryModel
  let connectors: [GalleryConnector]
  let entryHint: UnifiedChatEntryHint

  @State private var connectorState: ConnectorBarState
  @State private var draft: String
  @State private var messages: [ChatMessage]
  @State private var widgetState = McpWidgetHostState(activeSnapshot: nil, displayMode: .inline_)

  init(model: GalleryModel, connectors: [GalleryConnector], entryHint: UnifiedChatEntryHint) {
    self.model = model
    self.connectors = connectors
    self.entryHint = entryHint
    let seededState = ConnectorBarState(
      visibleConnectorIds: connectors.map(\.id),
      activeConnectorIds: Set(entryHint.activateMcpConnectorIds)
    )
    _connectorState = State(initialValue: seededState)
    _draft = State(initialValue: model.recommendedPrompt)
    _messages = State(initialValue: [
      ChatMessage(role: .assistant, text: "Loaded \(model.shortName). This is the native iOS chat shell; model inference will be wired in a later slice."),
      ChatMessage(role: .assistant, text: "KMP shared core controls connector state, capability labels, and route hints on this screen."),
    ])
  }

  var body: some View {
    VStack(spacing: 0) {
      statusHeader
      Divider()
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(messages) { message in
              MessageBubble(message: message)
                .id(message.id)
            }
            if let snapshot = widgetState.activeSnapshot {
              WidgetPreview(snapshot: snapshot, fullscreen: widgetState.displayMode == .fullscreen)
            }
          }
          .padding()
        }
        .onChange(of: messages.count) { _, _ in
          if let last = messages.last {
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
          Button("Show route hint") { appendSystem(routeSummary) }
          Button("Show widget card") { activateDemoWidget(fullscreen: false) }
          Button("Show fullscreen widget") { activateDemoWidget(fullscreen: true) }
          if widgetState.activeSnapshot != nil {
            Button("Close widget", role: .destructive) { widgetState = widgetState.close() }
          }
        } label: {
          Image(systemName: "ellipsis.circle")
        }
      }
    }
  }

  private var statusHeader: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(model.name)
          .font(.subheadline.weight(.semibold))
        Spacer()
        Text(connectorLauncherLabel)
          .font(.caption.weight(.semibold))
          .padding(.horizontal, 10)
          .padding(.vertical, 6)
          .background(Color.accentColor.opacity(0.12), in: Capsule())
      }
      HStack(spacing: 8) {
        CapabilityPill(title: "text", enabled: true, symbol: "text.bubble")
        CapabilityPill(title: "image", enabled: supports(.image), symbol: "photo")
        CapabilityPill(title: "audio", enabled: supports(.audio), symbol: "waveform")
        CapabilityPill(title: "skills", enabled: entryHint.activateSkills, symbol: "wand.and.stars")
      }
      Text(routeSummary)
        .font(.caption2.monospaced())
        .foregroundStyle(.secondary)
        .lineLimit(2)
    }
    .padding(.horizontal)
    .padding(.vertical, 12)
    .background(Color(.systemBackground))
  }

  private var connectorBar: some View {
    let policy = UnifiedChatChromePolicyKt.resolveUnifiedChatChromePolicy(
      hasVisibleConnectors: !connectors.isEmpty,
      supportsAudioInput: supports(.audio)
    )

    return VStack(alignment: .leading, spacing: 8) {
      if policy.showConnectorLauncherInComposer {
        HStack {
          Text(connectorLauncherLabel)
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
                connectorState = connectorState.toggle(connectorId: connector.id)
                appendSystem("\(connector.title) connector \(isActive(connector.id) ? "enabled" : "disabled").")
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
        TextField("Ask anything", text: $draft, axis: .vertical)
          .lineLimit(1...4)
          .textFieldStyle(.roundedBorder)
        Button {
          sendDraft()
        } label: {
          Image(systemName: "arrow.up.circle.fill")
            .font(.title2)
        }
        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding()
    .background(.bar)
  }

  private var connectorLauncherLabel: String {
    UnifiedChatChromePolicyKt.buildConnectorLauncherLabel(
      activeConnectorCount: Int32(connectorState.activeConnectorIds.count)
    )
  }

  private var routeSummary: String {
    UnifiedChatEntryHintKt.buildUnifiedChatRoute(
      taskId: model.taskId,
      modelName: model.name,
      entryHint: currentEntryHint
    )
  }

  private var currentEntryHint: UnifiedChatEntryHint {
    UnifiedChatEntryHint(
      activateImage: entryHint.activateImage,
      activateAudio: entryHint.activateAudio,
      activateSkills: entryHint.activateSkills,
      activateMcpConnectorIds: Array(connectorState.activeConnectorIds)
    )
  }

  private func supports(_ capability: UnifiedChatCapability) -> Bool {
    model.capabilities.supportsUnifiedChatCapability(requiredCapability: capability)
  }

  private func isActive(_ connectorId: String) -> Bool {
    connectorState.activeConnectorIds.contains(connectorId)
  }

  private func sendDraft() {
    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    messages.append(ChatMessage(role: .user, text: text))
    draft = ""
    let connectorList = connectorState.activeConnectorIds.sorted().joined(separator: ", ")
    messages.append(
      ChatMessage(
        role: .assistant,
        text: "Stub response from \(model.shortName). Active connectors: \(connectorList.isEmpty ? "none" : connectorList)."
      )
    )
  }

  private func appendSystem(_ text: String) {
    messages.append(ChatMessage(role: .assistant, text: text))
  }

  private func activateDemoWidget(fullscreen: Bool) {
    let snapshot = McpWidgetSnapshot(
      connectorId: connectorState.activeConnectorIds.first ?? "github",
      title: fullscreen ? "Fullscreen MCP Widget" : "Inline MCP Widget",
      summary: "This is a SwiftUI placeholder for future MCP Apps rendering.",
      widgetStateJson: "{\"route\":\"\(routeSummary)\"}"
    )
    widgetState = widgetState.activate(snapshot: snapshot, fullscreen: fullscreen)
  }
}

struct ChatMessage: Identifiable, Equatable {
  enum Role { case user, assistant }
  let id = UUID()
  let role: Role
  let text: String
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
  let message: ChatMessage

  var body: some View {
    HStack {
      if message.role == .user { Spacer(minLength: 40) }
      Text(message.text)
        .font(.body)
        .padding(12)
        .background(message.role == .user ? Color.accentColor.opacity(0.18) : Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
      if message.role == .assistant { Spacer(minLength: 40) }
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
