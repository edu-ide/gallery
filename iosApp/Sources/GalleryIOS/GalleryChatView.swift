import SwiftUI
import GallerySharedCore
import MarkdownUI
import AVFoundation
import PhotosUI
import Speech
import UniformTypeIdentifiers

private enum AudioRecorderMode {
  case attachment
  case voiceTurn
}

struct GalleryChatView: View {
  private static let transcriptScrollCoordinateSpace = "gallery-chat-transcript-scroll"
  // Gemma/local LLM responses are text. Voice playback here would be iOS TTS,
  // which can accidentally read raw MCP tool payloads aloud. Keep assistant
  // audio output disabled unless a dedicated voice-generation model is wired in.
  private static let assistantVoiceOutputEnabled = false

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
  @State private var audioRecorderMode: AudioRecorderMode = .attachment
  @State private var showAudioFilePicker = false
  @State private var toolApprovalConnector: GalleryConnector?
  @State private var pendingToolApproval: UgotMCPToolApprovalRequest?
  @State private var mcpPromptItems: [UgotMCPPromptDescriptor] = []
  @State private var isLoadingMCPPrompts = false
  @State private var showAttachmentError = false
  @State private var attachmentErrorMessage = ""
  @State private var activeWidgetAnchorMessageId: String?
  @State private var pendingTurnTopAnchorMessageId: String?
  @State private var widgetSnapshotsByMessageId: [String: McpWidgetSnapshot]
  @State private var activeWidgetModelContext: String?
  @State private var activeWidgetRenderKey = ""
  @State private var composerDraftSeed = ""
  @State private var composerFocusToken = 0
  @State private var agentWorkspaceStatus: AgentWorkspaceStatus
  @State private var agentActivityNotice: AgentActivityNotice?
  @State private var currentAgentTurn: UgotAgentTurnState?
  @State private var transcriptViewportHeight: CGFloat = 0
  @State private var streamingBottomY: CGFloat = 0
  @State private var streamingBottomFollowEnabled = false
  @State private var lastStreamingAutoScrollTime: TimeInterval = 0
  @State private var suppressNextConversationScroll = false
  @State private var pendingTurnTopScrollTask: Task<Void, Never>?
  @State private var pendingStreamingAutoScrollTask: Task<Void, Never>?
  @State private var pendingPersistTask: Task<Void, Never>?
  @StateObject private var voiceOutput = GalleryVoiceOutput()
  @StateObject private var liveVoiceInput = GalleryLiveSpeechInput()
  @State private var liveVoiceSessionActive = false
  @State private var liveVoiceAutoStopTask: Task<Void, Never>?
  @State private var liveVoiceRestartTask: Task<Void, Never>?
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
    let persistedSession = restoreExistingSession ? store.load(id: computedSessionId) : nil
    let restoredState: UnifiedChatSessionState
    if let persistedSession {
      restoredState = initialState.restoring(persistedSession)
    } else {
      restoredState = initialState
    }
    _sessionState = State(initialValue: restoredState)
    _composerDraftSeed = State(initialValue: restoredState.draft)
    let restoredWidgetSnapshots = persistedSession?.restoredWidgetSnapshotsByMessageId() ?? [:]
    _widgetSnapshotsByMessageId = State(initialValue: restoredWidgetSnapshots)
    _activeWidgetAnchorMessageId = State(initialValue: restoredState.latestWidgetAnchorMessageId(widgetSnapshotsByMessageId: restoredWidgetSnapshots))
    _agentWorkspaceStatus = State(initialValue: UgotAgentVFS.shared.workspaceStatus(sessionId: computedSessionId))
  }

  private var supportsLiveVoiceInput: Bool {
    supports(.text)
  }

  var body: some View {
    VStack(spacing: 0) {
      ScrollViewReader { proxy in
        GeometryReader { geometry in
          ScrollView {
            transcriptContent
              .padding()
          }
          .coordinateSpace(name: Self.transcriptScrollCoordinateSpace)
          .onAppear {
            transcriptViewportHeight = geometry.size.height
          }
          .onChange(of: geometry.size.height) { _, height in
            transcriptViewportHeight = height
          }
          .onChange(of: sessionState.messages.count) { _, _ in
            if suppressNextConversationScroll {
              suppressNextConversationScroll = false
              return
            }
            scrollToConversationAnchor(proxy)
          }
          .onChange(of: streamingAssistantText) { _, _ in
            scheduleStreamingAutoScroll(proxy)
          }
          .onPreferenceChange(StreamingBottomYPreferenceKey.self) { bottomY in
            streamingBottomY = bottomY
            guard shouldStartStreamingBottomFollow(bottomY: bottomY) else { return }
            streamingBottomFollowEnabled = true
            scheduleStreamingAutoScroll(proxy)
          }
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
            Section("기능") {
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
            Section("연결") {
              ForEach(connectors) { connector in
                Toggle(isOn: Binding(
                  get: { isActive(connector.id) },
                  set: { setConnector(connector.id, active: $0) }
                )) {
                  Label(connectorMenuTitle(connector), systemImage: connector.symbol)
                }
              }
            }
            Section("도구 승인") {
              ForEach(connectors) { connector in
                Button {
                  toolApprovalConnector = connector
                } label: {
                  Label("\(connector.title) 도구", systemImage: "checkmark.shield")
                }
              }
            }
          }
        } label: {
          Image(systemName: "slider.horizontal.3")
        }
      }
    }
    .onChange(of: sessionState.messages.count) { _, _ in schedulePersistSession() }
    .onChange(of: sessionState.agentSkillState.activeSkillIds.count) { _, _ in schedulePersistSession() }
    .onChange(of: sessionState.connectorBarState.activeConnectorIds.count) { _, _ in schedulePersistSession() }
    .onDisappear {
      pendingTurnTopScrollTask?.cancel()
      pendingStreamingAutoScrollTask?.cancel()
      liveVoiceAutoStopTask?.cancel()
      liveVoiceRestartTask?.cancel()
      stopLiveVoiceConversation()
      schedulePersistSession(delayNanoseconds: 0)
    }
    .onAppear {
      refreshAgentWorkspaceStatus()
      reloadMCPPrompts()
      prewarmMCPTools()
    }
    .onChange(of: sessionState.connectorBarState.activeConnectorIds) { _, _ in
      reloadMCPPrompts()
      prewarmMCPTools()
    }
    .onChange(of: selectedPhotoItem) { _, item in
      handleSelectedPhoto(item)
    }
    .onChange(of: liveVoiceInput.liveTranscript) { _, transcript in
      scheduleLiveVoiceAutoStop(for: transcript)
    }
    .onChange(of: liveVoiceInput.completedTurn) { _, turn in
      guard let turn else { return }
      liveVoiceAutoStopTask?.cancel()
      sendDraftThroughRuntime(prompt: turn.text, speakResponse: true)
    }
    .onChange(of: liveVoiceInput.isFinalizingTurn) { _, isFinalizing in
      guard !isFinalizing else { return }
      scheduleLiveVoiceRestart(after: 900_000_000)
    }
    .onChange(of: voiceOutput.completedUtteranceId) { _, utteranceId in
      guard utteranceId != nil else { return }
      scheduleLiveVoiceRestart()
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
        title: audioRecorderMode == .voiceTurn ? "음성으로 대화" : "Record Audio",
        idleTitle: audioRecorderMode == .voiceTurn ? "말을 시작하세요" : "Record audio",
        recordingTitle: audioRecorderMode == .voiceTurn ? "듣고 있어요…" : "Recording…",
        stopButtonTitle: audioRecorderMode == .voiceTurn ? "멈추고 대화하기" : "Stop recording",
        onComplete: { url in
          showAudioRecorder = false
          if audioRecorderMode == .voiceTurn {
            sendVoiceRecording(url)
          } else {
            addRecording(url)
          }
        },
        onCancel: { showAudioRecorder = false }
      )
    }
    .sheet(item: $toolApprovalConnector) { connector in
      UgotMCPToolApprovalView(connector: connector)
    }
    .sheet(item: $pendingToolApproval) { approval in
      UgotMCPToolApprovalPromptView(
        approval: approval,
        onApprove: {
          approvePendingTool(approval)
        },
        onReject: {
          rejectPendingTool(approval)
        }
      )
      .presentationDetents([.medium])
      .interactiveDismissDisabled()
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
    VStack(alignment: .leading, spacing: 12) {
      if visibleMessages.isEmpty && !isGenerating {
        emptyState.padding(.top, 72)
      } else {
        ForEach(visibleMessages, id: \.id) { message in
          MessageBubble(message: message)
            .id(message.id)
            .zIndex(1)
          if let snapshot = widgetSnapshotsByMessageId[message.id] {
            widgetCard(
              snapshot: snapshot,
              renderKey: "\(message.id)|\(snapshot.renderKeySeed)",
              isLatestWidget: message.id == latestWidgetAnchorMessageId
            )
          }
        }
        if shouldRenderUnanchoredWidget, let snapshot = sessionState.widgetHostState.activeSnapshot {
          widgetCard(
            snapshot: snapshot,
            renderKey: activeWidgetRenderKey.isEmpty ? snapshot.renderKeySeed : activeWidgetRenderKey,
            isLatestWidget: true
          )
        }
        if isGenerating {
          StreamingBubble(text: streamingAssistantText)
            .id("streaming-assistant")
            .zIndex(1)
          Color.clear
            .frame(height: 1)
            .id("streaming-bottom-anchor")
            .background(
              GeometryReader { bottomGeometry in
                Color.clear.preference(
                  key: StreamingBottomYPreferenceKey.self,
                  value: bottomGeometry.frame(in: .named(Self.transcriptScrollCoordinateSpace)).maxY
                )
              }
            )
        }
        if shouldReserveTurnTopSpace {
          Color.clear
            .frame(height: turnTopReserveHeight)
            .id("turn-top-reserve")
            .allowsHitTesting(false)
        }
      }
    }
  }

  @ViewBuilder
  private func widgetCard(snapshot: McpWidgetSnapshot, renderKey: String, isLatestWidget: Bool) -> some View {
    WidgetPreview(
      snapshot: snapshot,
      renderKey: renderKey,
      fullscreen: isLatestWidget && sessionState.widgetHostState.displayMode == .fullscreen,
      onModelContextChanged: { context in
        guard isLatestWidget else { return }
        activeWidgetModelContext = context
      }
    )
    .equatable()
    .id("widget-card-\(renderKey)")
    .zIndex(0)
  }

  private var shouldRenderUnanchoredWidget: Bool {
    guard sessionState.widgetHostState.activeSnapshot != nil else { return false }
    guard let anchorId = latestWidgetAnchorMessageId else { return true }
    return !visibleMessages.contains { $0.id == anchorId }
  }

  private var latestWidgetAnchorMessageId: String? {
    if let activeWidgetAnchorMessageId {
      return activeWidgetAnchorMessageId
    }
    return visibleMessages.last { widgetSnapshotsByMessageId[$0.id] != nil }?.id
  }

  private var visibleMessages: [UnifiedChatMessage] {
    sessionState.messages.filter { message in
      if message.role == .system {
        return InlineChatEvent(message: message) != nil
      }
      if message.role == .assistant && message.text.hasPrefix("Loaded ") { return false }
      return !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }

  private var shouldReserveTurnTopSpace: Bool {
    isGenerating || pendingTurnTopAnchorMessageId != nil
  }

  private var shouldShowAgentVisibilityPanel: Bool {
    agentActivityNotice != nil ||
      compactionStatus != nil ||
      !agentWorkspaceStatus.isEmpty ||
      !activeSkillTitles.isEmpty ||
      !activeConnectorTitles.isEmpty
  }

  private var compactionStatus: ChatCompactionStatus? {
    ChatAutoCompactor.status(messages: sessionState.messages)
  }

  private var activeSkillTitles: [String] {
    agentSkills
      .filter { sessionState.agentSkillState.activeSkillIds.contains($0.id) }
      .map(\.title)
      .sorted()
  }

  private var activeConnectorTitles: [String] {
    connectors
      .filter { sessionState.connectorBarState.activeConnectorIds.contains($0.id) }
      .map(\.title)
      .sorted()
  }

  private var turnTopReserveHeight: CGFloat {
    max(320, transcriptViewportHeight - 72)
  }

  private var streamingBottomFollowThresholdY: CGFloat {
    max(0, transcriptViewportHeight - 72)
  }

  private func shouldStartStreamingBottomFollow(bottomY: CGFloat? = nil) -> Bool {
    guard isGenerating,
          pendingTurnTopAnchorMessageId == nil,
          !streamingAssistantText.isEmpty,
          transcriptViewportHeight > 0 else {
      return false
    }
    return (bottomY ?? streamingBottomY) >= streamingBottomFollowThresholdY
  }

  private func scrollToConversationAnchor(_ proxy: ScrollViewProxy) {
    if pendingTurnTopAnchorMessageId != nil {
      scheduleTurnTopAnchorScroll(proxy)
      return
    }
    guard let lastId = visibleMessages.last?.id else { return }
    proxy.scrollTo(lastId, anchor: UnitPoint.bottom)
  }

  private func scrollToStreamingMessage(_ proxy: ScrollViewProxy) {
    if pendingTurnTopAnchorMessageId != nil {
      scheduleTurnTopAnchorScroll(proxy)
      return
    }
    guard streamingBottomFollowEnabled || shouldStartStreamingBottomFollow() else {
      return
    }
    streamingBottomFollowEnabled = true
    scrollToStreamingBottom(proxy)
  }

  private func scrollToStreamingBottom(_ proxy: ScrollViewProxy) {
    proxy.scrollTo("streaming-bottom-anchor", anchor: UnitPoint.bottom)
  }

  private func scheduleTurnTopAnchorScroll(_ proxy: ScrollViewProxy) {
    guard pendingTurnTopScrollTask == nil,
          let anchorId = pendingTurnTopAnchorMessageId else { return }

    pendingTurnTopScrollTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: 60_000_000)
      guard !Task.isCancelled,
            pendingTurnTopAnchorMessageId == anchorId else {
        pendingTurnTopScrollTask = nil
        return
      }

      withAnimation(.easeOut(duration: 0.16)) {
        proxy.scrollTo(anchorId, anchor: UnitPoint.top)
      }

      try? await Task.sleep(nanoseconds: 350_000_000)
      guard !Task.isCancelled,
            pendingTurnTopAnchorMessageId == anchorId else {
        pendingTurnTopScrollTask = nil
        return
      }

      pendingTurnTopAnchorMessageId = nil
      pendingTurnTopScrollTask = nil

      if shouldStartStreamingBottomFollow() {
        streamingBottomFollowEnabled = true
        scheduleStreamingAutoScroll(proxy)
      }
    }
  }

  private func scheduleStreamingAutoScroll(_ proxy: ScrollViewProxy) {
    guard isGenerating else { return }
    let minInterval: TimeInterval = 0.22
    let now = ProcessInfo.processInfo.systemUptime

    if now - lastStreamingAutoScrollTime >= minInterval {
      pendingStreamingAutoScrollTask?.cancel()
      lastStreamingAutoScrollTime = now
      scrollToStreamingMessage(proxy)
      return
    }

    pendingStreamingAutoScrollTask?.cancel()
    let delay = max(0.04, minInterval - (now - lastStreamingAutoScrollTime))
    pendingStreamingAutoScrollTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      guard !Task.isCancelled else { return }
      lastStreamingAutoScrollTime = ProcessInfo.processInfo.systemUptime
      scrollToStreamingMessage(proxy)
    }
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
        SuggestionButton(title: "오늘의 운세 알려줘") {
          composerDraftSeed = "오늘의 운세 알려줘."
          composerFocusToken += 1
        }
        SuggestionButton(title: "최근 메일 요약") {
          composerDraftSeed = "최근 메일 요약해줘."
          composerFocusToken += 1
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
          openAttachmentAudioRecorder()
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
    ChatComposerBar(
      draftSeed: composerDraftSeed,
      focusToken: composerFocusToken,
      attachments: $attachments,
      selectedPhotoItem: $selectedPhotoItem,
      showCamera: $showCamera,
      showAudioFilePicker: $showAudioFilePicker,
      supportsImage: supports(.image),
      supportsAudio: supports(.audio),
      supportsVoiceInput: supportsLiveVoiceInput,
      isGenerating: isGenerating,
      isVoiceListening: liveVoiceInput.isListening,
      isVoiceSessionActive: liveVoiceSessionActive,
      isVoiceSpeaking: voiceOutput.isSpeaking,
      voiceLevel: liveVoiceInput.audioLevel,
      mcpPromptItems: mcpPromptItems,
      isLoadingMCPPrompts: isLoadingMCPPrompts,
      onRecordAudio: openAttachmentAudioRecorder,
      onVoiceInput: openLiveVoiceRecorder,
      onSelectMCPPrompt: applyMCPPrompt,
      onSend: { draft in
        sendDraftThroughRuntime(prompt: draft)
      }
    )
  }

  private var canSend: Bool {
    !isGenerating && !attachments.isEmpty
  }

  private func openAttachmentAudioRecorder() {
    audioRecorderMode = .attachment
    showAudioRecorder = true
  }

  private func openLiveVoiceRecorder() {
    guard supportsLiveVoiceInput else { return }
    if liveVoiceSessionActive || liveVoiceInput.isListening || voiceOutput.isSpeaking {
      stopLiveVoiceConversation()
      return
    }

    guard !isGenerating else { return }
    startLiveVoiceInput(activateSession: true)
  }

  private func startLiveVoiceInput(activateSession: Bool) {
    liveVoiceAutoStopTask?.cancel()
    liveVoiceRestartTask?.cancel()
    if activateSession {
      liveVoiceSessionActive = true
    }
    voiceOutput.stop()
    isComposerFocused = false
    Task { @MainActor in
      do {
        guard liveVoiceSessionActive else { return }
        try await liveVoiceInput.start(locale: Locale(identifier: "ko-KR"))
      } catch {
        if activateSession {
          liveVoiceSessionActive = false
        }
        showAttachmentError(error.localizedDescription)
      }
    }
  }

  private func stopLiveVoiceInput(sendPartialFallback: Bool, keepSessionActive: Bool) {
    liveVoiceAutoStopTask?.cancel()
    liveVoiceRestartTask?.cancel()
    liveVoiceSessionActive = keepSessionActive
    liveVoiceInput.stop(sendPartialFallback: sendPartialFallback)
  }

  private func stopLiveVoiceConversation() {
    liveVoiceAutoStopTask?.cancel()
    liveVoiceRestartTask?.cancel()
    liveVoiceSessionActive = false
    liveVoiceInput.cancel()
    voiceOutput.stop()
  }

  private func scheduleLiveVoiceRestart(after delayNanoseconds: UInt64 = 350_000_000) {
    liveVoiceRestartTask?.cancel()
    guard supportsLiveVoiceInput,
          liveVoiceSessionActive,
          !isGenerating,
          !voiceOutput.isSpeaking,
          !liveVoiceInput.isListening,
          !liveVoiceInput.isFinalizingTurn else { return }
    liveVoiceRestartTask = Task { @MainActor in
      if delayNanoseconds > 0 {
        try? await Task.sleep(nanoseconds: delayNanoseconds)
      }
      guard !Task.isCancelled,
            supportsLiveVoiceInput,
            liveVoiceSessionActive,
            !isGenerating,
            !voiceOutput.isSpeaking,
            !liveVoiceInput.isListening,
            !liveVoiceInput.isFinalizingTurn else { return }
      startLiveVoiceInput(activateSession: false)
    }
  }

  private func scheduleLiveVoiceAutoStop(for transcript: String) {
    let normalized = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    liveVoiceAutoStopTask?.cancel()
    guard liveVoiceInput.isListening, !normalized.isEmpty, !isGenerating else { return }
    liveVoiceAutoStopTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: 1_700_000_000)
      guard !Task.isCancelled,
            liveVoiceInput.isListening,
            liveVoiceInput.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines) == normalized else { return }
      stopLiveVoiceInput(sendPartialFallback: true, keepSessionActive: true)
    }
  }

  private func sendVoiceRecording(_ url: URL) {
    do {
      let attachment = try ChatInputAttachmentStore.copyAudioFile(from: url)
      sendDraftThroughRuntime(
        prompt: "사용자의 음성을 듣고 자연스럽게 한국어로 짧게 대답해줘. 사용자가 명시적으로 받아쓰기를 요청하지 않았다면 단순 전사만 하지 말고 대화형 답변을 해줘.",
        attachmentsOverride: [attachment],
        speakResponse: true
      )
    } catch {
      showAttachmentError(error.localizedDescription)
    }
  }

  private func beginAgentTurn(
    prompt: String,
    attachmentCount: Int,
    activeAgentSkillIds: [String],
    activeConnectorIds: [String]
  ) {
    let turn = UgotAgentTurnState.start(
      userPrompt: prompt,
      attachmentCount: attachmentCount,
      activeSkillIds: activeAgentSkillIds,
      activeConnectorIds: activeConnectorIds
    )
    currentAgentTurn = turn
    agentActivityNotice = turn.activity.map(AgentActivityNotice.init(activity:))
  }

  private func applyAgentTurnEvent(_ event: UgotAgentTurnEvent) {
    guard var turn = currentAgentTurn else { return }
    turn.apply(event)
    currentAgentTurn = turn
    agentActivityNotice = turn.activity.map(AgentActivityNotice.init(activity:))
  }

  private func completeAgentTurn(_ outcome: UgotAgentTurnOutcome) {
    applyAgentTurnEvent(.complete(outcome))
    currentAgentTurn = nil
    agentActivityNotice = nil
  }

  private func failAgentTurn(_ reason: String) {
    applyAgentTurnEvent(.fail(reason))
  }

  private func agentTurnRoute(
    for route: GalleryCapabilityRoute,
    connectorCount: Int
  ) -> UgotAgentTurnRoute {
    switch route {
    case .nativeSkill(let skillId):
      let title = agentSkills.first(where: { $0.id == skillId })?.title
      return .nativeSkill(id: skillId, title: title)
    case .mcpConnector(let connectorId):
      let title = GalleryConnector.connector(for: connectorId)?.title
      return .mcpConnector(id: connectorId, title: title)
    case .mcpConnectors:
      return .mcpConnectors(count: connectorCount)
    case .model:
      return .model
    }
  }

  private func runMCPConnectorTurn(
    prompt: String,
    turnContext: String?,
    connectorIds: Set<String>,
    connectorSearchTitle: String,
    activeAgentSkillIds: [String],
    route: String,
    plannerModelName: String,
    plannerModelDisplayName: String,
    plannerModelFileName: String,
    plannerActiveAgentSkillIds: [String],
    plannerActiveConnectorIds: [String],
    speakResponse: Bool
  ) async -> Bool {
    await MainActor.run {
      applyAgentTurnEvent(.searchTools(connectorTitle: connectorSearchTitle))
      appendInlineEvent(.toolSearch(connectorTitle: connectorSearchTitle))
    }

    let mcpResult = await UgotMCPActionRunner.runIfNeeded(
      prompt: prompt,
      activeSkillIds: Set(activeAgentSkillIds),
      activeConnectorIds: connectorIds,
      sessionId: sessionId,
      toolPlanningProvider: { request in
        let planningPrompt = UgotMCPToolPlanningPromptBuilder.build(request: request)
        let planningRequest = GalleryInferenceRequest(
          modelName: plannerModelName,
          modelDisplayName: plannerModelDisplayName,
          modelFileName: plannerModelFileName,
          prompt: planningPrompt,
          route: "mcp-tool-router",
          activeAgentSkillIds: plannerActiveAgentSkillIds,
          activeConnectorIds: plannerActiveConnectorIds,
          supportsImage: false,
          supportsAudio: false,
          attachments: []
        )
        let plannerResult = await runtime.generate(request: planningRequest)
        return UgotMCPToolPlanningDecision.parse(from: plannerResult.text)
      }
    )

    guard let mcpResult else {
      await MainActor.run {
        applyAgentTurnEvent(.skipToolSearch(connectorTitle: connectorSearchTitle))
        appendInlineEvent(.toolSearchSkipped(connectorTitle: connectorSearchTitle))
      }
      return false
    }
    await completeAgenticToolResult(
      mcpResult,
      userPrompt: prompt,
      widgetContext: turnContext,
      route: route,
      modelName: plannerModelName,
      modelDisplayName: plannerModelDisplayName,
      modelFileName: plannerModelFileName,
      activeAgentSkillIds: plannerActiveAgentSkillIds,
      activeConnectorIds: plannerActiveConnectorIds,
      speakResponse: speakResponse
    )
    return true
  }

  private func sendDraftThroughRuntime(
    prompt rawPrompt: String,
    attachmentsOverride: [ChatInputAttachment]? = nil,
    speakResponse: Bool = false
  ) {
    let prompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    let attachmentsToSend = attachmentsOverride ?? attachments
    guard !isGenerating && (!prompt.isEmpty || !attachmentsToSend.isEmpty) else { return }
    let effectivePrompt = prompt.isEmpty ? "Please describe the attached input." : prompt
    let widgetContext = currentWidgetModelContext
    let activeAgentSkillIds = Array(sessionState.agentSkillState.activeSkillIds).sorted()
    let activeConnectorIds = Array(sessionState.connectorBarState.activeConnectorIds).sorted()
    let activeConnectorSet = Set(activeConnectorIds)
    let capabilityRoute: GalleryCapabilityRoute = {
      if let pendingConnectorId = UgotMCPToolApprovalStore.pendingConnectorId(
          sessionId: sessionId,
          connectorIds: activeConnectorSet
         ) {
        return .mcpConnector(pendingConnectorId)
      }
      return GalleryCapabilityRouter.route(
        prompt: effectivePrompt,
        activeSkillIds: Set(activeAgentSkillIds),
        activeConnectorIds: activeConnectorSet
      )
    }()
    let route = sessionState.route()
    let plannerModelName = sessionState.modelName
    let plannerModelDisplayName = sessionState.modelDisplayName
    let plannerModelFileName = model.modelFileName
    let plannerActiveAgentSkillIds = activeAgentSkillIds
    let plannerActiveConnectorIds = activeConnectorIds
    let supportsImageInput = attachmentsToSend.contains { $0.kind == .image } && supports(.image)
    let supportsAudioInput = attachmentsToSend.contains { $0.kind == .audio } && supports(.audio)

    sessionState = sessionState.appendUserMessage(text: userVisiblePrompt(prompt: effectivePrompt, attachments: attachmentsToSend))
    let currentUserMessageId = sessionState.messages.last?.id
    pendingTurnTopScrollTask?.cancel()
    pendingTurnTopScrollTask = nil
    pendingTurnTopAnchorMessageId = currentUserMessageId
    streamingBottomY = 0
    streamingBottomFollowEnabled = false
    lastStreamingAutoScrollTime = 0
    beginAgentTurn(
      prompt: effectivePrompt,
      attachmentCount: attachmentsToSend.count,
      activeAgentSkillIds: activeAgentSkillIds,
      activeConnectorIds: activeConnectorIds
    )
    applyAgentTurnEvent(.routePlanned(agentTurnRoute(for: capabilityRoute, connectorCount: activeConnectorSet.count)))
    isGenerating = true
    streamingAssistantText = ""
    if attachmentsOverride == nil {
      attachments = []
    }
    isComposerFocused = false
    schedulePersistSession(delayNanoseconds: 0)

    Task {
      await MainActor.run {
        applyAgentTurnEvent(.ingestAttachments(count: attachmentsToSend.count))
      }
      let ingestPayload = await ingestAttachmentsForTurn(
        sessionId: sessionId,
        attachments: attachmentsToSend
      )
      await MainActor.run {
        agentWorkspaceStatus = ingestPayload.workspaceStatus
        if !attachmentsToSend.isEmpty {
          appendInlineEvent(
            .attachmentRead(
              count: attachmentsToSend.count,
              names: attachmentsToSend.map(\.displayName)
            )
          )
        }
      }
      let turnContext = Self.mergedAgentContext(
        widgetContext: widgetContext,
        attachmentContext: ingestPayload.context
      )

      var unresolvedMCPActionCommand = false
      let shouldUseVisibleContext = shouldAnswerFromWidgetContext(prompt: effectivePrompt, widgetContext: turnContext)
      if shouldUseVisibleContext {
        await MainActor.run {
          applyAgentTurnEvent(.readVisibleContext)
          appendInlineEvent(.visibleCardRead)
        }
      } else {
        switch capabilityRoute {
        case .nativeSkill(let skillId):
          switch skillId {
          case GalleryAgentSkill.mobileActionsId:
            if let actionResult = await GalleryMobileActionRunner.runIfNeeded(
              prompt: effectivePrompt,
              activeSkillIds: Set(activeAgentSkillIds)
            ) {
              await completeAgenticToolResult(
                actionResult,
                userPrompt: effectivePrompt,
                widgetContext: turnContext,
                route: route,
                modelName: plannerModelName,
                modelDisplayName: plannerModelDisplayName,
                modelFileName: plannerModelFileName,
                activeAgentSkillIds: plannerActiveAgentSkillIds,
                activeConnectorIds: plannerActiveConnectorIds,
                speakResponse: speakResponse
              )
              return
            }
          default:
            break
          }
        case .mcpConnector(let connectorId):
          if await runMCPConnectorTurn(
            prompt: effectivePrompt,
            turnContext: turnContext,
            connectorIds: [connectorId],
            connectorSearchTitle: GalleryConnector.connector(for: connectorId)?.title ?? "MCP",
            activeAgentSkillIds: activeAgentSkillIds,
            route: route,
            plannerModelName: plannerModelName,
            plannerModelDisplayName: plannerModelDisplayName,
            plannerModelFileName: plannerModelFileName,
            plannerActiveAgentSkillIds: plannerActiveAgentSkillIds,
            plannerActiveConnectorIds: plannerActiveConnectorIds,
            speakResponse: speakResponse
          ) {
            return
          }
          unresolvedMCPActionCommand = Self.isLikelyStateChangingToolCommand(effectivePrompt)
        case .mcpConnectors:
          if await runMCPConnectorTurn(
            prompt: effectivePrompt,
            turnContext: turnContext,
            connectorIds: activeConnectorSet,
            connectorSearchTitle: "활성 MCP 커넥터",
            activeAgentSkillIds: activeAgentSkillIds,
            route: route,
            plannerModelName: plannerModelName,
            plannerModelDisplayName: plannerModelDisplayName,
            plannerModelFileName: plannerModelFileName,
            plannerActiveAgentSkillIds: plannerActiveAgentSkillIds,
            plannerActiveConnectorIds: plannerActiveConnectorIds,
            speakResponse: speakResponse
          ) {
            return
          }
          unresolvedMCPActionCommand = Self.isLikelyStateChangingToolCommand(effectivePrompt)
        case .model:
          break
        }
      }

      if unresolvedMCPActionCommand {
        await MainActor.run {
          applyAgentTurnEvent(.generateFinalAnswer(.guardrail))
          completeActionResult(
            GalleryChatActionResult(
              message: "실제 MCP 도구 실행이 필요한 요청인데 실행 가능한 도구를 확정하지 못했어요. 변경·저장·삭제 작업은 도구 실행 결과 없이 완료됐다고 말하지 않도록 중단했어요. 도구 승인 설정과 대상 이름을 확인한 뒤 다시 시도해 주세요."
            ),
            speakResponse: speakResponse,
            terminalOutcome: .guardrailStopped
          )
        }
        return
      }

      if Self.isLikelyStateChangingToolCommand(effectivePrompt) {
        await MainActor.run {
          applyAgentTurnEvent(.generateFinalAnswer(.guardrail))
          completeActionResult(
            GalleryChatActionResult(
              message: "변경·저장·삭제 같은 작업은 실제 도구 실행 결과가 있어야 완료됐다고 말할 수 있어요. 이번 턴에서는 실행된 도구가 없어서 중단했어요. 해당 MCP connector가 켜져 있는지와 도구 승인 설정을 확인해 주세요."
            ),
            speakResponse: speakResponse,
            terminalOutcome: .guardrailStopped
          )
        }
        return
      }

      if let currentUserMessageId {
        await runAutoCompactionIfNeeded(
          currentUserMessageId: currentUserMessageId,
          userPrompt: effectivePrompt,
          widgetContext: turnContext,
          activeAgentSkillIds: activeAgentSkillIds,
          activeConnectorIds: activeConnectorIds,
          route: route
        )
      }

      let modelPrompt = await MainActor.run {
        applyAgentTurnEvent(.generateFinalAnswer(.model))
        return promptForModel(
          userPrompt: effectivePrompt,
          widgetContext: turnContext,
          excludingMessageId: currentUserMessageId
        )
      }
      let request = GalleryInferenceRequest(
        modelName: sessionState.modelName,
        modelDisplayName: sessionState.modelDisplayName,
        modelFileName: model.modelFileName,
        prompt: modelPrompt,
        route: route,
        activeAgentSkillIds: activeAgentSkillIds,
        activeConnectorIds: activeConnectorIds,
        supportsImage: supportsImageInput,
        supportsAudio: supportsAudioInput,
        attachments: attachmentsToSend.map(\.inferenceAttachment)
      )

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
        agentActivityNotice = nil
        if speakResponse, Self.assistantVoiceOutputEnabled {
          let didStartSpeaking = voiceOutput.speak(finalText)
          if liveVoiceSessionActive && !didStartSpeaking {
            scheduleLiveVoiceRestart()
          }
        } else if speakResponse, liveVoiceSessionActive {
          scheduleLiveVoiceRestart()
        }
        schedulePersistSession(delayNanoseconds: 0)
        completeAgentTurn(.answered)
      }
    }
  }


  private static func isLikelyStateChangingToolCommand(_ prompt: String) -> Bool {
    let normalized = prompt
      .lowercased()
      .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
    let mutationTerms = [
      "바꿔", "변경", "설정", "저장", "삭제", "지워", "선택", "등록", "해제",
      "set", "change", "update", "save", "delete", "remove", "select", "clear", "default",
    ]
    let toolStateTerms = [
      "기본사용자", "기본프로필", "대표사용자", "저장사용자", "저장프로필",
      "defaultuser", "defaultprofile", "saveduser", "savedprofile", "preference", "settings",
      "메일", "mail", "이메일", "email", "라벨", "label",
    ]
    return mutationTerms.contains { normalized.contains($0) } &&
      toolStateTerms.contains { normalized.contains($0) }
  }

  private func schedulePersistSession(delayNanoseconds: UInt64 = 250_000_000) {
    pendingPersistTask?.cancel()
    let store = sessionStore
    let id = sessionId
    pendingPersistTask = Task { @MainActor in
      if delayNanoseconds > 0 {
        try? await Task.sleep(nanoseconds: delayNanoseconds)
      }
      guard !Task.isCancelled else { return }
      let persisted = sessionState.persistedSession(id: id, widgetSnapshotsByMessageId: widgetSnapshotsByMessageId)
      if let persisted {
        store.saveInBackground(persisted)
      } else {
        store.deleteInBackground(id: id)
      }
    }
  }

  private func completeActionResult(
    _ result: GalleryChatActionResult,
    speakResponse: Bool = false,
    terminalOutcome: UgotAgentTurnOutcome = .answered
  ) {
    if let approvalRequest = result.approvalRequest {
      applyAgentTurnEvent(.requestApproval(
        connectorTitle: approvalRequest.connectorTitle,
        toolTitle: approvalRequest.toolTitle
      ))
      pendingToolApproval = approvalRequest
      streamingAssistantText = ""
      isGenerating = false
      agentActivityNotice = nil
      completeAgentTurn(.requestedApproval(toolTitle: approvalRequest.toolTitle))
      schedulePersistSession(delayNanoseconds: 0)
      return
    }
    if let observation = result.toolObservation {
      appendAgentToolObservation(observation, userPrompt: nil)
      applyAgentTurnEvent(.runTool(
        connectorTitle: observation.connectorTitle,
        toolTitle: observation.toolTitle
      ))
      applyAgentTurnEvent(.observeTool(
        connectorTitle: observation.connectorTitle,
        toolTitle: observation.toolTitle,
        status: observation.status
      ))
    }
    if let snapshot = result.widgetSnapshot {
      sessionState = sessionState.activateWidget(snapshot: snapshot, fullscreen: false)
      appendInlineEvent(.toolResult(title: snapshot.title))
      activeWidgetAnchorMessageId = sessionState.messages.last?.id
      if let activeWidgetAnchorMessageId {
        widgetSnapshotsByMessageId[activeWidgetAnchorMessageId] = snapshot
      }
      activeWidgetModelContext = snapshot.modelContextFallbackMarkdown ?? result.message
      activeWidgetRenderKey = UUID().uuidString
      applyAgentTurnEvent(.generateFinalAnswer(.widget(toolTitle: snapshot.title)))
    } else {
      appendInlineEvent(.actionCompleted)
      sessionState = sessionState.appendAssistantMessage(text: result.message)
    }
    refreshAgentWorkspaceStatus()
    streamingAssistantText = ""
    isGenerating = false
    agentActivityNotice = nil
    if speakResponse, Self.assistantVoiceOutputEnabled {
      let didStartSpeaking = voiceOutput.speak(result.message)
      if liveVoiceSessionActive && !didStartSpeaking {
        scheduleLiveVoiceRestart()
      }
    } else if speakResponse, liveVoiceSessionActive {
      scheduleLiveVoiceRestart()
    }
    completeAgentTurn(result.widgetSnapshot.map { .showedWidget(toolTitle: $0.title) } ?? terminalOutcome)
    schedulePersistSession(delayNanoseconds: 0)
  }

  private func completeAgenticToolResult(
    _ result: GalleryChatActionResult,
    userPrompt: String,
    widgetContext: String?,
    route: String,
    modelName: String,
    modelDisplayName: String,
    modelFileName: String,
    activeAgentSkillIds: [String],
    activeConnectorIds: [String],
    speakResponse: Bool = false
  ) async {
    guard result.approvalRequest == nil,
          result.widgetSnapshot == nil,
          let observation = result.toolObservation else {
      await MainActor.run {
        completeActionResult(result, speakResponse: speakResponse)
      }
      return
    }

    await MainActor.run {
      appendAgentToolObservation(observation, userPrompt: userPrompt)
      applyAgentTurnEvent(.runTool(
        connectorTitle: observation.connectorTitle,
        toolTitle: observation.toolTitle
      ))
      applyAgentTurnEvent(.observeTool(
        connectorTitle: observation.connectorTitle,
        toolTitle: observation.toolTitle,
        status: observation.status
      ))
      applyAgentTurnEvent(.generateFinalAnswer(.toolObservation(toolTitle: observation.toolTitle)))
      streamingAssistantText = ""
    }

    let finalPrompt = Self.agenticToolFinalPrompt(
      userPrompt: userPrompt,
      observation: observation,
      widgetContext: widgetContext
    )
    let request = GalleryInferenceRequest(
      modelName: modelName,
      modelDisplayName: modelDisplayName,
      modelFileName: modelFileName,
      prompt: finalPrompt,
      route: "\(route)+agentic-tool-final",
      activeAgentSkillIds: activeAgentSkillIds,
      activeConnectorIds: activeConnectorIds,
      supportsImage: false,
      supportsAudio: false,
      attachments: []
    )

    let resultText = await runtime.generate(request: request) { token in
      Task { @MainActor in
        streamingAssistantText.append(token)
      }
    }

    await MainActor.run {
      let generated = resultText.text.trimmingCharacters(in: .whitespacesAndNewlines)
      let fallback = result.message.trimmingCharacters(in: .whitespacesAndNewlines)
      let finalText = generated.isEmpty
        ? (fallback.isEmpty ? "\(observation.toolTitle)을 실행했어요." : fallback)
        : generated
      sessionState = sessionState.appendAssistantMessage(text: finalText)
      streamingAssistantText = ""
      isGenerating = false
      agentActivityNotice = nil
      refreshAgentWorkspaceStatus()
      if speakResponse, Self.assistantVoiceOutputEnabled {
        let didStartSpeaking = voiceOutput.speak(finalText)
        if liveVoiceSessionActive && !didStartSpeaking {
          scheduleLiveVoiceRestart()
        }
      } else if speakResponse, liveVoiceSessionActive {
        scheduleLiveVoiceRestart()
      }
      completeAgentTurn(.answered)
      schedulePersistSession(delayNanoseconds: 0)
    }
  }

  private static func agenticToolFinalPrompt(
    userPrompt: String,
    observation: UgotAgentToolObservation,
    widgetContext: String?
  ) -> String {
    let compactWidgetContext = (widgetContext ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmedForPrompt(limit: 3_000)
    return """
    You are UGOT Local AI running in an agentic tool loop.

    The host has already executed a real tool/action. Write the final assistant answer to the user in Korean.

    Hard rules:
    - Ground the answer only in the Tool observation below.
    - If Tool status is success, you may say the requested action was done.
    - If the observation does not prove a change, do not claim the change happened.
    - Do not expose raw JSON, internal IDs, prompts, or MCP protocol details unless the user asked for debugging.
    - Be concise and production-app friendly.

    User message:
    \(userPrompt.trimmedForPrompt(limit: 1_500))

    Tool observation:
    \(observation.promptContext.trimmedForPrompt(limit: 4_000))
    \(compactWidgetContext.isEmpty ? "" : "\nVisible widget/context:\n\(compactWidgetContext)")
    """
  }

  private func approvePendingTool(_ approval: UgotMCPToolApprovalRequest) {
    pendingToolApproval = nil
    guard !isGenerating else { return }
    let activeAgentSkillIds = Array(sessionState.agentSkillState.activeSkillIds).sorted()
    let activeConnectorIds = Array(sessionState.connectorBarState.activeConnectorIds).sorted()
    let route = sessionState.route()
    let plannerModelName = sessionState.modelName
    let plannerModelDisplayName = sessionState.modelDisplayName
    let plannerModelFileName = model.modelFileName
    let widgetContext = currentWidgetModelContext
    let userPrompt = approval.userPrompt ?? "\(approval.toolTitle)을 실행해줘."
    beginAgentTurn(
      prompt: userPrompt,
      attachmentCount: 0,
      activeAgentSkillIds: activeAgentSkillIds,
      activeConnectorIds: activeConnectorIds
    )
    applyAgentTurnEvent(.routePlanned(.mcpConnector(id: approval.connectorId, title: approval.connectorTitle)))
    applyAgentTurnEvent(.approveTool(connectorTitle: approval.connectorTitle, toolTitle: approval.toolTitle))
    isGenerating = true
    streamingAssistantText = ""
    Task {
      let result = await UgotMCPActionRunner.runApprovedPending(
        sessionId: sessionId,
        activeConnectorIds: [approval.connectorId]
      ) ?? GalleryChatActionResult(message: "승인 대기 중인 도구가 없어요.")
      await completeAgenticToolResult(
        result,
        userPrompt: userPrompt,
        widgetContext: widgetContext,
        route: route,
        modelName: plannerModelName,
        modelDisplayName: plannerModelDisplayName,
        modelFileName: plannerModelFileName,
        activeAgentSkillIds: activeAgentSkillIds,
        activeConnectorIds: activeConnectorIds,
        speakResponse: false
      )
    }
  }

  private func rejectPendingTool(_ approval: UgotMCPToolApprovalRequest) {
    UgotMCPToolApprovalStore.clearPending(sessionId: approval.sessionId, connectorId: approval.connectorId)
    pendingToolApproval = nil
    if isGenerating {
      isGenerating = false
      streamingAssistantText = ""
      agentActivityNotice = nil
    }
    sessionState = sessionState.appendAssistantMessage(text: "\(approval.toolTitle) 실행을 거부했어요.")
    schedulePersistSession(delayNanoseconds: 0)
  }

  private func refreshAgentWorkspaceStatus() {
    Task {
      let status = await Task.detached(priority: .utility) {
        UgotAgentVFS.shared.workspaceStatus(sessionId: sessionId)
      }.value
      await MainActor.run {
        agentWorkspaceStatus = status
      }
    }
  }

  private func appendInlineEvent(_ event: InlineChatEvent) {
    appendAgentTimelineEvent(.notice(event))
  }

  private func appendAgentToolObservation(_ observation: UgotAgentToolObservation, userPrompt: String?) {
    appendAgentTimelineEvent(.toolObservation(observation, userPrompt: userPrompt))
  }

  private func appendAgentTimelineEvent(_ event: UgotAgentTimelineEvent) {
    let marker = UnifiedChatMessage(
      id: "m\(sessionState.nextMessageIndex)",
      role: .system,
      text: event.persistedText
    )
    sessionState = sessionState.doCopy(
      modelName: sessionState.modelName,
      modelDisplayName: sessionState.modelDisplayName,
      taskId: sessionState.taskId,
      modelCapabilities: sessionState.modelCapabilities,
      entryHint: sessionState.entryHint,
      agentSkillState: sessionState.agentSkillState,
      connectorBarState: sessionState.connectorBarState,
      messages: sessionState.messages + [marker],
      draft: sessionState.draft,
      widgetHostState: sessionState.widgetHostState,
      nextMessageIndex: sessionState.nextMessageIndex + 1
    )
  }

  private func ingestAttachmentsForTurn(
    sessionId: String,
    attachments: [ChatInputAttachment]
  ) async -> AttachmentWorkspaceIngestPayload {
    await Task.detached(priority: .utility) {
      let context = UgotAgentVFS.shared.ingestUserAttachments(
        sessionId: sessionId,
        attachments: attachments
      )
      let workspaceStatus = UgotAgentVFS.shared.workspaceStatus(sessionId: sessionId)
      return AttachmentWorkspaceIngestPayload(
        context: context,
        workspaceStatus: workspaceStatus
      )
    }.value
  }

  private func userVisiblePrompt(prompt: String, attachments: [ChatInputAttachment]) -> String {
    guard !attachments.isEmpty else { return prompt }
    let names = attachments.map { "\($0.symbol) \($0.displayName)" }.joined(separator: ", ")
    return "\(prompt)\n\nAttached: \(names)"
  }

  private var currentWidgetModelContext: String? {
    let active = activeWidgetModelContext?.trimmingCharacters(in: .whitespacesAndNewlines)
    let fallback = sessionState.widgetHostState.activeSnapshot?.modelContextFallbackMarkdown?.trimmingCharacters(in: .whitespacesAndNewlines)

    switch (active?.isEmpty == false ? active : nil, fallback?.isEmpty == false ? fallback : nil) {
    case let (.some(active), .some(fallback)):
      if active.contains(fallback.prefix(160)) || fallback.contains(active.prefix(160)) {
        return active.count >= fallback.count ? active : fallback
      }
      return """
      \(active)

      [Initial MCP tool result context]
      \(fallback)
      """
    case let (.some(active), .none):
      return active
    case let (.none, .some(fallback)):
      return fallback
    default:
      return nil
    }
  }

  private static func mergedAgentContext(
    widgetContext: String?,
    attachmentContext: String
  ) -> String? {
    let trimmedWidgetContext = widgetContext?.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedAttachmentContext = attachmentContext.trimmingCharacters(in: .whitespacesAndNewlines)
    let usableAttachmentContext =
      trimmedAttachmentContext.isEmpty || trimmedAttachmentContext == "Available agent files: none"
        ? nil
        : trimmedAttachmentContext

    var sections: [String] = []
    if let trimmedWidgetContext, !trimmedWidgetContext.isEmpty {
      sections.append(trimmedWidgetContext)
    }
    if let usableAttachmentContext {
      sections.append("""
      [Current user attachment files]
      These are virtual workspace paths for the attachments included in the current user turn. Use these paths when referring to files; the actual media is also passed to the local model runtime when supported.
      \(usableAttachmentContext)
      """)
    }
    return sections.isEmpty ? nil : sections.joined(separator: "\n\n")
  }

  private func promptForModel(userPrompt: String, widgetContext: String?, excludingMessageId: String? = nil) -> String {
    let builder = AutoCompactedChatPromptBuilder(
      messages: sessionState.messages.filter { $0.id != excludingMessageId },
      widgetContext: widgetContext,
      userPrompt: userPrompt
    )
    return builder.build()
  }

  private func makeAutoCompactionPlan(
    currentUserMessageId: String,
    userPrompt: String,
    widgetContext: String?
  ) -> ChatAutoCompactionPlan? {
    ChatAutoCompactor.makePlan(
      messages: sessionState.messages,
      currentUserMessageId: currentUserMessageId,
      userPrompt: userPrompt,
      widgetContext: widgetContext
    )
  }

  private func runAutoCompactionIfNeeded(
    currentUserMessageId: String,
    userPrompt: String,
    widgetContext: String?,
    activeAgentSkillIds: [String],
    activeConnectorIds: [String],
    route: String
  ) async {
    guard let plan = await MainActor.run(body: {
      makeAutoCompactionPlan(
        currentUserMessageId: currentUserMessageId,
        userPrompt: userPrompt,
        widgetContext: widgetContext
      )
    }) else {
      return
    }

    await MainActor.run {
      applyAgentTurnEvent(.compactContext)
      appendInlineEvent(.contextOrganizing)
    }

    let compactRequest = GalleryInferenceRequest(
      modelName: sessionState.modelName,
      modelDisplayName: sessionState.modelDisplayName,
      modelFileName: model.modelFileName,
      prompt: plan.compactPrompt,
      route: route,
      activeAgentSkillIds: activeAgentSkillIds,
      activeConnectorIds: activeConnectorIds,
      supportsImage: false,
      supportsAudio: false,
      attachments: []
    )
    let result = await runtime.generate(request: compactRequest)
    await MainActor.run {
      applyAutoCompaction(
        resultText: result.text,
        fallbackSummary: plan.fallbackSummary,
        sourceEstimatedTokens: plan.estimatedTokens,
        currentUserMessageId: currentUserMessageId
      )
      appendInlineEvent(.contextOrganized)
      applyAgentTurnEvent(.finishCompaction)
    }
  }

  private func applyAutoCompaction(
    resultText: String,
    fallbackSummary: String,
    sourceEstimatedTokens: Int,
    currentUserMessageId: String
  ) {
    guard let currentUserIndex = sessionState.messages.firstIndex(where: { $0.id == currentUserMessageId }) else {
      return
    }

    let summary = ChatAutoCompactor.normalizedSummary(
      runtimeText: resultText,
      fallbackSummary: fallbackSummary
    )
    let marker = UnifiedChatMessage(
      id: "m\(sessionState.nextMessageIndex)",
      role: .system,
      text: ChatAutoCompactor.persistedMarkerText(summary: summary, sourceEstimatedTokens: sourceEstimatedTokens)
    )
    var updatedMessages = sessionState.messages
    updatedMessages.insert(marker, at: currentUserIndex)

    suppressNextConversationScroll = true
    sessionState = sessionState.doCopy(
      modelName: sessionState.modelName,
      modelDisplayName: sessionState.modelDisplayName,
      taskId: sessionState.taskId,
      modelCapabilities: sessionState.modelCapabilities,
      entryHint: sessionState.entryHint,
      agentSkillState: sessionState.agentSkillState,
      connectorBarState: sessionState.connectorBarState,
      messages: updatedMessages,
      draft: sessionState.draft,
      widgetHostState: sessionState.widgetHostState,
      nextMessageIndex: sessionState.nextMessageIndex + 1
    )
    schedulePersistSession(delayNanoseconds: 0)
  }

  private func shouldAnswerFromWidgetContext(prompt: String, widgetContext: String?) -> Bool {
    guard let widgetContext,
          !widgetContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return false
    }
    let normalized = prompt
      .lowercased()
      .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
    let explicitNewToolRequest = normalized.contains("오늘") ||
      normalized.contains("today") ||
      normalized.contains("저장목록") ||
      normalized.contains("저장리스트") ||
      normalized.contains("등록목록") ||
      normalized.contains("프로필목록")
    if explicitNewToolRequest {
      return false
    }
    let evaluative = normalized.contains("어때") ||
      normalized.contains("설명") ||
      normalized.contains("분석") ||
      normalized.contains("해석") ||
      normalized.contains("whatdoyouthink") ||
      normalized.contains("howdoesitlook")
    let referential = normalized.contains("이거") ||
      normalized.contains("이것") ||
      normalized.contains("이사람") ||
      normalized.contains("이사주") ||
      normalized.contains("이차트") ||
      normalized.contains("현재위젯") ||
      normalized.contains("위젯내용") ||
      (normalized.contains("사주") && evaluative) ||
      (normalized.count <= 12 && (normalized.contains("어때") || normalized.contains("보여")))
    let continuation = normalized.contains("더") ||
      normalized.contains("자세히") ||
      normalized.contains("추가설명") ||
      normalized.contains("설명해") ||
      normalized.contains("구체") ||
      normalized.contains("풀어서") ||
      normalized.contains("detail") ||
      normalized.contains("elaborate") ||
      normalized.contains("more")
    return evaluative && (referential || continuation)
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
    schedulePersistSession(delayNanoseconds: 0)
  }

  private func setConnector(_ connectorId: String, active: Bool) {
    let currentlyActive = isActive(connectorId)
    guard currentlyActive != active else { return }
    sessionState = sessionState.toggleConnector(connectorId: connectorId)
    schedulePersistSession(delayNanoseconds: 0)
  }

  private func connectorMenuTitle(_ connector: GalleryConnector) -> String {
    connector.title
  }

  private func prewarmMCPTools() {
    let activeConnectorIds = sessionState.connectorBarState.activeConnectorIds
    guard !activeConnectorIds.isEmpty else { return }
    Task {
      await UgotMCPActionRunner.prewarmTools(activeConnectorIds: activeConnectorIds)
    }
  }

  private func reloadMCPPrompts() {
    let activeConnectorIds = sessionState.connectorBarState.activeConnectorIds
    let activeConnectors = connectors.filter { activeConnectorIds.contains($0.id) }
    guard !activeConnectors.isEmpty else {
      mcpPromptItems = []
      isLoadingMCPPrompts = false
      return
    }

    isLoadingMCPPrompts = true
    let locale = UgotMCPLocale.preferredLanguageTag
    Task {
      var loaded: [UgotMCPPromptDescriptor] = []
      do {
        guard let accessToken = try await UgotAuthStore.validAccessToken() else {
          await MainActor.run {
            mcpPromptItems = []
            isLoadingMCPPrompts = false
          }
          return
        }
        for connector in activeConnectors {
          guard let endpoint = URL(string: connector.endpoint) else { continue }
          let client = UgotMCPRuntimeClient.make(
            connectorId: connector.id,
            endpoint: endpoint,
            accessToken: accessToken
          )
          do {
            try await client.initialize()
            let prompts = try await client.listPrompts()
            loaded.append(contentsOf: prompts.map { UgotMCPPromptDescriptor(connector: connector, prompt: $0, locale: locale) })
          } catch {
            continue
          }
        }
      } catch {
        loaded = []
      }
      await MainActor.run {
        mcpPromptItems = loaded.sorted {
          if $0.connectorTitle != $1.connectorTitle { return $0.connectorTitle < $1.connectorTitle }
          return $0.title < $1.title
        }
        isLoadingMCPPrompts = false
      }
    }
  }

  private func applyMCPPrompt(_ prompt: UgotMCPPromptDescriptor) {
    Task {
      var text = prompt.title
      do {
        guard let accessToken = try await UgotAuthStore.validAccessToken(),
              let connector = GalleryConnector.connector(for: prompt.connectorId),
              let endpoint = URL(string: connector.endpoint) else {
          throw NSError(domain: "UgotMCPPrompt", code: 401)
        }
        let client = UgotMCPRuntimeClient.make(
          connectorId: connector.id,
          endpoint: endpoint,
          accessToken: accessToken
        )
        try await client.initialize()
        let result = try await client.getPrompt(name: prompt.name)
        text = UgotMCPPromptRenderer.renderPromptText(result, fallbackTitle: prompt.title)
      } catch {
        text = prompt.title
      }
      await MainActor.run {
        composerDraftSeed = text
        composerFocusToken += 1
      }
    }
  }

  private func activateDemoWidget(fullscreen: Bool) {
    let snapshot = McpWidgetSnapshot(
      connectorId: sessionState.connectorBarState.activeConnectorIds.first ?? GalleryConnector.defaultSelectedIds.first ?? "mcp",
      title: fullscreen ? "Fullscreen MCP Widget" : "Inline MCP Widget",
      summary: "This is a SwiftUI placeholder for future MCP Apps rendering.",
      widgetStateJson: "{\"route\":\"\(sessionState.route())\"}"
    )
    sessionState = sessionState.activateWidget(snapshot: snapshot, fullscreen: fullscreen)
  }
}

