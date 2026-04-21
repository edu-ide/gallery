import SwiftUI
import GallerySharedCore
import PhotosUI
import UniformTypeIdentifiers

struct GalleryChatView: View {
  let model: GalleryModel
  let agentSkills: [GalleryAgentSkill]
  let connectors: [GalleryConnector]
  let entryHint: UnifiedChatEntryHint

  private let sessionId: String
  private let sessionStore = GallerySessionStore()
  private let runtime: GalleryInferenceRuntime = GalleryRuntimeFactory.defaultRuntime()
  @State private var sessionState: UnifiedChatSessionState
  @State private var isGenerating = false
  @State private var streamingAssistantText = ""
  @State private var attachments: [ChatInputAttachment] = []
  @State private var selectedPhotoItem: PhotosPickerItem?
  @State private var showCamera = false
  @State private var showAudioRecorder = false
  @State private var showAudioFilePicker = false
  @State private var showAttachmentError = false
  @State private var attachmentErrorMessage = ""
  @FocusState private var isComposerFocused: Bool

  init(
    model: GalleryModel,
    agentSkills: [GalleryAgentSkill],
    connectors: [GalleryConnector],
    entryHint: UnifiedChatEntryHint,
    sessionIdOverride: String? = nil,
    restoreExistingSession: Bool = true
  ) {
    self.model = model
    self.agentSkills = agentSkills
    self.connectors = connectors
    self.entryHint = entryHint
    let computedSessionId = sessionIdOverride ?? GallerySessionStore.makeSessionId(
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
      visibleAgentSkillIds: agentSkills.map(\.id),
      visibleConnectorIds: connectors.map(\.id),
      initialDraft: ""
    )
    let store = GallerySessionStore()
    if restoreExistingSession, let persisted = store.load(id: computedSessionId) {
      _sessionState = State(initialValue: initialState.restoring(persisted))
    } else {
      _sessionState = State(initialValue: initialState)
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      ScrollViewReader { proxy in
        ScrollView {
          transcriptContent
          .padding()
        }
        .onChange(of: sessionState.messages.count) { _, _ in
          scrollToLastMessage(proxy)
        }
        .onChange(of: streamingAssistantText) { _, _ in
          scrollToStreamingMessage(proxy)
        }
      }
      composer
    }
    .background(Color(.systemBackground))
    .navigationTitle("Local AI")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        RuntimeStatusDot(isReady: runtime.isAvailable)
      }
      ToolbarItem(placement: .topBarTrailing) {
        Menu {
          if !agentSkills.isEmpty {
            Section("Skills") {
              ForEach(agentSkills) { skill in
                Toggle(isOn: Binding(
                  get: { isActiveSkill(skill.id) },
                  set: { setAgentSkill(skill.id, active: $0) }
                )) {
                  Label(skill.title, systemImage: skill.symbol)
                }
              }
            }
          }
          if !connectors.isEmpty {
            Section("Connectors") {
              ForEach(connectors) { connector in
                Toggle(isOn: Binding(
                  get: { isActive(connector.id) },
                  set: { setConnector(connector.id, active: $0) }
                )) {
                  Label(connectorMenuTitle(connector), systemImage: connector.symbol)
                }
              }
            }
          }
        } label: {
          Image(systemName: "slider.horizontal.3")
        }
      }
    }
    .onChange(of: sessionState.messages.count) { _, _ in persistSession() }
    .onChange(of: sessionState.agentSkillState.activeSkillIds.count) { _, _ in persistSession() }
    .onChange(of: sessionState.connectorBarState.activeConnectorIds.count) { _, _ in persistSession() }
    .onDisappear { persistSession() }
    .onChange(of: selectedPhotoItem) { _, item in
      handleSelectedPhoto(item)
    }
    .sheet(isPresented: $showCamera) {
      CameraCaptureView(
        onImage: { image in
          addCameraImage(image)
          showCamera = false
        },
        onCancel: { showCamera = false }
      )
    }
    .sheet(isPresented: $showAudioRecorder) {
      AudioRecorderSheet(
        onComplete: { url in
          addRecording(url)
          showAudioRecorder = false
        },
        onCancel: { showAudioRecorder = false }
      )
    }
    .fileImporter(
      isPresented: $showAudioFilePicker,
      allowedContentTypes: [.wav, .audio],
      allowsMultipleSelection: false,
      onCompletion: handlePickedAudioFile
    )
    .alert("Attachment failed", isPresented: $showAttachmentError) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(attachmentErrorMessage)
    }
  }

  @ViewBuilder
  private var transcriptContent: some View {
    LazyVStack(alignment: .leading, spacing: 12) {
      if visibleMessages.isEmpty && !isGenerating {
        emptyState.padding(.top, 72)
      } else {
        ForEach(visibleMessages, id: \.id) { message in
          MessageBubble(message: message)
            .id(message.id)
        }
        if isGenerating {
          StreamingBubble(text: streamingAssistantText)
            .id("streaming-assistant")
        }
      }
      widgetCard
    }
  }

  @ViewBuilder
  private var widgetCard: some View {
    if let snapshot = sessionState.widgetHostState.activeSnapshot {
      WidgetPreview(
        snapshot: snapshot,
        fullscreen: sessionState.widgetHostState.displayMode == .fullscreen
      )
    }
  }

  private var visibleMessages: [UnifiedChatMessage] {
    sessionState.messages.filter { message in
      if message.role == .system { return false }
      if message.role == .assistant && message.text.hasPrefix("Loaded ") { return false }
      return !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }

  private func scrollToLastMessage(_ proxy: ScrollViewProxy) {
    guard let lastId = sessionState.messages.last?.id else { return }
    proxy.scrollTo(lastId, anchor: UnitPoint.bottom)
  }

  private func scrollToStreamingMessage(_ proxy: ScrollViewProxy) {
    proxy.scrollTo("streaming-assistant", anchor: UnitPoint.bottom)
  }

  private var emptyState: some View {
    VStack(spacing: 18) {
      Image(systemName: "sparkles")
        .font(.system(size: 44, weight: .semibold))
        .foregroundStyle(Color.accentColor)
        .frame(width: 80, height: 80)
        .background(Color.accentColor.opacity(0.12), in: Circle())
      VStack(spacing: 6) {
        Text("무엇을 도와드릴까요?")
          .font(.title2.bold())
        Text("\(model.shortName) runs locally on this iPhone.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      VStack(spacing: 8) {
        SuggestionButton(title: "오늘 할 일 정리해줘") {
          sessionState = sessionState.updateDraft(draft: "오늘 할 일을 우선순위대로 정리해줘.")
          isComposerFocused = true
        }
        SuggestionButton(title: "짧게 한국어로 인사해줘") {
          sessionState = sessionState.updateDraft(draft: "짧게 한국어로 인사해줘.")
          isComposerFocused = true
        }
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.horizontal, 24)
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
      Text("Runtime: \(runtime.displayName)")
        .font(.caption2.weight(.semibold))
        .foregroundStyle(runtime.isAvailable ? .green : .orange)
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
      if policy.showConnectorLauncherInComposer || policy.showInlineConnectorRowAboveComposer {
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

  private var attachmentStrip: some View {
    Group {
      if attachments.isEmpty {
        EmptyView()
      } else {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 8) {
            ForEach(attachments) { attachment in
              AttachmentChip(attachment: attachment) {
                attachments.removeAll { $0.id == attachment.id }
              }
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
  }

  private var addInputMenu: some View {
    Menu {
      if supports(.image) {
        PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
          Label("Photo Library", systemImage: "photo.on.rectangle")
        }
        Button {
          showCamera = true
        } label: {
          Label("Camera", systemImage: "camera")
        }
      }
      if supports(.audio) {
        Button {
          showAudioFilePicker = true
        } label: {
          Label("Pick WAV File", systemImage: "doc.badge.plus")
        }
        Button {
          showAudioRecorder = true
        } label: {
          Label("Record Audio", systemImage: "mic")
        }
      }
      if !supports(.image) && !supports(.audio) {
        Text("No attachments available")
      }
    } label: {
      Image(systemName: "plus.circle.fill")
        .font(.title2)
        .foregroundStyle(Color.accentColor)
        .frame(width: 34, height: 34)
    }
    .accessibilityLabel("Add input")
  }

  private var composer: some View {
    VStack(spacing: 10) {
      attachmentStrip
      HStack(alignment: .bottom, spacing: 10) {
        addInputMenu
        TextField(
          "Ask anything",
          text: Binding(
            get: { sessionState.draft },
            set: { sessionState = sessionState.updateDraft(draft: $0) }
          ),
          axis: .vertical
        )
        .lineLimit(1...4)
        .focused($isComposerFocused)
        .textFieldStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        Button {
          sendDraftThroughRuntime()
        } label: {
          if isGenerating {
            ProgressView()
              .controlSize(.small)
          } else {
            Image(systemName: "arrow.up.circle.fill")
              .font(.title2)
          }
        }
        .buttonStyle(.plain)
        .foregroundStyle(canSend ? Color.accentColor : Color.secondary)
        .disabled(!canSend)
      }
    }
    .padding(.horizontal, 14)
    .padding(.top, 10)
    .padding(.bottom, 12)
    .background(.regularMaterial)
  }

  private var canSend: Bool {
    !isGenerating && (!sessionState.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
  }

  private func sendDraftThroughRuntime() {
    let prompt = sessionState.draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard canSend else { return }
    let attachmentsToSend = attachments
    let effectivePrompt = prompt.isEmpty ? "Please describe the attached input." : prompt

    let request = GalleryInferenceRequest(
      modelName: sessionState.modelName,
      modelDisplayName: sessionState.modelDisplayName,
      modelFileName: model.modelFileName,
      prompt: effectivePrompt,
      route: sessionState.route(),
      activeAgentSkillIds: Array(sessionState.agentSkillState.activeSkillIds).sorted(),
      activeConnectorIds: Array(sessionState.connectorBarState.activeConnectorIds).sorted(),
      supportsImage: attachmentsToSend.contains { $0.kind == .image } && supports(.image),
      supportsAudio: attachmentsToSend.contains { $0.kind == .audio } && supports(.audio),
      attachments: attachmentsToSend.map(\.inferenceAttachment)
    )

    sessionState = sessionState.appendUserMessage(text: userVisiblePrompt(prompt: effectivePrompt, attachments: attachmentsToSend))
    isGenerating = true
    streamingAssistantText = ""
    attachments = []
    isComposerFocused = false
    persistSession()

    Task {
      let result = await runtime.generate(request: request) { token in
        Task { @MainActor in
          streamingAssistantText.append(token)
        }
      }
      await MainActor.run {
        let finalText = result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          ? streamingAssistantText
          : result.text
        sessionState = sessionState.appendAssistantMessage(text: finalText)
        streamingAssistantText = ""
        isGenerating = false
        persistSession()
      }
    }
  }

  private func persistSession() {
    if let persisted = sessionState.persistedSession(id: sessionId) {
      sessionStore.save(persisted)
    } else {
      sessionStore.delete(id: sessionId)
    }
  }

  private func userVisiblePrompt(prompt: String, attachments: [ChatInputAttachment]) -> String {
    guard !attachments.isEmpty else { return prompt }
    let names = attachments.map { "\($0.symbol) \($0.displayName)" }.joined(separator: ", ")
    return "\(prompt)\n\nAttached: \(names)"
  }

  private func handleSelectedPhoto(_ item: PhotosPickerItem?) {
    guard let item else { return }
    Task {
      do {
        let attachment = try await ChatInputAttachmentStore.savePickedPhoto(item)
        await MainActor.run { attachments.append(attachment) }
      } catch {
        await MainActor.run { showAttachmentError(error.localizedDescription) }
      }
      await MainActor.run { selectedPhotoItem = nil }
    }
  }

  private func handlePickedAudioFile(_ result: Result<[URL], Error>) {
    do {
      guard let url = try result.get().first else { return }
      attachments.append(try ChatInputAttachmentStore.copyAudioFile(from: url))
    } catch {
      showAttachmentError(error.localizedDescription)
    }
  }

  private func addCameraImage(_ image: UIImage) {
    do {
      attachments.append(try ChatInputAttachmentStore.saveCameraImage(image))
    } catch {
      showAttachmentError(error.localizedDescription)
    }
  }

  private func addRecording(_ url: URL) {
    do {
      attachments.append(try ChatInputAttachmentStore.copyAudioFile(from: url))
    } catch {
      showAttachmentError(error.localizedDescription)
    }
  }

  private func showAttachmentError(_ message: String) {
    attachmentErrorMessage = message
    showAttachmentError = true
  }

  private func supports(_ capability: UnifiedChatCapability) -> Bool {
    sessionState.modelCapabilities.supportsUnifiedChatCapability(requiredCapability: capability)
  }

  private func isActive(_ connectorId: String) -> Bool {
    sessionState.connectorBarState.activeConnectorIds.contains(connectorId)
  }

  private func isActiveSkill(_ skillId: String) -> Bool {
    sessionState.agentSkillState.activeSkillIds.contains(skillId)
  }

  private func setAgentSkill(_ skillId: String, active: Bool) {
    let currentlyActive = isActiveSkill(skillId)
    guard currentlyActive != active else { return }
    sessionState = sessionState.withAgentSkill(skillId: skillId, active: active)
    persistSession()
  }

  private func setConnector(_ connectorId: String, active: Bool) {
    let currentlyActive = isActive(connectorId)
    guard currentlyActive != active else { return }
    sessionState = sessionState.toggleConnector(connectorId: connectorId)
    persistSession()
  }

  private func connectorMenuTitle(_ connector: GalleryConnector) -> String {
    connector.id == GalleryConnector.fortuneMcpId ? "Fortune" : connector.title
  }

  private func activateDemoWidget(fullscreen: Bool) {
    let snapshot = McpWidgetSnapshot(
      connectorId: sessionState.connectorBarState.activeConnectorIds.first ?? GalleryConnector.fortuneMcpId,
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
      VStack(alignment: .leading, spacing: 4) {
        if message.role == .assistant {
          AssistantMarkdownText(text: message.text)
            .font(.body)
            .textSelection(.enabled)
        } else {
          Text(message.text)
            .font(.body)
            .textSelection(.enabled)
        }
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 11)
      .foregroundStyle(message.role == .user ? .white : .primary)
      .background(
        message.role == .user ? Color.accentColor : Color(.secondarySystemGroupedBackground),
        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
      )
      if message.role != .user { Spacer(minLength: 40) }
    }
  }
}

private struct StreamingBubble: View {
  let text: String

  var body: some View {
    HStack(alignment: .bottom, spacing: 8) {
      VStack(alignment: .leading, spacing: 8) {
        if text.isEmpty {
          HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Thinking…")
              .font(.body)
              .foregroundStyle(.secondary)
          }
        } else {
          AssistantMarkdownText(text: text)
            .font(.body)
            .textSelection(.enabled)
        }
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 11)
      .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
      Spacer(minLength: 40)
    }
  }
}

private struct AssistantMarkdownText: View {
  let text: String

  var body: some View {
    if let attributed = try? AttributedString(
      markdown: text,
      options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
    ) {
      Text(attributed)
    } else {
      Text(text)
    }
  }
}

private struct AttachmentChip: View {
  let attachment: ChatInputAttachment
  let onRemove: () -> Void

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: attachment.symbol)
      Text(attachment.displayName)
        .lineLimit(1)
      Button(action: onRemove) {
        Image(systemName: "xmark.circle.fill")
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
    }
    .font(.caption.weight(.semibold))
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(Color(.secondarySystemBackground), in: Capsule())
  }
}

private struct RuntimeStatusDot: View {
  let isReady: Bool

  var body: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(isReady ? Color.green : Color.orange)
        .frame(width: 8, height: 8)
      Text(isReady ? "On-device" : "Setup")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
    }
  }
}

private struct SuggestionButton: View {
  let title: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(.subheadline.weight(.semibold))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
    .buttonStyle(.plain)
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
      agentSkills: GalleryAgentSkill.samples,
      connectors: GalleryConnector.samples,
      entryHint: UnifiedChatEntryHint(
        activateImage: true,
        activateAudio: false,
        activateSkills: true,
        activateAgentSkillIds: GalleryAgentSkill.defaultSelectedIds,
        activateMcpConnectorIds: GalleryConnector.defaultSelectedIds
      )
    )
  }
}