@MainActor
private final class UgotMCPToolApprovalViewModel: ObservableObject {
  @Published var tools: [UgotMCPToolDescriptor] = []
  @Published var isLoading = false
  @Published var errorMessage: String?

  func load(connector: GalleryConnector) async {
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }
    do {
      guard let accessToken = try await UgotAuthStore.validAccessToken() else {
        errorMessage = "UGOT 로그인이 필요해요."
        tools = []
        return
      }
      let client = UgotMCPRuntimeClient.make(
        connectorId: connector.id,
        endpoint: URL(string: connector.endpoint)!,
        accessToken: accessToken
      )
      try await client.initialize()
      tools = try await client.listTools()
        .map { UgotMCPToolDescriptor(connectorId: connector.id, tool: $0) }
        .sorted { lhs, rhs in
          if lhs.isDestructive != rhs.isDestructive {
            return !lhs.isDestructive && rhs.isDestructive
          }
          return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    } catch {
      errorMessage = error.localizedDescription
      tools = []
    }
  }

  func policy(for tool: UgotMCPToolDescriptor) -> UgotMCPToolApprovalPolicy {
    UgotMCPToolApprovalStore.policy(connectorId: tool.connectorId, descriptor: tool)
  }

  func setPolicy(_ policy: UgotMCPToolApprovalPolicy, for tool: UgotMCPToolDescriptor) {
    UgotMCPToolApprovalStore.setPolicy(policy, connectorId: tool.connectorId, toolName: tool.name)
    objectWillChange.send()
  }
}

private struct UgotMCPToolApprovalView: View {
  let connector: GalleryConnector
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase
  @StateObject private var viewModel = UgotMCPToolApprovalViewModel()

  var body: some View {
    NavigationStack {
      Group {
        if viewModel.isLoading && viewModel.tools.isEmpty {
          ProgressView("도구 목록을 불러오는 중…")
        } else if let errorMessage = viewModel.errorMessage {
          VStack(spacing: 16) {
            ContentUnavailableView(
              "도구 목록을 불러오지 못했어요",
              systemImage: "exclamationmark.triangle",
              description: Text(errorMessage)
            )
            if connector.endpoint.hasPrefix("http://") {
              Text("로컬 네트워크 권한을 처음 승인한 직후에는 iOS가 첫 요청을 취소할 수 있어요. 앱을 나갔다 오지 않아도 아래 버튼으로 바로 다시 시도할 수 있게 했어요.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            }
            HStack {
              Button {
                Task { await viewModel.load(connector: connector) }
              } label: {
                Label("다시 시도", systemImage: "arrow.clockwise")
              }
              .buttonStyle(.borderedProminent)

              Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                  UIApplication.shared.open(url)
                }
              } label: {
                Label("설정 열기", systemImage: "gearshape")
              }
              .buttonStyle(.bordered)
            }
          }
        } else {
          List {
            Section {
              Text("Connector를 켜는 것은 도구를 사용할 수 있게 만드는 것이고, 여기서는 각 도구의 실행 승인 정책을 따로 제어해요.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            Section("\(connector.title) 도구") {
              ForEach(viewModel.tools) { tool in
                UgotMCPToolApprovalRow(
                  tool: tool,
                  policy: Binding(
                    get: { viewModel.policy(for: tool) },
                    set: { viewModel.setPolicy($0, for: tool) }
                  )
                )
              }
            }
          }
          .refreshable {
            await viewModel.load(connector: connector)
          }
        }
      }
      .navigationTitle("도구 승인")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("닫기") { dismiss() }
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button {
            Task { await viewModel.load(connector: connector) }
          } label: {
            Image(systemName: "arrow.clockwise")
          }
          .disabled(viewModel.isLoading)
        }
      }
      .task {
        if viewModel.tools.isEmpty {
          await viewModel.load(connector: connector)
        }
      }
      .onChange(of: scenePhase) { _, phase in
        guard phase == .active, viewModel.errorMessage != nil else { return }
        Task { await viewModel.load(connector: connector) }
      }
    }
  }
}

private struct UgotMCPToolApprovalPromptView: View {
  let approval: UgotMCPToolApprovalRequest
  let onApprove: () -> Void
  let onReject: () -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 18) {
        Label("도구 실행 승인", systemImage: "hand.raised.fill")
          .font(.title3.weight(.semibold))
          .foregroundStyle(.primary)

        VStack(alignment: .leading, spacing: 10) {
          approvalLine("Connector", approval.connectorTitle)
          approvalLine("Tool", approval.toolTitle)
          Text("`\(approval.toolName)`")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))

        VStack(alignment: .leading, spacing: 8) {
          Text("입력값")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
          Text(approval.argumentsPreview)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        }

        Spacer(minLength: 8)

        HStack(spacing: 12) {
          Button(role: .destructive) {
            dismiss()
            onReject()
          } label: {
            Text("거부")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(.bordered)

          Button {
            dismiss()
            onApprove()
          } label: {
            Text("승인 후 실행")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(.borderedProminent)
        }
      }
      .padding(20)
      .navigationTitle("승인 필요")
      .navigationBarTitleDisplayMode(.inline)
    }
  }

  private func approvalLine(_ title: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text(title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .frame(width: 82, alignment: .leading)
      Text(value)
        .font(.subheadline.weight(.semibold))
      Spacer(minLength: 0)
    }
  }
}

private struct UgotMCPToolApprovalRow: View {
  let tool: UgotMCPToolDescriptor
  @Binding var policy: UgotMCPToolApprovalPolicy

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        VStack(alignment: .leading, spacing: 4) {
          Text(tool.title)
            .font(.subheadline.weight(.semibold))
          Text("`\(tool.name)`")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 8)
        Picker("승인", selection: $policy) {
          ForEach(UgotMCPToolApprovalPolicy.allCases) { policy in
            Label(policy.title, systemImage: policy.symbol).tag(policy)
          }
        }
        .pickerStyle(.menu)
        .labelsHidden()
      }

      if !tool.summary.isEmpty {
        Text(tool.summary)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(3)
      }

      HStack(spacing: 6) {
        if tool.hasWidget {
          ToolBadge(title: "Widget", symbol: "rectangle.on.rectangle")
        }
        if tool.isDestructive {
          ToolBadge(title: "변경/삭제 가능", symbol: "exclamationmark.triangle", tint: .orange)
        }
        if !tool.requiredParameters.isEmpty {
          ToolBadge(title: "필수 \(tool.requiredParameters.count)", symbol: "list.bullet.rectangle")
        }
      }

      Label(policy.detail, systemImage: policy.symbol)
        .font(.caption2)
        .foregroundStyle(policy == .deny ? Color.red : Color.secondary)
    }
    .padding(.vertical, 4)
  }
}

private struct ToolBadge: View {
  let title: String
  let symbol: String
  var tint: Color = .secondary

  var body: some View {
    Label(title, systemImage: symbol)
      .font(.caption2.weight(.semibold))
      .foregroundStyle(tint)
      .padding(.horizontal, 7)
      .padding(.vertical, 4)
      .background(tint.opacity(0.10), in: Capsule())
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

private struct AgentActivityNotice: Equatable, Sendable {
  let symbol: String
  let title: String
  let detail: String

  init(symbol: String, title: String, detail: String) {
    self.symbol = symbol
    self.title = title
    self.detail = detail
  }

  init(activity: UgotAgentTurnActivity) {
    self.symbol = activity.symbol
    self.title = activity.title
    self.detail = activity.detail
  }
}

private struct AttachmentWorkspaceIngestPayload: Sendable {
  let context: String
  let workspaceStatus: AgentWorkspaceStatus
}

private struct InlineChatEvent: Equatable {
  private static let marker = "[UGOT_INLINE_EVENT]"

  let symbol: String
  let title: String
  let detail: String

  var persistedText: String {
    let payload: [String: String] = [
      "symbol": symbol,
      "title": title,
      "detail": detail,
    ]
    let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
    let json = String(data: data, encoding: .utf8) ?? "{}"
    return "\(Self.marker)\n\(json)"
  }

  init(symbol: String, title: String, detail: String) {
    self.symbol = symbol
    self.title = title
    self.detail = detail
  }

  init?(message: UnifiedChatMessage) {
    guard message.role == .system else { return nil }
    if let canonical = UgotAgentTimelineEvent(message: message),
       let event = canonical.inlineEvent {
      self = event
      return
    }
    let trimmed = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix(Self.marker) else { return nil }
    let jsonText = trimmed
      .dropFirst(Self.marker.count)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = jsonText.data(using: .utf8),
          let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let symbol = payload["symbol"] as? String,
          let title = payload["title"] as? String,
          let detail = payload["detail"] as? String else {
      return nil
    }
    self.symbol = symbol
    self.title = title
    self.detail = detail
  }

  static func attachmentRead(count: Int, names: [String]) -> InlineChatEvent {
    let compactNames = names
      .prefix(3)
      .joined(separator: ", ")
    let suffix = names.count > 3 ? " 외 \(names.count - 3)개" : ""
    let detail = count == 1
      ? "\(compactNames)을 답변에 반영할게요."
      : "\(count)개 파일을 답변에 반영할게요: \(compactNames)\(suffix)"
    return InlineChatEvent(
      symbol: "paperclip",
      title: "첨부파일을 읽었어요",
      detail: detail
    )
  }

  static var visibleCardRead: InlineChatEvent {
    InlineChatEvent(
      symbol: "rectangle.on.rectangle",
      title: "화면의 내용을 참고했어요",
      detail: "열린 결과를 기준으로 이어서 답할게요."
    )
  }

  static func toolSearch(connectorTitle: String) -> InlineChatEvent {
    InlineChatEvent(
      symbol: "sparkle.magnifyingglass",
      title: "도구를 검색하고 있어요",
      detail: "\(connectorTitle)에서 실행 가능한 도구를 확인 중이에요."
    )
  }

  static func toolSearchSkipped(connectorTitle: String) -> InlineChatEvent {
    InlineChatEvent(
      symbol: "text.magnifyingglass",
      title: "대화로 이어갈게요",
      detail: "\(connectorTitle)에서 이번 요청에 맞는 실행 도구는 선택하지 않았어요."
    )
  }

  static func toolResult(title: String) -> InlineChatEvent {
    let displayTitle = userFacingTitle(title)
    return InlineChatEvent(
      symbol: "sparkle.magnifyingglass",
      title: "필요한 정보를 가져왔어요",
      detail: displayTitle.map { "\($0)을 아래에 열었어요." } ?? "결과를 아래에 열었어요."
    )
  }

  static func toolExecuted(_ observation: UgotAgentToolObservation) -> InlineChatEvent {
    let title = userFacingTitle(observation.toolTitle) ?? observation.connectorTitle
    let statusText = observation.status == "success" ? "실행 완료" : observation.status
    return InlineChatEvent(
      symbol: observation.didMutate ? "checkmark.shield" : "wrench.and.screwdriver",
      title: "\(title) \(statusText)",
      detail: observation.didMutate ? "도구 결과를 확인한 뒤 답변할게요." : "관찰 결과를 기준으로 이어서 답할게요."
    )
  }

  static var actionCompleted: InlineChatEvent {
    InlineChatEvent(
      symbol: "checkmark.circle",
      title: "요청한 동작을 실행했어요",
      detail: "결과를 이어서 알려드릴게요."
    )
  }

  static var contextOrganized: InlineChatEvent {
    InlineChatEvent(
      symbol: "text.badge.checkmark",
      title: "대화 흐름을 정리했어요",
      detail: "긴 이전 대화는 조용히 정리하고 지금 흐름을 이어갈게요."
    )
  }

  static var contextOrganizing: InlineChatEvent {
    InlineChatEvent(
      symbol: "arrow.triangle.2.circlepath",
      title: "대화 흐름을 정리하고 있어요",
      detail: "긴 이전 대화를 짧게 정리한 뒤 바로 이어갈게요."
    )
  }

  private static func userFacingTitle(_ rawTitle: String) -> String? {
    let trimmed = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let lowered = trimmed.lowercased()
    if lowered.contains("_") ||
      lowered.contains("mcp") ||
      lowered.contains("tool") ||
      lowered.hasPrefix("show") {
      return nil
    }
    return trimmed
  }
}

private struct UgotAgentToolTranscript {
  private static let marker = "[UGOT_TOOL_OBSERVATION]"

  let callId: String
  let userPrompt: String?
  let connectorTitle: String
  let toolName: String
  let toolTitle: String
  let argumentsPreview: String
  let outputText: String
  let hasWidget: Bool
  let didMutate: Bool
  let status: String

  fileprivate init(
    callId: String,
    userPrompt: String?,
    connectorTitle: String,
    toolName: String,
    toolTitle: String,
    argumentsPreview: String,
    outputText: String,
    hasWidget: Bool,
    didMutate: Bool,
    status: String
  ) {
    self.callId = callId
    self.userPrompt = userPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? userPrompt : nil
    self.connectorTitle = connectorTitle
    self.toolName = toolName
    self.toolTitle = toolTitle
    self.argumentsPreview = argumentsPreview
    self.outputText = outputText
    self.hasWidget = hasWidget
    self.didMutate = didMutate
    self.status = status
  }

  var promptText: String {
    var lines: [String] = [
      "[Tool observation]",
      "call_id: \(callId)",
      "status: \(status)",
      "connector: \(connectorTitle)",
      "tool: \(toolTitle) (\(toolName))",
      "mutation: \(didMutate ? "yes" : "no")",
      "widget: \(hasWidget ? "yes" : "no")",
      "arguments: \(argumentsPreview)",
    ]
    if let userPrompt, !userPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      lines.append("original_user_message: \(userPrompt.trimmedForPrompt(limit: 600))")
    }
    lines.append("output:\n\(outputText.trimmedMiddleForPrompt(limit: 1_800))")
    return lines.joined(separator: "\n")
  }

  static func persistedText(observation: UgotAgentToolObservation, userPrompt: String?) -> String {
    let payload: [String: Any] = [
      "callId": "call_\(UUID().uuidString)",
      "userPrompt": userPrompt ?? "",
      "connectorTitle": observation.connectorTitle,
      "toolName": observation.toolName,
      "toolTitle": observation.toolTitle,
      "argumentsPreview": observation.argumentsPreview,
      "outputText": observation.outputText,
      "hasWidget": observation.hasWidget,
      "didMutate": observation.didMutate,
      "status": observation.status,
    ]
    let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
    let json = String(data: data, encoding: .utf8) ?? "{}"
    return "\(Self.marker)\n\(json)"
  }

  init?(message: UnifiedChatMessage) {
    guard message.role == .system else { return nil }
    if let canonical = UgotAgentTimelineEvent(message: message),
       let transcript = canonical.toolTranscript {
      self = transcript
      return
    }
    let trimmed = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix(Self.marker) else { return nil }
    let jsonText = trimmed
      .dropFirst(Self.marker.count)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = jsonText.data(using: .utf8),
          let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let callId = payload["callId"] as? String,
          let connectorTitle = payload["connectorTitle"] as? String,
          let toolName = payload["toolName"] as? String,
          let toolTitle = payload["toolTitle"] as? String,
          let argumentsPreview = payload["argumentsPreview"] as? String,
          let outputText = payload["outputText"] as? String,
          let hasWidget = payload["hasWidget"] as? Bool,
          let didMutate = payload["didMutate"] as? Bool,
          let status = payload["status"] as? String else {
      return nil
    }
    let userPrompt = payload["userPrompt"] as? String
    self.init(
      callId: callId,
      userPrompt: userPrompt,
      connectorTitle: connectorTitle,
      toolName: toolName,
      toolTitle: toolTitle,
      argumentsPreview: argumentsPreview,
      outputText: outputText,
      hasWidget: hasWidget,
      didMutate: didMutate,
      status: status
    )
  }
}

/// Canonical agent timeline event persisted in chat history.
///
/// This is the mobile equivalent of Codex keeping tool-search/tool-call/tool-output
/// items in the conversation stream. UI chips and model-readable transcripts are
/// projections of this single event, so reload/auto-compact/follow-up turns do
/// not depend on separate synthetic system rows.
private struct UgotAgentTimelineEvent {
  private static let marker = "[UGOT_AGENT_EVENT_V1]"

  enum Kind: String {
    case notice
    case toolObservation = "tool_observation"
  }

  let kind: Kind
  let eventId: String
  let timestamp: String
  let display: InlineChatEvent?
  let callId: String?
  let userPrompt: String?
  let connectorTitle: String?
  let toolName: String?
  let toolTitle: String?
  let argumentsPreview: String?
  let outputText: String?
  let hasWidget: Bool?
  let didMutate: Bool?
  let status: String?

  var persistedText: String {
    var payload: [String: Any] = [
      "schema": 1,
      "kind": kind.rawValue,
      "eventId": eventId,
      "timestamp": timestamp,
    ]
    if let display {
      payload["display"] = [
        "symbol": display.symbol,
        "title": display.title,
        "detail": display.detail,
      ]
    }
    if let callId { payload["callId"] = callId }
    if let userPrompt { payload["userPrompt"] = userPrompt }
    if let connectorTitle { payload["connectorTitle"] = connectorTitle }
    if let toolName { payload["toolName"] = toolName }
    if let toolTitle { payload["toolTitle"] = toolTitle }
    if let argumentsPreview { payload["argumentsPreview"] = argumentsPreview }
    if let outputText { payload["outputText"] = outputText }
    if let hasWidget { payload["hasWidget"] = hasWidget }
    if let didMutate { payload["didMutate"] = didMutate }
    if let status { payload["status"] = status }

    let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
    let json = String(data: data, encoding: .utf8) ?? "{}"
    return "\(Self.marker)\n\(json)"
  }

  var inlineEvent: InlineChatEvent? {
    display
  }

  var toolTranscript: UgotAgentToolTranscript? {
    guard kind == .toolObservation,
          let callId,
          let connectorTitle,
          let toolName,
          let toolTitle,
          let argumentsPreview,
          let outputText,
          let hasWidget,
          let didMutate,
          let status else {
      return nil
    }
    return UgotAgentToolTranscript(
      callId: callId,
      userPrompt: userPrompt,
      connectorTitle: connectorTitle,
      toolName: toolName,
      toolTitle: toolTitle,
      argumentsPreview: argumentsPreview,
      outputText: outputText,
      hasWidget: hasWidget,
      didMutate: didMutate,
      status: status
    )
  }

  static func notice(_ event: InlineChatEvent) -> UgotAgentTimelineEvent {
    UgotAgentTimelineEvent(
      kind: .notice,
      eventId: "evt_\(UUID().uuidString)",
      timestamp: ISO8601DateFormatter().string(from: Date()),
      display: event,
      callId: nil,
      userPrompt: nil,
      connectorTitle: nil,
      toolName: nil,
      toolTitle: nil,
      argumentsPreview: nil,
      outputText: nil,
      hasWidget: nil,
      didMutate: nil,
      status: nil
    )
  }

  static func toolObservation(
    _ observation: UgotAgentToolObservation,
    userPrompt: String?
  ) -> UgotAgentTimelineEvent {
    let callId = "call_\(UUID().uuidString)"
    return UgotAgentTimelineEvent(
      kind: .toolObservation,
      eventId: "evt_\(UUID().uuidString)",
      timestamp: ISO8601DateFormatter().string(from: Date()),
      display: .toolExecuted(observation),
      callId: callId,
      userPrompt: userPrompt,
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

  init?(
    message: UnifiedChatMessage
  ) {
    guard message.role == .system else { return nil }
    let trimmed = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix(Self.marker) else { return nil }
    let jsonText = trimmed
      .dropFirst(Self.marker.count)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = jsonText.data(using: .utf8),
          let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let rawKind = payload["kind"] as? String,
          let kind = Kind(rawValue: rawKind),
          let eventId = payload["eventId"] as? String,
          let timestamp = payload["timestamp"] as? String else {
      return nil
    }

    self.kind = kind
    self.eventId = eventId
    self.timestamp = timestamp
    if let displayPayload = payload["display"] as? [String: Any],
       let symbol = displayPayload["symbol"] as? String,
       let title = displayPayload["title"] as? String,
       let detail = displayPayload["detail"] as? String {
      self.display = InlineChatEvent(symbol: symbol, title: title, detail: detail)
    } else {
      self.display = nil
    }
    self.callId = payload["callId"] as? String
    let rawUserPrompt = payload["userPrompt"] as? String
    self.userPrompt = rawUserPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? rawUserPrompt : nil
    self.connectorTitle = payload["connectorTitle"] as? String
    self.toolName = payload["toolName"] as? String
    self.toolTitle = payload["toolTitle"] as? String
    self.argumentsPreview = payload["argumentsPreview"] as? String
    self.outputText = payload["outputText"] as? String
    self.hasWidget = payload["hasWidget"] as? Bool
    self.didMutate = payload["didMutate"] as? Bool
    self.status = payload["status"] as? String
  }

  private init(
    kind: Kind,
    eventId: String,
    timestamp: String,
    display: InlineChatEvent?,
    callId: String?,
    userPrompt: String?,
    connectorTitle: String?,
    toolName: String?,
    toolTitle: String?,
    argumentsPreview: String?,
    outputText: String?,
    hasWidget: Bool?,
    didMutate: Bool?,
    status: String?
  ) {
    self.kind = kind
    self.eventId = eventId
    self.timestamp = timestamp
    self.display = display
    self.callId = callId
    self.userPrompt = userPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? userPrompt : nil
    self.connectorTitle = connectorTitle
    self.toolName = toolName
    self.toolTitle = toolTitle
    self.argumentsPreview = argumentsPreview
    self.outputText = outputText
    self.hasWidget = hasWidget
    self.didMutate = didMutate
    self.status = status
  }
}

private struct AgentVisibilityPanel: View {
  let activity: AgentActivityNotice?
  let compactionStatus: ChatCompactionStatus?
  let workspaceStatus: AgentWorkspaceStatus
  let activeSkillTitles: [String]
  let activeConnectorTitles: [String]

  @State private var isExpanded = false

  var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      VStack(alignment: .leading, spacing: 10) {
        if let activity {
          AgentStateDetailRow(
            symbol: activity.symbol,
            title: activity.title,
            detail: activity.detail,
            showsProgress: activity.title.contains("중")
          )
        }

        if let compactionStatus {
          AgentStateDetailRow(
            symbol: "archivebox",
            title: "Auto compact 활성",
            detail: compactionDetailText(compactionStatus),
            showsProgress: false
          )
          if let summary = compactionStatus.summary, !summary.isEmpty {
            Text(summary)
              .font(.caption2)
              .foregroundStyle(.secondary)
              .lineLimit(5)
              .padding(8)
              .frame(maxWidth: .infinity, alignment: .leading)
              .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
          }
        }

        if !workspaceStatus.isEmpty {
          AgentStateDetailRow(
            symbol: "folder.badge.gearshape",
            title: "Agent workspace",
            detail: "\(workspaceStatus.fileCount)개 artifact가 가상 파일시스템에 있고, 모델 프롬프트에는 안정적인 VFS 경로로 전달돼요.",
            showsProgress: false
          )
          VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(workspaceStatus.files.prefix(6))) { file in
              HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: fileIcon(for: file.mimeType))
                  .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                  Text(file.path)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                  if let preview = file.preview?.trimmingCharacters(in: .whitespacesAndNewlines), !preview.isEmpty {
                    Text(preview.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression))
                      .font(.caption2)
                      .foregroundStyle(.secondary)
                      .lineLimit(1)
                  }
                }
              }
            }
            if workspaceStatus.fileCount > 6 {
              Text("+ \(workspaceStatus.fileCount - 6)개 더 있음")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            }
          }
          .padding(8)
          .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }

        if !activeSkillTitles.isEmpty || !activeConnectorTitles.isEmpty {
          AgentStateDetailRow(
            symbol: "switch.2",
            title: "활성 도구",
            detail: activeToolDetail,
            showsProgress: false
          )
        }
      }
      .padding(.top, 8)
    } label: {
      HStack(spacing: 8) {
        if activity != nil {
          ProgressView()
            .controlSize(.mini)
        } else {
          Image(systemName: "brain.head.profile")
            .foregroundStyle(Color.accentColor)
        }
        Text("Agent 상태")
          .font(.caption.weight(.semibold))
        Spacer(minLength: 8)
        HStack(spacing: 6) {
          if compactionStatus != nil {
            AgentStateChip(title: "compact", symbol: "archivebox")
          }
          if !workspaceStatus.isEmpty {
            AgentStateChip(title: "\(workspaceStatus.fileCount) files", symbol: "folder")
          }
          let toolCount = activeSkillTitles.count + activeConnectorTitles.count
          if toolCount > 0 {
            AgentStateChip(title: "\(toolCount) tools", symbol: "switch.2")
          }
        }
      }
      .contentShape(Rectangle())
    }
    .font(.caption)
    .padding(10)
    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
  }

  private var activeToolDetail: String {
    var parts: [String] = []
    if !activeSkillTitles.isEmpty {
      parts.append("Skills: \(activeSkillTitles.joined(separator: ", "))")
    }
    if !activeConnectorTitles.isEmpty {
      parts.append("Connectors: \(activeConnectorTitles.joined(separator: ", "))")
    }
    return parts.joined(separator: "\n")
  }

  private func compactionDetailText(_ status: ChatCompactionStatus) -> String {
    let tokenText = status.estimatedTokens.map { "약 \($0) tokens를 " } ?? ""
    return "\(tokenText)요약 메모리로 체크포인트했고, 다음 답변부터 이 메모리가 자동으로 포함돼요."
  }

  private func fileIcon(for mimeType: String?) -> String {
    let normalized = mimeType?.lowercased() ?? ""
    if normalized.hasPrefix("image/") { return "photo" }
    if normalized.hasPrefix("audio/") { return "waveform" }
    if normalized.contains("json") { return "curlybraces.square" }
    if normalized.contains("html") { return "safari" }
    if normalized.contains("markdown") || normalized.hasPrefix("text/") { return "doc.text" }
    return "doc"
  }
}

private struct AgentStateChip: View {
  let title: String
  let symbol: String

  var body: some View {
    Label(title, systemImage: symbol)
      .labelStyle(.titleAndIcon)
      .font(.caption2.weight(.semibold))
      .padding(.horizontal, 7)
      .padding(.vertical, 4)
      .foregroundStyle(Color.accentColor)
      .background(Color.accentColor.opacity(0.12), in: Capsule())
  }
}

private struct AgentStateDetailRow: View {
  let symbol: String
  let title: String
  let detail: String
  let showsProgress: Bool

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      if showsProgress {
        ProgressView()
          .controlSize(.mini)
          .padding(.top, 1)
      } else {
        Image(systemName: symbol)
          .foregroundStyle(Color.accentColor)
          .frame(width: 16)
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.caption.weight(.semibold))
        Text(detail)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}


private struct AutoCompactedChatPromptBuilder {
  private static let maxPromptCharacters = 18_000
  private static let maxUserCharacters = 4_000
  private static let maxWidgetCharacters = 8_000
  private static let maxHistoryCharacters = 5_500
  private static let recentMessageCount = 8

  let messages: [UnifiedChatMessage]
  let widgetContext: String?
  let userPrompt: String

  func build() -> String {
    let compactUserPrompt = userPrompt.trimmedForPrompt(limit: Self.maxUserCharacters)
    let compactWidgetContext = compactWidgetContext()
    let compactHistory = compactConversationHistory()

    var sections: [String] = []
    sections.append("""
    You are UGOT Local AI. Answer the user directly and keep behavior grounded in the compacted context below. The context is automatically compacted when it grows too large, so prioritize the Current user message, then Current MCP widget context, then Recent turns, then Older compacted memory. Do not mention the compaction unless the user asks. Never claim that you changed, saved, deleted, selected, sent, opened, or updated anything unless the current turn includes an explicit tool/action result confirming it.
    """)

    if let compactWidgetContext {
      sections.append("""
      [Current MCP widget context]
      This widget is visible to the user and is the source of truth for follow-up questions such as "이거 어때", "어때 보여", "이 사람", "이 사주", or "이 차트". If the current widget is a compatibility/relationship result and the user asks how the relationship looks, answer with concrete details from the score, pair details, relation detail, strengths, cautions, and element balance. Do not answer with only a title or "the result is loaded".
      \(compactWidgetContext)
      """)
    }

    if let compactHistory {
      sections.append("""
      [Auto-compacted chat context]
      \(compactHistory)
      """)
    }

    sections.append("""
    [Current user message]
    \(compactUserPrompt)
    """)

    return sections
      .joined(separator: "\n\n")
      .trimmedForPrompt(limit: Self.maxPromptCharacters)
  }

  private func compactWidgetContext() -> String? {
    guard let widgetContext else { return nil }
    let trimmed = widgetContext.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return trimmed.trimmedMiddleForPrompt(limit: Self.maxWidgetCharacters)
  }

  private func compactConversationHistory() -> String? {
    let projection = ChatAutoCompactor.project(messages: messages)
    let historyMessages = projection.recentMessages
      .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      .filter { !Self.isWidgetDisplayMessage($0) }
      .filter { $0.role != .system || UgotAgentToolTranscript(message: $0) != nil }
    guard !historyMessages.isEmpty || projection.summary != nil else { return nil }

    let recentMessages = Array(historyMessages.suffix(Self.recentMessageCount))
    let olderMessages = projection.summary == nil
      ? Array(historyMessages.dropLast(recentMessages.count))
      : []

    var parts: [String] = []
    if let summary = projection.summary {
      parts.append("""
      Compacted memory:
      \(summary.trimmedMiddleForPrompt(limit: Self.maxHistoryCharacters / 2))
      """)
    }

    if !olderMessages.isEmpty {
      let olderLines = olderMessages
        .suffix(24)
        .map { "- \(Self.historyLine(for: $0, limit: 220))" }
      let omittedCount = max(0, olderMessages.count - olderLines.count)
      var olderSection = "Older memory summary:"
      if omittedCount > 0 {
        olderSection += " \(omittedCount) earlier messages omitted."
      }
      olderSection += "\n" + olderLines.joined(separator: "\n")
      parts.append(olderSection)
    }

    if !recentMessages.isEmpty {
      let recentLines = recentMessages.map { Self.historyLine(for: $0, limit: 1_100) }
      parts.append("Recent turns:\n" + recentLines.joined(separator: "\n\n"))
    }

    let rendered = parts.joined(separator: "\n\n")
    return rendered.trimmedMiddleForPrompt(limit: Self.maxHistoryCharacters)
  }

  private static func isWidgetDisplayMessage(_ message: UnifiedChatMessage) -> Bool {
    message.role == .assistant && message.text.contains("위젯으로 표시했어요")
  }

  private static func historyLine(for message: UnifiedChatMessage, limit: Int) -> String {
    if let transcript = UgotAgentToolTranscript(message: message) {
      return "Tool: \(transcript.promptText.trimmedMiddleForPrompt(limit: limit))"
    }
    return "\(message.role.promptLabel): \(message.text.trimmedMiddleForPrompt(limit: limit))"
  }
}

private struct ChatAutoCompactionPlan {
  let compactPrompt: String
  let fallbackSummary: String
  let estimatedTokens: Int
}

private struct ChatCompactionStatus: Equatable {
  let estimatedTokens: Int?
  let summary: String?
}

private struct ChatHistoryProjection {
  let summary: String?
  let recentMessages: [UnifiedChatMessage]
}

private enum ChatAutoCompactor {
  private static let markerPrefix = "[UGOT_CONTEXT_COMPACTION]"
  private static let summarizationPrompt = """
  You are performing a CONTEXT CHECKPOINT COMPACTION. Create a handoff summary for another LLM that will resume the task.

  Include:
  - Current progress and key decisions made
  - Important context, constraints, or user preferences
  - What remains to be done (clear next steps)
  - Any critical data, examples, or references needed to continue

  Be concise, structured, and focused on helping the next LLM seamlessly continue the work.
  """
  private static let summaryPrefix = """
  Another language model started to solve this problem and produced a summary of the conversation so far. Use this summary to continue the chat without re-reading the compacted-away messages:
  """
  private static let autoCompactTokenLimit = 7_372
  private static let compactInputTokenBudget = 6_400
  private static let recentUserMessageTokenBudget = 20_000
  private static let compactPromptCharacterLimit = 26_000

  static func makePlan(
    messages: [UnifiedChatMessage],
    currentUserMessageId: String,
    userPrompt: String,
    widgetContext: String?
  ) -> ChatAutoCompactionPlan? {
    let historyBeforeCurrent = messages.filter { $0.id != currentUserMessageId }
    let estimatedTokens = estimateActiveTokenUsage(
      messages: historyBeforeCurrent,
      widgetContext: widgetContext,
      userPrompt: userPrompt
    )
    guard estimatedTokens >= autoCompactTokenLimit else {
      return nil
    }

    let projection = project(messages: historyBeforeCurrent)
    let sourceMessages = projection.recentMessages.filter(shouldIncludeInModelHistory)
    let widgetTokenEstimate = widgetContext.map(estimatedTokenCount) ?? 0
    let hasLargeWidgetContext = widgetTokenEstimate >= 1_800
    guard sourceMessages.count > 4 || hasLargeWidgetContext else {
      return nil
    }

    let fallbackSummary = deterministicSummary(
      existingSummary: projection.summary,
      messages: sourceMessages,
      widgetContext: widgetContext
    )
    let compactPrompt = buildCompactPrompt(
      existingSummary: projection.summary,
      messages: sourceMessages,
      widgetContext: widgetContext
    )
    return ChatAutoCompactionPlan(
      compactPrompt: compactPrompt,
      fallbackSummary: fallbackSummary,
      estimatedTokens: estimatedTokens
    )
  }

  static func project(messages: [UnifiedChatMessage]) -> ChatHistoryProjection {
    guard let markerIndex = messages.indices.last(where: { isCompactionMarker(messages[$0]) }) else {
      return ChatHistoryProjection(summary: nil, recentMessages: messages.filter(shouldIncludeInModelHistory))
    }

    let summary = parseSummary(from: messages[markerIndex].text)
    let recent = messages.suffix(from: messages.index(after: markerIndex)).filter(shouldIncludeInModelHistory)
    return ChatHistoryProjection(summary: summary, recentMessages: Array(recent))
  }

  static func status(messages: [UnifiedChatMessage]) -> ChatCompactionStatus? {
    guard let marker = messages.last(where: isCompactionMarker) else { return nil }
    return ChatCompactionStatus(
      estimatedTokens: parseSourceEstimatedTokens(from: marker.text),
      summary: parseSummary(from: marker.text)
    )
  }

  static func persistedMarkerText(summary: String, sourceEstimatedTokens: Int) -> String {
    """
    \(markerPrefix)
    sourceEstimatedTokens: \(sourceEstimatedTokens)
    \(summaryPrefix)
    \(summary.trimmingCharacters(in: .whitespacesAndNewlines))
    """
  }

  static func normalizedSummary(runtimeText: String, fallbackSummary: String) -> String {
    let trimmed = runtimeText.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.count >= 80 && !looksLikeRuntimeFailure(trimmed) {
      return trimmed.trimmedMiddleForPrompt(limit: 5_000)
    }
    return fallbackSummary.trimmedMiddleForPrompt(limit: 5_000)
  }

  private static func buildCompactPrompt(
    existingSummary: String?,
    messages: [UnifiedChatMessage],
    widgetContext: String?
  ) -> String {
    var sections = [summarizationPrompt]
    if let existingSummary, !existingSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      sections.append("""
      Existing compacted summary:
      \(existingSummary.trimmedMiddleForPrompt(limit: 4_000))
      """)
    }
    let renderedMessages = renderForCompaction(messages: messages)
    if !renderedMessages.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      sections.append("""
      Conversation to compact:
      \(renderedMessages)
      """)
    }
    if let widgetContext,
       !widgetContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      sections.append("""
      Current visible MCP widget context to preserve for follow-up questions:
      \(widgetContext.trimmedMiddleForPrompt(limit: 6_000))
      """)
    }
    return sections
      .joined(separator: "\n\n")
      .trimmedMiddleForPrompt(limit: compactPromptCharacterLimit)
  }

  private static func estimateActiveTokenUsage(
    messages: [UnifiedChatMessage],
    widgetContext: String?,
    userPrompt: String
  ) -> Int {
    let projection = project(messages: messages)
    let historyText = projection.recentMessages
      .filter(shouldIncludeInModelHistory)
      .map { "\($0.role.promptLabel): \($0.text)" }
      .joined(separator: "\n\n")
    let summaryTokens = projection.summary.map(estimatedTokenCount) ?? 0
    let widgetTokens = widgetContext.map(estimatedTokenCount) ?? 0
    return 512 +
      summaryTokens +
      estimatedTokenCount(historyText) +
      widgetTokens +
      estimatedTokenCount(userPrompt)
  }

  private static func renderForCompaction(messages: [UnifiedChatMessage]) -> String {
    var rendered: [String] = []
    var remainingTokens = compactInputTokenBudget

    for message in messages.reversed() {
      guard remainingTokens > 0 else { break }
      let line = renderMessageForPrompt(message, limit: 1_600)
      let tokens = estimatedTokenCount(line)
      if tokens <= remainingTokens {
        rendered.append(line)
        remainingTokens -= tokens
      } else {
        rendered.append(line.trimmedMiddleForPrompt(limit: max(300, remainingTokens * 4)))
        break
      }
    }

    return rendered.reversed().joined(separator: "\n\n")
  }

  private static func deterministicSummary(
    existingSummary: String?,
    messages: [UnifiedChatMessage],
    widgetContext: String?
  ) -> String {
    var parts: [String] = []
    if let existingSummary, !existingSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      parts.append("""
      Current compacted memory:
      \(existingSummary.trimmedMiddleForPrompt(limit: 2_200))
      """)
    }

    if !messages.isEmpty {
      let importantLines = messages
        .suffix(24)
        .map { "- \(renderMessageForPrompt($0, limit: 260))" }
        .joined(separator: "\n")
      parts.append("""
      Recent conversation facts and decisions:
      \(importantLines)
      """)
    }

    let recentUserMessages = collectRecentUserMessages(messages: messages)
    if !recentUserMessages.isEmpty {
      parts.append("""
      Recent user messages to preserve:
      \(recentUserMessages.map { "- \($0.oneLineForPrompt(limit: 300))" }.joined(separator: "\n"))
      """)
    }

    if let widgetContext,
       !widgetContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      parts.append("""
      Current visible widget facts to preserve:
      \(widgetContext.trimmedMiddleForPrompt(limit: 2_400))
      """)
    }

    return parts.joined(separator: "\n\n")
  }

  private static func collectRecentUserMessages(messages: [UnifiedChatMessage]) -> [String] {
    var selected: [String] = []
    var remaining = recentUserMessageTokenBudget
    for message in messages.reversed() where message.role == .user {
      let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { continue }
      let tokens = estimatedTokenCount(text)
      if tokens <= remaining {
        selected.append(text)
        remaining -= tokens
      } else {
        selected.append(text.trimmedMiddleForPrompt(limit: max(120, remaining * 4)))
        break
      }
    }
    return selected.reversed()
  }

  private static func shouldIncludeInModelHistory(_ message: UnifiedChatMessage) -> Bool {
    let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return false }
    if isCompactionMarker(message) { return false }
    if UgotAgentToolTranscript(message: message) != nil { return true }
    if message.role == .system { return false }
    if message.role == .assistant && text.hasPrefix("Loaded ") { return false }
    if message.role == .assistant && text.contains("위젯으로 표시했어요") { return false }
    return true
  }

  private static func isCompactionMarker(_ message: UnifiedChatMessage) -> Bool {
    message.role == .system && message.text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(markerPrefix)
  }

  private static func parseSummary(from markerText: String) -> String? {
    guard let range = markerText.range(of: summaryPrefix) else {
      return nil
    }
    let summary = markerText[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
    return summary.isEmpty ? nil : summary
  }

  private static func parseSourceEstimatedTokens(from markerText: String) -> Int? {
    markerText
      .split(separator: "\n")
      .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("sourceEstimatedTokens:") }
      .flatMap { line in
        Int(
          line
            .replacingOccurrences(of: "sourceEstimatedTokens:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        )
      }
  }

  private static func estimatedTokenCount(_ text: String) -> Int {
    max(1, Int(ceil(Double(text.count) / 4.0)))
  }

  private static func renderMessageForPrompt(_ message: UnifiedChatMessage, limit: Int) -> String {
    if let transcript = UgotAgentToolTranscript(message: message) {
      return "Tool: \(transcript.promptText.oneLineForPrompt(limit: limit))"
    }
    return "\(message.role.promptLabel): \(message.text.oneLineForPrompt(limit: limit))"
  }

  private static func looksLikeRuntimeFailure(_ text: String) -> Bool {
    let lowered = text.lowercased()
    return lowered.contains("not found") ||
      lowered.contains("failed") ||
      lowered.contains("runtime") && lowered.contains("not yet include") ||
      lowered.contains("copy it to documents/gallerymodels")
  }
}

private extension UnifiedChatMessageRole {
  var promptLabel: String {
    switch self {
    case .user:
      return "User"
    case .assistant:
      return "Assistant"
    case .system:
      return "System"
    default:
      return "Message"
    }
  }
}

private struct StreamingBottomYPreferenceKey: PreferenceKey {
  static var defaultValue: CGFloat = 0

  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = nextValue()
  }
}

private extension String {
  func oneLineForPrompt(limit: Int) -> String {
    trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmedForPrompt(limit: limit)
  }

  func trimmedForPrompt(limit: Int) -> String {
    guard count > limit else { return self }
    return String(prefix(max(0, limit - 1))) + "…"
  }

  func trimmedMiddleForPrompt(limit: Int) -> String {
    guard count > limit else { return self }
    let marker = "\n…[auto-compacted \(count - limit) chars]…\n"
    let available = max(0, limit - marker.count)
    let headCount = Int(Double(available) * 0.62)
    let tailCount = max(0, available - headCount)
    return String(prefix(headCount)) + marker + String(suffix(tailCount))
  }
}

private struct MessageBubble: View {
  let message: UnifiedChatMessage

  @ViewBuilder
  var body: some View {
    if let event = InlineChatEvent(message: message) {
      InlineChatEventRow(event: event)
    } else {
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
}

private struct InlineChatEventRow: View {
  let event: InlineChatEvent

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Image(systemName: event.symbol)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
      Text(event.title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      if !event.detail.isEmpty {
        Text("· \(event.detail)")
          .font(.caption)
          .foregroundStyle(.tertiary)
          .lineLimit(1)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 4)
    .padding(.vertical, 2)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
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
    Markdown(text)
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

@MainActor
private final class GalleryVoiceOutput: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
  @Published private(set) var isSpeaking = false
  @Published private(set) var completedUtteranceId: UUID?

  private let synthesizer = AVSpeechSynthesizer()
  private var activeUtteranceId: UUID?
  private var speechCompletionFallbackTask: Task<Void, Never>?

  override init() {
    super.init()
    synthesizer.delegate = self
  }

  func stop() {
    speechCompletionFallbackTask?.cancel()
    speechCompletionFallbackTask = nil
    if synthesizer.isSpeaking {
      activeUtteranceId = nil
      synthesizer.stopSpeaking(at: .immediate)
    }
    isSpeaking = false
  }

  @discardableResult
  func speak(_ text: String) -> Bool {
    let spokenText = Self.speechText(from: text)
    guard !spokenText.isEmpty else {
      return false
    }
    stop()
    let utteranceId = UUID()
    activeUtteranceId = utteranceId
    isSpeaking = true
    try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
    try? AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
    let utterance = AVSpeechUtterance(string: spokenText)
    utterance.voice = AVSpeechSynthesisVoice(language: "ko-KR")
      ?? AVSpeechSynthesisVoice(language: Locale.current.identifier)
    utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.92
    utterance.pitchMultiplier = 1.02
    synthesizer.speak(utterance)
    scheduleFallbackCompletion(for: utteranceId, text: spokenText)
    return true
  }

  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    Task { @MainActor in
      self.finishActiveUtterance()
    }
  }

  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    Task { @MainActor in
      self.speechCompletionFallbackTask?.cancel()
      self.speechCompletionFallbackTask = nil
      self.activeUtteranceId = nil
      self.isSpeaking = false
    }
  }

  private func finishActiveUtterance() {
    guard let activeUtteranceId else { return }
    speechCompletionFallbackTask?.cancel()
    speechCompletionFallbackTask = nil
    self.activeUtteranceId = nil
    isSpeaking = false
    completedUtteranceId = activeUtteranceId
  }

  private func scheduleFallbackCompletion(for utteranceId: UUID, text: String) {
    speechCompletionFallbackTask?.cancel()
    let duration = Self.estimatedSpeechDuration(for: text)
    speechCompletionFallbackTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
      guard !Task.isCancelled, activeUtteranceId == utteranceId else { return }
      finishActiveUtterance()
    }
  }

  private static func estimatedSpeechDuration(for text: String) -> Double {
    let characterCount = max(text.count, 1)
    return min(max(Double(characterCount) / 5.5 + 1.2, 2.0), 45.0)
  }

  private static func speechText(from text: String) -> String {
    var result = text
      .replacingOccurrences(of: "```", with: " ")
      .replacingOccurrences(of: "`", with: "")
      .replacingOccurrences(of: "#", with: "")
      .replacingOccurrences(of: "*", with: "")
      .replacingOccurrences(of: "_", with: "")
      .replacingOccurrences(of: ">", with: "")
      .replacingOccurrences(of: "[", with: "")
      .replacingOccurrences(of: "]", with: "")
    result = result.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    return String(result.trimmingCharacters(in: .whitespacesAndNewlines).prefix(900))
  }
}

private struct GalleryLiveVoiceTurn: Equatable, Identifiable {
  let id = UUID()
  let text: String
}

@MainActor
private final class GalleryLiveSpeechInput: NSObject, ObservableObject {
  @Published private(set) var isListening = false
  @Published private(set) var liveTranscript = ""
  @Published private(set) var audioLevel: CGFloat = 0
  @Published private(set) var statusText = "탭해서 말하기"
  @Published private(set) var isFinalizingTurn = false
  @Published var completedTurn: GalleryLiveVoiceTurn?

  private let audioEngine = AVAudioEngine()
  private var speechRecognizer: SFSpeechRecognizer?
  private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
  private var recognitionTask: SFSpeechRecognitionTask?
  private var fallbackCompletionTask: Task<Void, Never>?
  private var silenceCompletionTask: Task<Void, Never>?
  private var hasInstalledInputTap = false
  private var hasCompletedCurrentTurn = false
  private var hasDetectedSpeech = false
  private var lastAudioLevelPublishTime: TimeInterval = 0
  private var lastPublishedAudioLevel: CGFloat = 0

  var isVisible: Bool {
    isListening || !liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  func start(locale: Locale) async throws {
    guard !isListening else { return }
    let speechAuthorized = await Self.requestSpeechAuthorization()
    guard speechAuthorized else {
      throw NSError(
        domain: "GalleryLiveSpeechInput",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "음성 인식 권한이 필요합니다."]
      )
    }
    let microphoneAuthorized = await AVAudioApplication.requestRecordPermission()
    guard microphoneAuthorized else {
      throw NSError(
        domain: "GalleryLiveSpeechInput",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "마이크 권한이 필요합니다."]
      )
    }

    cancel()
    completedTurn = nil
    liveTranscript = ""
    audioLevel = 0
    hasCompletedCurrentTurn = false
    hasDetectedSpeech = false
    isFinalizingTurn = false
    lastAudioLevelPublishTime = 0
    lastPublishedAudioLevel = 0
    statusText = "듣는 중…"

    let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer()
    guard let recognizer, recognizer.isAvailable else {
      throw NSError(
        domain: "GalleryLiveSpeechInput",
        code: 3,
        userInfo: [NSLocalizedDescriptionKey: "현재 사용할 수 있는 음성 인식기가 없습니다."]
      )
    }
    speechRecognizer = recognizer

    let audioSession = AVAudioSession.sharedInstance()
    try audioSession.setCategory(
      .playAndRecord,
      mode: .measurement,
      options: [.duckOthers, .defaultToSpeaker, .allowBluetoothHFP]
    )
    try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    request.taskHint = .dictation
    recognitionRequest = request

    let inputNode = audioEngine.inputNode
    let recordingFormat = inputNode.outputFormat(forBus: 0)
    inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self, request] buffer, _ in
      request.append(buffer)
      let level = Self.normalizedAudioLevel(buffer)
      Task { @MainActor [weak self] in
        self?.handleAudioLevel(level)
      }
    }
    hasInstalledInputTap = true

    recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
      Task { @MainActor [weak self] in
        self?.handleRecognition(result: result, error: error)
      }
    }

    audioEngine.prepare()
    try audioEngine.start()
    isListening = true
  }

  func stop(sendPartialFallback: Bool) {
    guard isListening else { return }
    isListening = false
    isFinalizingTurn = sendPartialFallback
    statusText = "인식 정리 중…"
    let fallbackText = liveTranscript
    silenceCompletionTask?.cancel()
    silenceCompletionTask = nil
    stopAudioCapture(endAudio: true, cancelRecognition: false)

    guard sendPartialFallback else { return }
    fallbackCompletionTask?.cancel()
    fallbackCompletionTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: 650_000_000)
      guard !Task.isCancelled, !hasCompletedCurrentTurn else { return }
      completeTurn(with: fallbackText)
    }
  }

  func cancel() {
    fallbackCompletionTask?.cancel()
    silenceCompletionTask?.cancel()
    silenceCompletionTask = nil
    stopAudioCapture(endAudio: false, cancelRecognition: true)
    isListening = false
    isFinalizingTurn = false
    liveTranscript = ""
    audioLevel = 0
    statusText = "탭해서 말하기"
    hasCompletedCurrentTurn = true
    hasDetectedSpeech = false
  }

  private func handleRecognition(result: SFSpeechRecognitionResult?, error: Error?) {
    if let result {
      liveTranscript = result.bestTranscription.formattedString
      statusText = result.isFinal ? "인식 완료" : "듣는 중…"
      if !liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        hasDetectedSpeech = true
      }
      if result.isFinal {
        completeTurn(with: result.bestTranscription.formattedString)
        return
      }
    }

    if error != nil && !hasCompletedCurrentTurn {
      if !liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        completeTurn(with: liveTranscript)
      } else {
        cancel()
      }
    }
  }

  private func completeTurn(with text: String) {
    let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !hasCompletedCurrentTurn else { return }
    hasCompletedCurrentTurn = true
    fallbackCompletionTask?.cancel()
    silenceCompletionTask?.cancel()
    silenceCompletionTask = nil
    stopAudioCapture(endAudio: false, cancelRecognition: true)
    isListening = false
    isFinalizingTurn = false
    audioLevel = 0
    statusText = "탭해서 말하기"
    hasDetectedSpeech = false
    if normalized.isEmpty {
      liveTranscript = ""
      return
    }
    liveTranscript = ""
    completedTurn = GalleryLiveVoiceTurn(text: normalized)
  }

  private func handleAudioLevel(_ level: CGFloat) {
    guard isListening, !hasCompletedCurrentTurn else { return }

    let now = CACurrentMediaTime()
    let shouldPublish = now - lastAudioLevelPublishTime > 0.10 ||
      abs(level - lastPublishedAudioLevel) > 0.08
    if shouldPublish {
      audioLevel = level
      lastPublishedAudioLevel = level
      lastAudioLevelPublishTime = now
    }

    if level > 0.075 {
      hasDetectedSpeech = true
      silenceCompletionTask?.cancel()
      silenceCompletionTask = nil
      return
    }

    guard hasDetectedSpeech, silenceCompletionTask == nil else { return }
    silenceCompletionTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: 1_250_000_000)
      let normalized = liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !Task.isCancelled,
            isListening,
            hasDetectedSpeech,
            !normalized.isEmpty,
            audioLevel < 0.12 else {
        silenceCompletionTask = nil
        return
      }
      stop(sendPartialFallback: true)
    }
  }

  private func stopAudioCapture(endAudio: Bool, cancelRecognition: Bool) {
    if audioEngine.isRunning {
      audioEngine.stop()
    }
    if hasInstalledInputTap {
      audioEngine.inputNode.removeTap(onBus: 0)
      hasInstalledInputTap = false
    }
    if endAudio {
      recognitionRequest?.endAudio()
    }
    if cancelRecognition {
      recognitionTask?.cancel()
      recognitionTask = nil
      recognitionRequest = nil
    }
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }

  private static func requestSpeechAuthorization() async -> Bool {
    await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { status in
        continuation.resume(returning: status == .authorized)
      }
    }
  }

  nonisolated private static func normalizedAudioLevel(_ buffer: AVAudioPCMBuffer) -> CGFloat {
    guard let channelData = buffer.floatChannelData?[0] else { return 0 }
    let frameLength = Int(buffer.frameLength)
    guard frameLength > 0 else { return 0 }
    var sum: Float = 0
    for index in 0..<frameLength {
      let sample = channelData[index]
      sum += sample * sample
    }
    let rms = sqrt(sum / Float(frameLength))
    return CGFloat(min(max(rms * 24, 0), 1))
  }
}

private struct ChatComposerBar: View {
  let draftSeed: String
  let focusToken: Int
  @Binding var attachments: [ChatInputAttachment]
  @Binding var selectedPhotoItem: PhotosPickerItem?
  @Binding var showCamera: Bool
  @Binding var showAudioFilePicker: Bool
  let supportsImage: Bool
  let supportsAudio: Bool
  let supportsVoiceInput: Bool
  let isGenerating: Bool
  let isVoiceListening: Bool
  let isVoiceSessionActive: Bool
  let isVoiceSpeaking: Bool
  let voiceLevel: CGFloat
  let mcpPromptItems: [UgotMCPPromptDescriptor]
  let isLoadingMCPPrompts: Bool
  let onRecordAudio: () -> Void
  let onVoiceInput: () -> Void
  let onSelectMCPPrompt: (UgotMCPPromptDescriptor) -> Void
  let onSend: (String) -> Void

  @State private var draft: String
  @FocusState private var isFocused: Bool

  init(
    draftSeed: String,
    focusToken: Int,
    attachments: Binding<[ChatInputAttachment]>,
    selectedPhotoItem: Binding<PhotosPickerItem?>,
    showCamera: Binding<Bool>,
    showAudioFilePicker: Binding<Bool>,
    supportsImage: Bool,
    supportsAudio: Bool,
    supportsVoiceInput: Bool,
    isGenerating: Bool,
    isVoiceListening: Bool,
    isVoiceSessionActive: Bool,
    isVoiceSpeaking: Bool,
    voiceLevel: CGFloat,
    mcpPromptItems: [UgotMCPPromptDescriptor],
    isLoadingMCPPrompts: Bool,
    onRecordAudio: @escaping () -> Void,
    onVoiceInput: @escaping () -> Void,
    onSelectMCPPrompt: @escaping (UgotMCPPromptDescriptor) -> Void,
    onSend: @escaping (String) -> Void
  ) {
    self.draftSeed = draftSeed
    self.focusToken = focusToken
    _attachments = attachments
    _selectedPhotoItem = selectedPhotoItem
    _showCamera = showCamera
    _showAudioFilePicker = showAudioFilePicker
    self.supportsImage = supportsImage
    self.supportsAudio = supportsAudio
    self.supportsVoiceInput = supportsVoiceInput
    self.isGenerating = isGenerating
    self.isVoiceListening = isVoiceListening
    self.isVoiceSessionActive = isVoiceSessionActive
    self.isVoiceSpeaking = isVoiceSpeaking
    self.voiceLevel = voiceLevel
    self.mcpPromptItems = mcpPromptItems
    self.isLoadingMCPPrompts = isLoadingMCPPrompts
    self.onRecordAudio = onRecordAudio
    self.onVoiceInput = onVoiceInput
    self.onSelectMCPPrompt = onSelectMCPPrompt
    self.onSend = onSend
    _draft = State(initialValue: draftSeed)
  }

  var body: some View {
    VStack(spacing: 8) {
      attachmentStrip
      HStack(alignment: .bottom, spacing: 8) {
        addInputMenu
        mcpPromptMenu
        TextField("메시지", text: $draft, axis: .vertical)
          .lineLimit(1...4)
          .focused($isFocused)
          .textFieldStyle(.plain)
          .padding(.vertical, 8)
        if supportsVoiceInput {
          Button {
            onVoiceInput()
          } label: {
            voiceButtonLabel
          }
          .buttonStyle(.plain)
          .disabled(isGenerating && !isVoiceListening && !isVoiceSessionActive)
          .accessibilityLabel(isVoiceSessionActive ? "Stop voice chat" : "Voice chat")
        }
        Button {
          let draftToSend = draft
          draft = ""
          onSend(draftToSend)
        } label: {
          sendButtonLabel
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
      }
      .padding(.leading, 8)
      .padding(.trailing, 6)
      .padding(.vertical, 6)
      .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
    .padding(.horizontal, 14)
    .padding(.top, 8)
    .padding(.bottom, 10)
    .background(Color(.systemBackground))
    .overlay(alignment: .top) {
      Divider().opacity(0.45)
    }
    .onChange(of: draftSeed) { _, value in
      draft = value
    }
    .onChange(of: focusToken) { _, _ in
      draft = draftSeed
      isFocused = true
    }
  }

  private var canSend: Bool {
    !isGenerating && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
  }

  private var voiceButtonSymbol: String {
    if isVoiceListening { return "waveform.circle.fill" }
    if isVoiceSpeaking { return "speaker.wave.2.circle.fill" }
    if isVoiceSessionActive { return "stop.circle.fill" }
    if isGenerating { return "mic.slash.circle.fill" }
    return "mic.circle.fill"
  }

  private var voiceButtonColor: Color {
    if isVoiceListening { return .red }
    if isVoiceSessionActive { return .orange }
    if isGenerating { return .secondary }
    return .accentColor
  }

  private var voiceButtonLabel: some View {
    Image(systemName: voiceButtonSymbol)
      .font(.title2)
      .symbolRenderingMode(.hierarchical)
      .foregroundStyle(voiceButtonColor)
      .frame(width: 34, height: 34)
      .scaleEffect(isVoiceListening ? 1 + min(voiceLevel, 0.8) * 0.18 : 1)
      .animation(.easeOut(duration: 0.12), value: voiceLevel)
  }

  private var sendButtonLabel: some View {
    ZStack {
      Circle()
        .fill(canSend ? Color.accentColor : Color(.tertiarySystemFill))
        .frame(width: 32, height: 32)
      if isGenerating {
        ProgressView()
          .controlSize(.small)
          .tint(.white)
      } else {
        Image(systemName: "arrow.up")
          .font(.system(size: 15, weight: .bold))
          .foregroundStyle(canSend ? .white : .secondary)
      }
    }
  }

  @ViewBuilder
  private var attachmentStrip: some View {
    if !attachments.isEmpty {
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

  private var addInputMenu: some View {
    Menu {
      if supportsImage {
        PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
          Label("Photo Library", systemImage: "photo.on.rectangle")
        }
        Button {
          showCamera = true
        } label: {
          Label("Camera", systemImage: "camera")
        }
      }
      if supportsAudio {
        Button {
          showAudioFilePicker = true
        } label: {
          Label("Pick WAV File", systemImage: "doc.badge.plus")
        }
        Button {
          onRecordAudio()
        } label: {
          Label("Record Audio", systemImage: "mic")
        }
      }
      if !supportsImage && !supportsAudio {
        Text("No attachments available")
      }
    } label: {
      Image(systemName: "plus")
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(Color.accentColor)
        .frame(width: 32, height: 32)
        .background(Color(.tertiarySystemFill), in: Circle())
    }
    .accessibilityLabel("Add input")
  }

  private var mcpPromptMenu: some View {
    Menu {
      if isLoadingMCPPrompts && mcpPromptItems.isEmpty {
        Label("프롬프트 불러오는 중", systemImage: "hourglass")
      } else if mcpPromptItems.isEmpty {
        Label("사용 가능한 MCP 프롬프트 없음", systemImage: "text.badge.xmark")
      } else {
        ForEach(groupedPromptConnectors, id: \.connectorId) { group in
          Section(group.connectorTitle) {
            ForEach(group.items) { item in
              Button {
                onSelectMCPPrompt(item)
              } label: {
                Label(item.title, systemImage: item.connectorSymbol)
              }
            }
          }
        }
      }
    } label: {
      Image(systemName: isLoadingMCPPrompts ? "text.badge.clock" : "text.badge.star")
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(mcpPromptItems.isEmpty && !isLoadingMCPPrompts ? Color.secondary : Color.accentColor)
        .frame(width: 32, height: 32)
        .background(Color(.tertiarySystemFill), in: Circle())
    }
    .accessibilityLabel("MCP prompts")
  }

  private var groupedPromptConnectors: [PromptConnectorGroup] {
    Dictionary(grouping: mcpPromptItems, by: \.connectorId)
      .compactMap { connectorId, items -> PromptConnectorGroup? in
        guard let first = items.first else { return nil }
        return PromptConnectorGroup(
          connectorId: connectorId,
          connectorTitle: first.connectorTitle,
          items: items.sorted { $0.title < $1.title }
        )
      }
      .sorted { $0.connectorTitle < $1.connectorTitle }
  }
}

private struct PromptConnectorGroup: Hashable {
  let connectorId: String
  let connectorTitle: String
  let items: [UgotMCPPromptDescriptor]
}

private struct WidgetPreview: View, Equatable {
  let snapshot: McpWidgetSnapshot
  let renderKey: String
  let fullscreen: Bool
  var onModelContextChanged: ((String) -> Void)?
  @State private var renderFailure: String?
  @State private var widgetHeight: CGFloat = 520
  @State private var showsToolDetails = false

  static func == (lhs: WidgetPreview, rhs: WidgetPreview) -> Bool {
    lhs.renderKey == rhs.renderKey && lhs.fullscreen == rhs.fullscreen
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      widgetHeader

      if let renderFailure,
         let content = snapshot.contentMarkdown {
        AssistantMarkdownText(text: content)
          .font(.body)
        Text("Widget render fallback: \(renderFailure)")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      } else if snapshot.hasMcpWidgetHTML {
        UgotMCPWidgetWebView(
          snapshot: snapshot,
          onSizeChanged: { height in
            if abs(widgetHeight - height) > 1 {
              widgetHeight = height
            }
          },
          onModelContextChanged: onModelContextChanged,
          onRenderFailure: { message in
            renderFailure = message
          }
        )
        .frame(maxWidth: .infinity, minHeight: 360)
        .frame(height: fullscreen ? max(widgetHeight, 520) : widgetHeight)
        .onChange(of: snapshot.widgetStateJson) { _, _ in
          widgetHeight = 520
          renderFailure = nil
        }
      } else if let content = snapshot.contentMarkdown {
        AssistantMarkdownText(text: content)
          .font(.body)
          .padding(.vertical, 4)
      }
    }
    .padding(12)
    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .stroke(Color(.separator).opacity(0.35), lineWidth: 0.5)
    )
  }

  private var widgetHeader: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .center, spacing: 8) {
        Label("결과", systemImage: "sparkles.rectangle.stack")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Spacer(minLength: 8)
        Text(snapshot.userFacingWidgetTitle)
          .font(.caption.weight(.semibold))
          .foregroundStyle(Color.accentColor)
          .padding(.horizontal, 8)
          .padding(.vertical, 5)
          .background(Color.accentColor.opacity(0.12), in: Capsule())
      }

      DisclosureGroup(isExpanded: $showsToolDetails) {
        VStack(alignment: .leading, spacing: 5) {
          widgetDetailRow(label: "연결", value: snapshot.connectorDisplayName)
          widgetDetailRow(label: "제목", value: snapshot.title)
          if !snapshot.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            widgetDetailRow(label: "요약", value: snapshot.summary)
          }
          if let input = snapshot.toolInputPreview {
            widgetDetailRow(label: "입력", value: input)
          }
        }
        .padding(.top, 4)
      } label: {
        Text(showsToolDetails ? "상세 정보 숨기기" : "상세 정보")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
      }
      .tint(.secondary)
    }
  }

  private func widgetDetailRow(label: String, value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(label)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .frame(width: 42, alignment: .leading)
      Text(value)
        .font(label == "입력" ? .system(.caption2, design: .monospaced) : .caption2)
        .foregroundStyle(.secondary)
        .lineLimit(3)
    }
  }
}


private extension McpWidgetSnapshot {
  var renderKeySeed: String {
    "\(connectorId)|\(title)|\(summary)|\(widgetStateJson.utf8.count)"
  }

  var widgetStateObject: [String: Any]? {
    guard let data = widgetStateJson.data(using: .utf8) else {
      return nil
    }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }

  var userFacingWidgetTitle: String {
    if let explicitTitle = userFacingText(title) {
      return explicitTitle
    }
    if let rawToolName = userFacingText(widgetStateObject?["toolName"] as? String) {
      return rawToolName
    }
    return "열린 결과"
  }

  private func userFacingText(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !trimmed.isEmpty else { return nil }
    let lowered = trimmed.lowercased()
    if lowered.contains("_") ||
      lowered.contains("mcp") ||
      lowered.contains("tool") ||
      lowered.hasPrefix("show") {
      return nil
    }
    return trimmed
  }

  var toolNameForDisplay: String {
    let rawToolName = widgetStateObject?["toolName"] as? String
    let trimmed = rawToolName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? title : trimmed
  }

  var toolInputPreview: String? {
    guard let input = widgetStateObject?["toolInput"] as? [String: Any],
          !input.isEmpty,
          let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8),
          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return nil
    }
    return text.count > 220 ? String(text.prefix(220)) + "…" : text
  }

  var connectorDisplayName: String {
    GalleryConnector.connector(for: connectorId)?.title ?? connectorId
  }

  var hasMcpWidgetHTML: Bool {
    guard let object = widgetStateObject,
          let htmlBase64 = object["widgetHtmlBase64"] as? String,
          Data(base64Encoded: htmlBase64) != nil else {
      return false
    }
    return true
  }

  var contentMarkdown: String? {
    guard let object = widgetStateObject,
          let content = object["contentMarkdown"] as? String,
          !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return nil
    }
    return content
  }

  var modelContextFallbackMarkdown: String? {
    guard let object = widgetStateObject else {
      return nil
    }
    if let modelContext = object["modelContext"] as? String,
       !modelContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return modelContext
    }
    var lines: [String] = []
    lines.append("Widget title: \(title)")
    if !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      lines.append("Widget summary: \(summary)")
    }
    if let toolName = object["toolName"] as? String {
      lines.append("Tool: \(toolName)")
    }
    if let content = object["contentMarkdown"] as? String,
       !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      lines.append(content)
    }
    if let toolOutput = object["toolOutput"] as? [String: Any],
       let resources = toolOutput["embeddedResources"] as? [[String: Any]],
       !resources.isEmpty {
      let resourceLines = resources.map { resource -> String in
        let uri = resource["uri"] as? String ?? "embedded-resource"
        let mimeType = resource["mimeType"] as? String ?? "unknown"
        let textLength = resource["textLength"].map { ", \(String(describing: $0)) chars" } ?? ""
        return "- \(uri) (\(mimeType)\(textLength))"
      }
      lines.append("Embedded resources available to the widget:\n\(resourceLines.joined(separator: "\n"))")
    }
    let rendered = lines.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    return rendered.isEmpty ? nil : rendered
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
