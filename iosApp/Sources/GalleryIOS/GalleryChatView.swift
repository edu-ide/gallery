import Foundation
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

private enum ThinkingDisplayMode: String, CaseIterable, Identifiable {
  case detailed
  case compact
  case hidden

  var id: String { rawValue }

  var title: String {
    switch self {
    case .detailed: return "상세"
    case .compact: return "Compact"
    case .hidden: return "숨김"
    }
  }

  var detail: String {
    switch self {
    case .detailed: return "실행 로그를 펼쳐서 표시"
    case .compact: return "한 줄로 표시"
    case .hidden: return "숨김"
    }
  }

  var symbol: String {
    switch self {
    case .detailed: return "list.bullet.rectangle"
    case .compact: return "ellipsis.bubble"
    case .hidden: return "eye.slash"
    }
  }
}

private extension GalleryModelThinkingMode {
  var title: String {
    switch self {
    case .off: return "끄기"
    case .on: return "켜기"
    }
  }

  var detail: String {
    switch self {
    case .off: return "빠른 직접 답변을 우선해요."
    case .on: return "답변 전에 더 신중하게 계획하도록 요청해요."
    }
  }

  var symbol: String {
    switch self {
    case .off: return "bolt"
    case .on: return "brain.head.profile.fill"
    }
  }
}

private final class GalleryInferenceTimeoutState: @unchecked Sendable {
  private let lock = NSLock()
  private var completed = false
  private let continuation: CheckedContinuation<GalleryInferenceResult?, Never>

  init(_ continuation: CheckedContinuation<GalleryInferenceResult?, Never>) {
    self.continuation = continuation
  }

  func finish(_ result: GalleryInferenceResult?) {
    lock.lock()
    defer { lock.unlock() }
    guard !completed else { return }
    completed = true
    continuation.resume(returning: result)
  }

  func shouldEmitToken() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return !completed
  }
}

struct GalleryChatView: View {
  private static let transcriptScrollCoordinateSpace = "gallery-chat-transcript-scroll"
  private static let mcpToolPlanningTimeoutNanoseconds: UInt64 = 12_000_000_000
  private static let mcpToolFinalAnswerTimeoutNanoseconds: UInt64 = 15_000_000_000
  // Gemma/local LLM responses are text. Voice playback here would be iOS TTS,
  // which can accidentally read raw MCP tool payloads aloud. Keep assistant
  // audio output disabled unless a dedicated voice-generation model is wired in.
  private static let assistantVoiceOutputEnabled = false

  let model: GalleryModel
  let agentSkills: [GalleryAgentSkill]
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
  @State private var connectors: [GalleryConnector]
  @State private var showConnectorSettings = false
  @State private var toolApprovalConnector: GalleryConnector?
  @State private var pendingToolApproval: UgotMCPToolApprovalRequest?
  @State private var mcpPromptItems: [UgotMCPPromptDescriptor] = []
  @State private var mcpResourceItems: [UgotMCPResourceDescriptor] = []
  @State private var mcpContextAttachments: [UgotMCPContextAttachment] = []
  @State private var pendingMCPPromptForArguments: PendingMCPPromptArgumentsPresentation?
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
  @State private var currentAgentTurn: AgentTurnState?
  @State private var agentThinkingText = ""
  @State private var mcpConnectorStatusEvents: [String: UgotMCPConnectorStatusEvent] = [:]
  @State private var mcpConnectorStatusMessageId: String?
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
  @AppStorage("gallery.modelThinkingMode") private var modelThinkingModeRaw = GalleryModelThinkingMode.on.rawValue
  @AppStorage("gallery.thinkingDisplayMode") private var thinkingDisplayModeRaw = ThinkingDisplayMode.compact.rawValue
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
    self.entryHint = entryHint
    self._connectors = State(initialValue: connectors)
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
          Section("모델 Thinking") {
            Picker("모델 Thinking", selection: Binding(
              get: { modelThinkingMode },
              set: { modelThinkingModeRaw = $0.rawValue }
            )) {
              ForEach(GalleryModelThinkingMode.allCases) { mode in
                Label(mode.title, systemImage: mode.symbol)
                  .tag(mode)
              }
            }
            .pickerStyle(.inline)
          }
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
              Button {
                showConnectorSettings = true
              } label: {
                Label("Connector 설정", systemImage: "externaldrive.connected.to.line.below")
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
    .sheet(isPresented: $showConnectorSettings) {
      NavigationStack {
        GalleryConnectorSettingsView(
          selectedConnectorIds: Binding(
            get: { Set(sessionState.connectorBarState.activeConnectorIds) },
            set: { applyConnectorSelection($0) }
          ),
          onChanged: {
            reloadConnectorRegistry()
          }
        )
      }
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
    .sheet(item: $pendingMCPPromptForArguments) { presentation in
      MCPPromptArgumentsSheet(
        prompt: presentation.prompt,
        automaticArguments: automaticMCPPromptArguments(for: presentation.prompt),
        onCancel: { pendingMCPPromptForArguments = nil },
        onAttach: { arguments in
          pendingMCPPromptForArguments = nil
          attachMCPPrompt(presentation.prompt, arguments: arguments)
        },
        onCompleteArgument: { prompt, argumentName, partialValue, arguments in
          await completeMCPPromptArgument(
            prompt,
            argumentName: argumentName,
            partialValue: partialValue,
            arguments: arguments
          )
        }
      )
      .id(presentation.id)
      .presentationDetents([.medium, .large])
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
        if shouldShowStreamingBubble {
          StreamingBubble(
            text: streamingAssistantText,
            modelThinkingMode: modelThinkingMode
          )
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

  private var modelThinkingMode: GalleryModelThinkingMode {
    GalleryModelThinkingMode(rawValue: modelThinkingModeRaw) ?? .on
  }

  private var thinkingDisplayMode: ThinkingDisplayMode {
    ThinkingDisplayMode(rawValue: thinkingDisplayModeRaw) ?? .compact
  }

  private var shouldShowStreamingBubble: Bool {
    !streamingAssistantText.isEmpty || isGenerating
  }

  private var shouldReserveTurnTopSpace: Bool {
    pendingTurnTopAnchorMessageId != nil || isGenerating
  }

  private var shouldShowAgentVisibilityPanel: Bool { false }

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
      mcpResourceItems: mcpResourceItems,
      mcpContextAttachments: $mcpContextAttachments,
      isLoadingMCPPrompts: isLoadingMCPPrompts,
      onRecordAudio: openAttachmentAudioRecorder,
      onVoiceInput: openLiveVoiceRecorder,
      onSelectMCPPrompt: applyMCPPrompt,
      onSelectMCPResource: applyMCPResource,
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
    let turn = AgentTurnStateMachineKt.createAgentTurnState(
      userPrompt: prompt,
      attachmentCount: Int32(attachmentCount),
      activeSkillIds: activeAgentSkillIds,
      activeConnectorIds: activeConnectorIds,
      id: "turn_\(UUID().uuidString)",
      nowEpochMs: Self.currentEpochMs()
    )
    currentAgentTurn = turn
    agentActivityNotice = turn.activity.map(AgentActivityNotice.init(activity:))
    agentThinkingText = Self.agentThinkingText(from: turn)
  }

  private func applyAgentTurnEvent(_ event: AgentTurnEvent) {
    guard let turn = currentAgentTurn else { return }
    let nextTurn = turn.apply(event: event, nowEpochMs: Self.currentEpochMs())
    currentAgentTurn = nextTurn
    agentActivityNotice = nextTurn.activity.map(AgentActivityNotice.init(activity:))
    agentThinkingText = Self.agentThinkingText(from: nextTurn)
  }

  private func completeAgentTurn(_ outcome: AgentTurnOutcome) {
    applyAgentTurnEvent(AgentTurnStateMachineKt.agentTurnEventComplete(outcome: outcome))
    currentAgentTurn = nil
    agentActivityNotice = nil
    agentThinkingText = ""
  }

  private static func agentThinkingText(from turn: AgentTurnState?) -> String {
    guard let turn else { return "" }
    var lines: [String] = []
    let prompt = turn.userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    if !prompt.isEmpty {
      lines.append("요청 해석: \(prompt.trimmedMiddleForPrompt(limit: 180))")
    }
    for (index, step) in turn.steps.enumerated() {
      let title = step.title.trimmingCharacters(in: .whitespacesAndNewlines)
      let detail = step.detail.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !title.isEmpty || !detail.isEmpty else { continue }
      if detail.isEmpty {
        lines.append("\(index + 1). \(title)")
      } else {
        lines.append("\(index + 1). \(title) — \(detail)")
      }
    }
    let phaseTitle = turn.phase.title.trimmingCharacters(in: .whitespacesAndNewlines)
    let phaseDetail = turn.phase.detail.trimmingCharacters(in: .whitespacesAndNewlines)
    if !phaseTitle.isEmpty || !phaseDetail.isEmpty {
      let currentLine = phaseDetail.isEmpty ? "현재: \(phaseTitle)" : "현재: \(phaseTitle) — \(phaseDetail)"
      if lines.last != currentLine {
        lines.append(currentLine)
      }
    }
    return lines.joined(separator: "\n")
  }

  private func assistantMessageText(content: String) -> String {
    // Do not persist or render a separate trace/thinking envelope in normal chat.
    // Tool/search/approval activity is projected as explicit inline event rows.
    content
  }

  private func agentTurnRoute(
    for route: GalleryCapabilityRoute,
    connectorCount: Int
  ) -> AgentTurnRoute {
    switch route {
    case .nativeSkill(let skillId):
      let title = agentSkills.first(where: { $0.id == skillId })?.title
      return AgentTurnStateMachineKt.agentTurnRouteNativeSkill(id: skillId, title: title)
    case .mcpConnector(let connectorId):
      let title = GalleryConnector.connector(for: connectorId)?.title
      return AgentTurnStateMachineKt.agentTurnRouteMcpConnector(id: connectorId, title: title)
    case .mcpConnectors:
      return AgentTurnStateMachineKt.agentTurnRouteMcpConnectors(count: Int32(connectorCount))
    case .model:
      return AgentTurnStateMachineKt.agentTurnRouteModel()
    }
  }

  private static func currentEpochMs() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1_000)
  }

  private func generateWithTimeout(
    request: GalleryInferenceRequest,
    timeoutNanoseconds: UInt64,
    onToken: (@Sendable (String) -> Void)? = nil
  ) async -> GalleryInferenceResult? {
    let runtime = runtime
    return await withCheckedContinuation { continuation in
      let state = GalleryInferenceTimeoutState(continuation)
      let generationTask = Task.detached(priority: .userInitiated) {
        let result: GalleryInferenceResult
        if let onToken {
          result = await runtime.generate(request: request) { token in
            guard state.shouldEmitToken() else { return }
            onToken(token)
          }
        } else {
          result = await runtime.generate(request: request)
        }
        state.finish(result)
      }
      Task.detached(priority: .utility) {
        try? await Task.sleep(nanoseconds: timeoutNanoseconds)
        generationTask.cancel()
        state.finish(nil)
      }
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
    requireToolObservation: Bool,
    toolSelectionHintsByConnectorId: [String: UgotMCPToolSelectionHints] = [:],
    speakResponse: Bool
  ) async -> Bool {
    await MainActor.run {
      applyAgentTurnEvent(AgentTurnStateMachineKt.agentTurnEventSearchTools(connectorTitle: connectorSearchTitle))
      appendInlineEvent(.toolSearch(connectorTitle: connectorSearchTitle))
    }

    let mcpResult = await UgotMCPActionRunner.runIfNeeded(
      prompt: prompt,
      activeSkillIds: Set(activeAgentSkillIds),
      activeConnectorIds: connectorIds,
      sessionId: sessionId,
      requireToolObservation: requireToolObservation,
      toolSelectionHintsByConnectorId: toolSelectionHintsByConnectorId,
      toolPlanningProvider: { request in
        let planningPrompt = UgotMCPToolPlanningPromptBuilder.build(request: request)
        let planningRequest = GalleryInferenceRequest(
          modelName: plannerModelName,
          modelDisplayName: plannerModelDisplayName,
          modelFileName: plannerModelFileName,
          prompt: planningPrompt,
          route: "mcp-tool-router",
          thinkingMode: .off,
          activeAgentSkillIds: plannerActiveAgentSkillIds,
          activeConnectorIds: plannerActiveConnectorIds,
          supportsImage: false,
          supportsAudio: false,
          attachments: []
        )
        guard let plannerResult = await generateWithTimeout(
          request: planningRequest,
          timeoutNanoseconds: Self.mcpToolPlanningTimeoutNanoseconds
        ) else {
          return nil
        }
        return UgotMCPToolPlanningDecision.parse(from: plannerResult.text)
      },
      connectorStatusHandler: { event in
        await MainActor.run {
          upsertMCPConnectorStatusEvent(event)
        }
      }
    )

    guard let mcpResult else {
      await MainActor.run {
        applyAgentTurnEvent(AgentTurnStateMachineKt.agentTurnEventSkipToolSearch(connectorTitle: connectorSearchTitle))
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
    let mcpContextAttachmentsToSend = mcpContextAttachments
    guard !isGenerating && (!prompt.isEmpty || !attachmentsToSend.isEmpty || !mcpContextAttachmentsToSend.isEmpty) else { return }
    let effectivePrompt = Self.effectiveTurnPrompt(
      typedPrompt: prompt,
      mcpContextAttachments: mcpContextAttachmentsToSend
    )
    let widgetContext = currentWidgetModelContext
    let activeAgentSkillIds = Array(sessionState.agentSkillState.activeSkillIds).sorted()
    let activeConnectorSet = Set(sessionState.connectorBarState.activeConnectorIds)
    let mcpContextConnectorSet = Set(mcpContextAttachmentsToSend.map(\.connectorId))
    let turnConnectorSet = activeConnectorSet.union(mcpContextConnectorSet)
    let activeConnectorIds = Array(turnConnectorSet).sorted()
    let hasMCPPromptAttachment = mcpContextAttachmentsToSend.contains { $0.kind == .prompt }
    let mcpContextRequiresToolObservation = hasMCPPromptAttachment || Self.isLikelyMCPToolCommand(effectivePrompt)
    let mcpToolSelectionHintsByConnectorId = Self.mcpToolSelectionHintsByConnectorId(mcpContextAttachmentsToSend)
    let capabilityRoute: GalleryCapabilityRoute = {
      if let pendingConnectorId = UgotMCPToolApprovalStore.pendingConnectorId(
          sessionId: sessionId,
          connectorIds: turnConnectorSet
         ) {
        return .mcpConnector(pendingConnectorId)
      }
      if mcpContextConnectorSet.count == 1,
         let connectorId = mcpContextConnectorSet.first {
        return .mcpConnector(connectorId)
      }
      if !mcpContextConnectorSet.isEmpty {
        return .mcpConnectors
      }
      return GalleryCapabilityRouter.route(
        prompt: effectivePrompt,
        activeSkillIds: Set(activeAgentSkillIds),
        activeConnectorIds: turnConnectorSet
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

    let visibleUserText = userVisiblePrompt(
      prompt: prompt,
      attachments: attachmentsToSend,
      mcpContextAttachments: mcpContextAttachmentsToSend
    )
    let previousLastMessageId = sessionState.messages.last?.id
    sessionState = sessionState.appendUserMessage(text: visibleUserText)
    let currentUserMessageId = sessionState.messages.last?.id == previousLastMessageId
      ? nil
      : sessionState.messages.last?.id
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
    applyAgentTurnEvent(AgentTurnStateMachineKt.agentTurnEventRoutePlanned(route: agentTurnRoute(for: capabilityRoute, connectorCount: turnConnectorSet.count)))
    isGenerating = true
    streamingAssistantText = ""
    mcpConnectorStatusEvents = [:]
    mcpConnectorStatusMessageId = nil
    if attachmentsOverride == nil {
      attachments = []
      mcpContextAttachments = []
    }
    isComposerFocused = false
    schedulePersistSession(delayNanoseconds: 0)

    if turnConnectorSet.isEmpty && Self.isLikelyMCPToolCommand(effectivePrompt) {
      applyAgentTurnEvent(AgentTurnStateMachineKt.agentTurnEventGenerateFinalAnswer(source: AgentTurnStateMachineKt.agentTurnFinalAnswerSourceGuardrail()))
      completeActionResult(
        GalleryChatActionResult(
          message: "이 요청은 MCP connector 도구가 필요하지만 현재 켜진 connector가 없어요. Chat input 옆 connector 메뉴에서 Fortune/Gmail 같은 connector를 켠 뒤 다시 실행해 주세요."
        ),
        speakResponse: speakResponse,
        terminalOutcome: AgentTurnStateMachineKt.agentTurnOutcomeGuardrailStopped()
      )
      return
    }

    Task {
      await MainActor.run {
        applyAgentTurnEvent(AgentTurnStateMachineKt.agentTurnEventIngestAttachments(count: Int32(attachmentsToSend.count)))
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
        if !mcpContextAttachmentsToSend.isEmpty {
          appendInlineEvent(.mcpContextAttached(mcpContextAttachmentsToSend))
        }
      }
      let turnContext = Self.mergedAgentContext(
        widgetContext: widgetContext,
        attachmentContext: ingestPayload.context,
        mcpContext: Self.mcpContextSummary(mcpContextAttachmentsToSend)
      )

      var unresolvedMCPActionCommand = false
      let shouldUseVisibleContext = !hasMCPPromptAttachment && shouldAnswerFromWidgetContext(prompt: effectivePrompt, widgetContext: turnContext)
      if shouldUseVisibleContext {
        await MainActor.run {
          applyAgentTurnEvent(AgentTurnStateMachineKt.agentTurnEventReadVisibleContext())
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
            requireToolObservation: true,
            toolSelectionHintsByConnectorId: mcpToolSelectionHintsByConnectorId,
            speakResponse: speakResponse
          ) {
            return
          }
          unresolvedMCPActionCommand = mcpContextRequiresToolObservation
        case .mcpConnectors:
          if await runMCPConnectorTurn(
            prompt: effectivePrompt,
            turnContext: turnContext,
            connectorIds: turnConnectorSet,
            connectorSearchTitle: mcpContextConnectorSet.isEmpty ? "활성 MCP 커넥터" : "첨부 MCP 커넥터",
            activeAgentSkillIds: activeAgentSkillIds,
            route: route,
            plannerModelName: plannerModelName,
            plannerModelDisplayName: plannerModelDisplayName,
            plannerModelFileName: plannerModelFileName,
            plannerActiveAgentSkillIds: plannerActiveAgentSkillIds,
            plannerActiveConnectorIds: plannerActiveConnectorIds,
            requireToolObservation: mcpContextRequiresToolObservation,
            toolSelectionHintsByConnectorId: mcpToolSelectionHintsByConnectorId,
            speakResponse: speakResponse
          ) {
            return
          }
          unresolvedMCPActionCommand = mcpContextRequiresToolObservation
        case .model:
          break
        }
      }

      if unresolvedMCPActionCommand {
        await MainActor.run {
          applyAgentTurnEvent(AgentTurnStateMachineKt.agentTurnEventGenerateFinalAnswer(source: AgentTurnStateMachineKt.agentTurnFinalAnswerSourceGuardrail()))
          completeActionResult(
            GalleryChatActionResult(
              message: "MCP 도구 실행이 필요한 요청인데 실행 가능한 도구를 확정하지 못했어요. 일반 대화로 처리하면 거짓 답변이 될 수 있어서 중단했어요. connector가 켜져 있는지, 로그인이 유지되는지, 도구 승인 설정이 막혀 있지 않은지 확인해 주세요."
            ),
            speakResponse: speakResponse,
            terminalOutcome: AgentTurnStateMachineKt.agentTurnOutcomeGuardrailStopped()
          )
        }
        return
      }

      if Self.isLikelyStateChangingToolCommand(effectivePrompt) {
        await MainActor.run {
          applyAgentTurnEvent(AgentTurnStateMachineKt.agentTurnEventGenerateFinalAnswer(source: AgentTurnStateMachineKt.agentTurnFinalAnswerSourceGuardrail()))
          completeActionResult(
            GalleryChatActionResult(
              message: "변경·저장·삭제 같은 작업은 실제 도구 실행 결과가 있어야 완료됐다고 말할 수 있어요. 이번 턴에서는 실행된 도구가 없어서 중단했어요. 해당 MCP connector가 켜져 있는지와 도구 승인 설정을 확인해 주세요."
            ),
            speakResponse: speakResponse,
            terminalOutcome: AgentTurnStateMachineKt.agentTurnOutcomeGuardrailStopped()
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
        applyAgentTurnEvent(AgentTurnStateMachineKt.agentTurnEventGenerateFinalAnswer(source: AgentTurnStateMachineKt.agentTurnFinalAnswerSourceModel()))
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
        thinkingMode: modelThinkingMode,
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
        sessionState = sessionState.appendAssistantMessage(text: assistantMessageText(content: finalText))
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
        completeAgentTurn(AgentTurnStateMachineKt.agentTurnOutcomeAnswered())
      }
    }
  }


  private static func isLikelyStateChangingToolCommand(_ prompt: String) -> Bool {
    let normalized = prompt
      .lowercased()
      .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
    let mutationTerms = [
      "바꿔", "바꿀", "바꾸", "변경", "변경할", "설정", "설정할", "지정",
      "저장", "삭제", "지워", "선택", "등록", "해제",
      "set", "change", "update", "save", "delete", "remove", "select", "clear", "default", "make",
    ]
    let toolStateTerms = [
      "기본사용자", "기본유저", "기본프로필", "기본타깃", "기본타겟", "기본대상",
      "대표사용자", "대표유저", "대표타깃", "대표타겟", "대표대상", "저장사용자", "저장유저", "저장프로필",
      "defaultuser", "defaultprofile", "defaulttarget", "saveduser", "savedprofile", "preference", "settings",
      "메일", "mail", "이메일", "email", "라벨", "label",
    ]
    return mutationTerms.contains { normalized.contains($0) } &&
      toolStateTerms.contains { normalized.contains($0) }
  }

  private static func isLikelyMCPToolCommand(_ prompt: String) -> Bool {
    if isLikelyStateChangingToolCommand(prompt) {
      return true
    }
    let normalized = prompt
      .lowercased()
      .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
    let connectorDomainTerms = [
      "운세", "사주", "오늘운세", "띠별", "궁합", "관계", "저장목록", "저장사용자", "저장유저", "기본사용자", "기본유저",
      "fortune", "saju", "horoscope", "compatibility", "savedprofile", "saveduser",
      "메일", "이메일", "받은메일", "최근메일", "메일요약", "mail", "email", "inbox", "gmail",
      "계정", "로그인", "인증", "연동", "연결됨", "연결됐", "연동됨", "연동됐",
      "account", "identity", "login", "auth", "oauth", "connected", "connection", "linked",
    ]
    return connectorDomainTerms.contains { normalized.contains($0) }
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
    terminalOutcome: AgentTurnOutcome? = nil
  ) {
    for observation in result.toolObservations {
      appendAgentToolObservation(observation, userPrompt: nil)
      applyAgentTurnEvent(AgentTurnStateMachineKt.agentTurnEventRunTool(
        connectorTitle: observation.connectorTitle,
        toolTitle: observation.toolTitle
      ))
      applyAgentTurnEvent(AgentTurnStateMachineKt.agentTurnEventObserveTool(
        connectorTitle: observation.connectorTitle,
        toolTitle: observation.toolTitle,
        status: observation.status
      ))
    }
    if let approvalRequest = result.approvalRequest {
      applyAgentTurnEvent(AgentTurnStateMachineKt.agentTurnEventRequestApproval(
        connectorTitle: approvalRequest.connectorTitle,
        toolTitle: approvalRequest.toolTitle
      ))
      pendingToolApproval = approvalRequest
      streamingAssistantText = ""
      isGenerating = false
      agentActivityNotice = nil
      completeAgentTurn(AgentTurnStateMachineKt.agentTurnOutcomeRequestedApproval(toolTitle: approvalRequest.toolTitle))
      schedulePersistSession(delayNanoseconds: 0)
      return
    }
    if let snapshot = result.widgetSnapshot {
      sessionState = sessionState.activateWidget(snapshot: snapshot, fullscreen: false)
      if result.toolObservations.isEmpty {
        appendInlineEvent(.toolResult(title: snapshot.title))
      }
      activeWidgetAnchorMessageId = sessionState.messages.last?.id
      if let activeWidgetAnchorMessageId {
        widgetSnapshotsByMessageId[activeWidgetAnchorMessageId] = snapshot
      }
      activeWidgetModelContext = snapshot.modelContextFallbackMarkdown ?? result.message
      activeWidgetRenderKey = UUID().uuidString
      applyAgentTurnEvent(AgentTurnStateMachineKt.agentTurnEventGenerateFinalAnswer(source: AgentTurnStateMachineKt.agentTurnFinalAnswerSourceWidget(toolTitle: snapshot.title)))
    } else {
      if result.toolObservations.isEmpty {
        appendInlineEvent(.actionCompleted)
      }
      sessionState = sessionState.appendAssistantMessage(text: assistantMessageText(content: result.message))
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
    let outcome = result.widgetSnapshot.map {
      AgentTurnStateMachineKt.agentTurnOutcomeShowedWidget(toolTitle: $0.title)
    } ?? terminalOutcome ?? AgentTurnStateMachineKt.agentTurnOutcomeAnswered()
    completeAgentTurn(outcome)
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
    let normalizedResult = Self.resultWithCanonicalObservationIfNeeded(result)
    guard normalizedResult.approvalRequest == nil,
          normalizedResult.widgetSnapshot == nil,
          let observation = normalizedResult.toolObservation else {
      await MainActor.run {
        completeActionResult(normalizedResult, speakResponse: speakResponse)
      }
      return
    }

    await MainActor.run {
      for observation in normalizedResult.toolObservations {
        appendAgentToolObservation(observation, userPrompt: userPrompt)
        applyAgentTurnEvent(AgentTurnStateMachineKt.agentTurnEventRunTool(
          connectorTitle: observation.connectorTitle,
          toolTitle: observation.toolTitle
        ))
        applyAgentTurnEvent(AgentTurnStateMachineKt.agentTurnEventObserveTool(
          connectorTitle: observation.connectorTitle,
          toolTitle: observation.toolTitle,
          status: observation.status
        ))
      }
      applyAgentTurnEvent(AgentTurnStateMachineKt.agentTurnEventGenerateFinalAnswer(source: AgentTurnStateMachineKt.agentTurnFinalAnswerSourceToolObservation(toolTitle: observation.toolTitle)))
      streamingAssistantText = ""
    }

    let finalPrompt = Self.agenticToolFinalPrompt(
      userPrompt: userPrompt,
      observation: observation,
      observations: normalizedResult.toolObservations,
      widgetContext: widgetContext
    )
    let request = GalleryInferenceRequest(
      modelName: modelName,
      modelDisplayName: modelDisplayName,
      modelFileName: modelFileName,
      prompt: finalPrompt,
      route: "\(route)+agentic-tool-final",
      thinkingMode: modelThinkingMode,
      activeAgentSkillIds: activeAgentSkillIds,
      activeConnectorIds: activeConnectorIds,
      supportsImage: false,
      supportsAudio: false,
      attachments: []
    )

    let resultText = await generateWithTimeout(
      request: request,
      timeoutNanoseconds: Self.mcpToolFinalAnswerTimeoutNanoseconds
    ) { token in
      Task { @MainActor in
        streamingAssistantText.append(token)
      }
    }

    await MainActor.run {
      let generated = resultText?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let fallback = result.message.trimmingCharacters(in: .whitespacesAndNewlines)
      let finalText = generated.isEmpty
        ? (fallback.isEmpty ? "\(observation.toolTitle)을 실행했어요." : fallback)
        : generated
      sessionState = sessionState.appendAssistantMessage(text: assistantMessageText(content: finalText))
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
      completeAgentTurn(AgentTurnStateMachineKt.agentTurnOutcomeAnswered())
      schedulePersistSession(delayNanoseconds: 0)
    }
  }

  private static func resultWithCanonicalObservationIfNeeded(_ result: GalleryChatActionResult) -> GalleryChatActionResult {
    guard result.approvalRequest == nil,
          result.widgetSnapshot == nil,
          result.toolObservations.isEmpty else {
      return result
    }
    let message = result.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? "도구 실행이 완료되지 않았어요."
      : result.message
    return GalleryChatActionResult(
      message: message,
      toolObservation: UgotAgentToolObservation.hostObservation(
        connectorTitle: "Agent Tool Loop",
        toolName: "agent.tool_result",
        toolTitle: "도구 실행 상태",
        outputText: message,
        status: "blocked"
      )
    )
  }

  private static func agenticToolFinalPrompt(
    userPrompt: String,
    observation: UgotAgentToolObservation,
    observations: [UgotAgentToolObservation],
    widgetContext: String?
  ) -> String {
    let compactWidgetContext = (widgetContext ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmedForPrompt(limit: 3_000)
    let observationTranscript = observations.isEmpty
      ? observation.promptContext
      : observations
        .suffix(8)
        .enumerated()
        .map { index, observation in
          """
          Observation \(index + 1):
          \(observation.promptContext)
          """
        }
        .joined(separator: "\n\n")
        .trimmedForPrompt(limit: 6_000)
    return """
    You are UGOT Local AI running in an agentic tool loop.

    The host has completed the tool-loop observation step. There may be multiple observations because the host can search/resolve/replan before answering. Write the final assistant answer to the user in Korean.

    Hard rules:
    - Ground the answer only in the Tool observations below.
    - If the final relevant Tool status is success and Mutation is yes, you may say the requested action was done.
    - If the final relevant Tool status is success and Mutation is no, summarize the observed result without claiming a change.
    - If the final relevant Tool status is not success, clearly say the action was not completed and what is needed next.
    - If the observations do not prove a change, do not claim the change happened.
    - Do not expose raw JSON, internal IDs, prompts, or MCP protocol details unless the user asked for debugging.
    - Be concise and production-app friendly.

    User message:
    \(userPrompt.trimmedForPrompt(limit: 1_500))

    Final relevant tool:
    \(observation.toolTitle) (`\(observation.toolName)`) status=\(observation.status)

    Tool observations:
    \(observationTranscript)
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
    applyAgentTurnEvent(AgentTurnStateMachineKt.agentTurnEventRoutePlanned(route: AgentTurnStateMachineKt.agentTurnRouteMcpConnector(id: approval.connectorId, title: approval.connectorTitle)))
    applyAgentTurnEvent(AgentTurnStateMachineKt.agentTurnEventApproveTool(connectorTitle: approval.connectorTitle, toolTitle: approval.toolTitle))
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

  private func upsertMCPConnectorStatusEvent(_ event: UgotMCPConnectorStatusEvent) {
    mcpConnectorStatusEvents[event.connectorId] = event
    let summary = InlineChatEvent.mcpConnectorStatusSummary(Array(mcpConnectorStatusEvents.values))
    let text = UgotAgentTimelineEvent.notice(summary).persistedText

    if let messageId = mcpConnectorStatusMessageId,
       let index = sessionState.messages.firstIndex(where: { $0.id == messageId }) {
      var messages = sessionState.messages
      messages[index] = UnifiedChatMessage(id: messageId, role: .system, text: text)
      sessionState = sessionState.doCopy(
        modelName: sessionState.modelName,
        modelDisplayName: sessionState.modelDisplayName,
        taskId: sessionState.taskId,
        modelCapabilities: sessionState.modelCapabilities,
        entryHint: sessionState.entryHint,
        agentSkillState: sessionState.agentSkillState,
        connectorBarState: sessionState.connectorBarState,
        messages: messages,
        draft: sessionState.draft,
        widgetHostState: sessionState.widgetHostState,
        nextMessageIndex: sessionState.nextMessageIndex
      )
      return
    }

    let marker = UnifiedChatMessage(
      id: "m\(sessionState.nextMessageIndex)",
      role: .system,
      text: text
    )
    mcpConnectorStatusMessageId = marker.id
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

  private func userVisiblePrompt(
    prompt: String,
    attachments: [ChatInputAttachment],
    mcpContextAttachments: [UgotMCPContextAttachment]
  ) -> String {
    var lines: [String] = []
    let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedPrompt.isEmpty {
      lines.append(trimmedPrompt)
    }
    if !attachments.isEmpty {
      let names = attachments.map { "\($0.symbol) \($0.displayName)" }.joined(separator: ", ")
      lines.append("Attached files: \(names)")
    }
    if !mcpContextAttachments.isEmpty {
      lines.append(UserMCPContextAttachmentEnvelope.persistedText(mcpContextAttachments))
    }
    return lines.joined(separator: "\n\n")
  }

  private static func effectiveTurnPrompt(
    typedPrompt: String,
    mcpContextAttachments: [UgotMCPContextAttachment]
  ) -> String {
    let trimmedPrompt = typedPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !mcpContextAttachments.isEmpty else {
      return trimmedPrompt.isEmpty ? "Please describe the attached input." : trimmedPrompt
    }

    let attachedItems = mcpContextAttachments
      .map { attachment in
        let kind = attachment.kind == .prompt ? "Prompt" : "Resource"
        let summary = attachment.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = [
          summary.isEmpty
          ? "- \(kind): \(attachment.title) (\(attachment.connectorTitle))"
          : "- \(kind): \(attachment.title) (\(attachment.connectorTitle)) — \(summary)"
        ]
        if let uri = attachment.uri, !uri.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          lines.append("  - id: \(uri)")
        }
        if !attachment.arguments.isEmpty {
          let args = Self.mcpArgumentsJSONObjectString(attachment.arguments)
          lines.append("  - selected arguments: \(args)")
        }
        lines.append("  - intent effect: \(attachment.intentEffect)")
        let renderedPrompt = attachment.contextText
          .trimmingCharacters(in: .whitespacesAndNewlines)
          .trimmedMiddleForPrompt(limit: 1_500)
        if !renderedPrompt.isEmpty {
          lines.append("  - rendered instruction:\n\(renderedPrompt)")
        }
        return lines.joined(separator: "\n")
      }
      .joined(separator: "\n")
    let intentEffect = UgotMCPIntentEffect.strongest(mcpContextAttachments.map(\.intentEffect))
    let intentLine = Self.mcpIntentLine(for: intentEffect)
    let policyLine = Self.mcpIntentPolicyLine(for: intentEffect)

    return """
    [MCP attachment request]
    \(intentLine)
    \(trimmedPrompt.isEmpty ? "User message: <attached prompt/resource only>" : "User message: \(trimmedPrompt)")

    The user attached these MCP prompt/resource artifacts as the request:
    \(attachedItems)

    Treat the attached artifact and its selected arguments as the user's intent. Explicit selected arguments override the current widget, default profile, or previously opened result. \(policyLine) Do not expose raw MCP attachment text to the user.
    """
  }

  private static func mcpToolSelectionHintsByConnectorId(
    _ attachments: [UgotMCPContextAttachment]
  ) -> [String: UgotMCPToolSelectionHints] {
    Dictionary(grouping: attachments, by: \.connectorId).compactMapValues { connectorAttachments in
      let merged = UgotMCPToolSelectionHints.merged(connectorAttachments.map(\.toolHints))
      return merged.isEmpty ? nil : merged
    }
  }

  private static func mcpIntentLine(for intentEffect: String) -> String {
    switch UgotMCPIntentEffect.normalized(intentEffect) {
    case "write":
      return "Intent effect: write."
    case "destructive":
      return "Intent effect: destructive."
    case "none":
      return "Intent effect: none."
    default:
      return "Intent effect: read-only explanation."
    }
  }

  private static func mcpIntentPolicyLine(for intentEffect: String) -> String {
    switch UgotMCPIntentEffect.normalized(intentEffect) {
    case "write":
      return "If this request requires changing connector state, call an appropriate MCP tool through the host approval flow and answer only after observing the tool result. Do not claim the state changed until a tool observation confirms it."
    case "destructive":
      return "If this request requires a destructive connector action, call an appropriate MCP tool only through the host approval flow and answer only after observing the tool result. Do not claim the action completed until a tool observation confirms it."
    case "none":
      return "Do not call a connector tool unless the user adds a new explicit request that requires one."
    default:
      return "If the current answer requires connector data, first call an appropriate read-only MCP tool and answer only after observing the tool result. Do not mutate connector state."
    }
  }

  private static func mcpContextSummary(_ attachments: [UgotMCPContextAttachment]) -> String {
    attachments.map { attachment in
      var header = "## \(attachment.title)"
      header += "\nConnector: \(attachment.connectorTitle)"
      header += "\nType: \(attachment.kind.rawValue)"
      header += "\nIntent effect: \(attachment.intentEffect)"
      if let uri = attachment.uri, !uri.isEmpty {
        header += "\nURI: \(uri)"
      }
      if !attachment.arguments.isEmpty {
        let args = attachment.arguments
          .sorted { $0.key < $1.key }
          .map { "- \($0.key): \($0.value)" }
          .joined(separator: "\n")
        header += "\nArguments:\n\(args)"
      }
      return "\(header)\n\n\(attachment.contextText)"
    }.joined(separator: "\n\n---\n\n")
  }

  private static func mcpArgumentsJSONObjectString(_ arguments: [String: String]) -> String {
    guard !arguments.isEmpty,
          JSONSerialization.isValidJSONObject(arguments),
          let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]),
          let json = String(data: data, encoding: .utf8) else {
      return arguments
        .sorted { $0.key < $1.key }
        .map { "\($0.key)=\($0.value)" }
        .joined(separator: ", ")
    }
    return json
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
    attachmentContext: String,
    mcpContext: String = ""
  ) -> String? {
    let trimmedWidgetContext = widgetContext?.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedAttachmentContext = attachmentContext.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedMCPContext = mcpContext.trimmingCharacters(in: .whitespacesAndNewlines)
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
    if !trimmedMCPContext.isEmpty {
      sections.append("""
      [Current MCP context attachments]
      These prompts/resources were explicitly attached by the user from the MCP menu for this turn. Use them as supporting context; do not describe them as raw tool output.
      \(trimmedMCPContext)
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
      applyAgentTurnEvent(AgentTurnStateMachineKt.agentTurnEventCompactContext())
      appendInlineEvent(.contextOrganizing)
    }

    let compactRequest = GalleryInferenceRequest(
      modelName: sessionState.modelName,
      modelDisplayName: sessionState.modelDisplayName,
      modelFileName: model.modelFileName,
      prompt: plan.compactPrompt,
      route: route,
      thinkingMode: .off,
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
      applyAgentTurnEvent(AgentTurnStateMachineKt.agentTurnEventFinishCompaction())
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
    GalleryConnectorSelectionStore.saveSelectedIds(Set(sessionState.connectorBarState.activeConnectorIds))
    schedulePersistSession(delayNanoseconds: 0)
  }

  private func applyConnectorSelection(_ selectedIds: Set<String>) {
    let updatedConnectors = GalleryConnector.samples
    connectors = updatedConnectors
    let visibleIds = updatedConnectors.map(\.id)
    let sanitizedSelectedIds = selectedIds.intersection(Set(visibleIds))
    let connectorBarState = ConnectorBarState(
      visibleConnectorIds: visibleIds,
      activeConnectorIds: sanitizedSelectedIds
    )
    sessionState = sessionState.doCopy(
      modelName: sessionState.modelName,
      modelDisplayName: sessionState.modelDisplayName,
      taskId: sessionState.taskId,
      modelCapabilities: sessionState.modelCapabilities,
      entryHint: sessionState.entryHint,
      agentSkillState: sessionState.agentSkillState,
      connectorBarState: connectorBarState,
      messages: sessionState.messages,
      draft: sessionState.draft,
      widgetHostState: sessionState.widgetHostState,
      nextMessageIndex: sessionState.nextMessageIndex
    )
    GalleryConnectorSelectionStore.saveSelectedIds(Set(sessionState.connectorBarState.activeConnectorIds))
    schedulePersistSession(delayNanoseconds: 0)
    reloadMCPPrompts()
    prewarmMCPTools()
  }

  private func reloadConnectorRegistry() {
    applyConnectorSelection(Set(sessionState.connectorBarState.activeConnectorIds))
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
      mcpResourceItems = []
      isLoadingMCPPrompts = false
      return
    }

    isLoadingMCPPrompts = true
    let locale = UgotMCPLocale.preferredLanguageTag
    Task {
      var loaded: [UgotMCPPromptDescriptor] = []
      var loadedResources: [UgotMCPResourceDescriptor] = []
      let accessToken = try? await UgotAuthStore.validAccessToken()
      for connector in activeConnectors {
        guard connector.authMode != .ugotBearer || accessToken != nil else { continue }
        guard let endpoint = URL(string: connector.endpoint) else { continue }
        let client = UgotMCPRuntimeClient.make(
          connectorId: connector.id,
          endpoint: endpoint,
          accessToken: accessToken ?? ""
        )
        do {
          try await client.initialize()
          do {
            let prompts = try await client.listPrompts()
            loaded.append(contentsOf: prompts.map { UgotMCPPromptDescriptor(connector: connector, prompt: $0, locale: locale) })
          } catch {
            // Some generic MCP servers do not implement prompts; keep resources visible.
          }
          do {
            let resources = try await client.listResources()
            loadedResources.append(
              contentsOf: resources
                .map { UgotMCPResourceDescriptor(connector: connector, resource: $0, locale: locale) }
                .filter(\.isUserVisible)
            )
          } catch {
            // Resources are optional MCP capability; ignore per-connector failures.
          }
        } catch {
          continue
        }
      }
      await MainActor.run {
        mcpPromptItems = loaded.sorted {
          if $0.connectorTitle != $1.connectorTitle { return $0.connectorTitle < $1.connectorTitle }
          return $0.title < $1.title
        }
        mcpResourceItems = loadedResources.sorted {
          if $0.connectorTitle != $1.connectorTitle { return $0.connectorTitle < $1.connectorTitle }
          return $0.title < $1.title
        }
        isLoadingMCPPrompts = false
      }
    }
  }

  private func applyMCPPrompt(_ prompt: UgotMCPPromptDescriptor) {
    pendingMCPPromptForArguments = PendingMCPPromptArgumentsPresentation(prompt: prompt)
  }

  private func automaticMCPPromptArguments(for prompt: UgotMCPPromptDescriptor) -> [String: String] {
    var arguments: [String: String] = [:]
    let argumentNames = Set(prompt.arguments.map(\.name))
    if UgotMCPIntentEffect.normalized(prompt.intentEffect) == "read",
       argumentNames.contains("target_name"),
       let targetName = Self.currentTargetName(from: currentWidgetModelContext) {
      arguments["target_name"] = targetName
    }
    return arguments
  }

  private static func currentTargetName(from widgetContext: String?) -> String? {
    guard let widgetContext else { return nil }
    let context = widgetContext.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !context.isEmpty else { return nil }

    let patterns = [
      #"(?i)["']targetName["']\s*:\s*["']([^"']{1,80})["']"#,
      #"(?i)["']target_name["']\s*:\s*["']([^"']{1,80})["']"#,
      #"(?im)^\s*[-*]?\s*(?:target|target name|selected target|current target|widget target|daily fortune target|name|대상|현재 대상|선택 대상|이름)\s*[:：]\s*([^\n,()]{1,80})"#,
      #"(?im)^\s*(?:daily_fortune|fortune|saju|chart)\s+for\s+([^\n,()]{1,80})(?:\s+on|\s+for|$)"#,
    ]

    for pattern in patterns {
      if let match = firstRegexCapture(pattern: pattern, in: context),
         let normalized = normalizedPromptTargetName(match) {
        return normalized
      }
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
    return String(text[range])
  }

  private static func normalizedPromptTargetName(_ raw: String) -> String? {
    let trimmed = raw
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`[]{}"))
    guard !trimmed.isEmpty else { return nil }
    let lowercased = trimmed.lowercased()
    let placeholders = [
      "the current target",
      "the current widget target",
      "the current daily fortune target",
      "current target",
      "current widget target",
      "unknown",
      "none",
      "null",
      "n/a",
    ]
    if placeholders.contains(lowercased) { return nil }
    if trimmed.count > 80 { return nil }
    return trimmed
  }

  private func completeMCPPromptArgument(
    _ prompt: UgotMCPPromptDescriptor,
    argumentName: String,
    partialValue: String,
    arguments: [String: String]
  ) async -> UgotMCPPromptCompletionResult {
    do {
      let accessToken = try? await UgotAuthStore.validAccessToken()
      guard let connector = GalleryConnector.connector(for: prompt.connectorId),
            let endpoint = URL(string: connector.endpoint) else {
        return .empty
      }
      guard connector.authMode != .ugotBearer || accessToken != nil else {
        return .empty
      }
      let client = UgotMCPRuntimeClient.make(
        connectorId: connector.id,
        endpoint: endpoint,
        accessToken: accessToken ?? ""
      )
      try await client.initialize()
      return try await client.completePromptArgument(
        promptName: prompt.name,
        argumentName: argumentName,
        partialValue: partialValue,
        arguments: arguments
      )
    } catch {
      return .empty
    }
  }

  private func attachMCPPrompt(_ prompt: UgotMCPPromptDescriptor, arguments: [String: String]) {
    Task {
      var contextText = prompt.summary.isEmpty ? prompt.title : prompt.summary
      var toolHints = prompt.toolHints
      do {
        let accessToken = try? await UgotAuthStore.validAccessToken()
        guard let connector = GalleryConnector.connector(for: prompt.connectorId),
              let endpoint = URL(string: connector.endpoint) else {
          throw NSError(domain: "UgotMCPPrompt", code: 401)
        }
        guard connector.authMode != .ugotBearer || accessToken != nil else {
          throw NSError(domain: "UgotMCPPrompt", code: 401)
        }
        let client = UgotMCPRuntimeClient.make(
          connectorId: connector.id,
          endpoint: endpoint,
          accessToken: accessToken ?? ""
        )
        try await client.initialize()
        let result = try await client.getPrompt(name: prompt.name, arguments: arguments)
        contextText = UgotMCPPromptRenderer.renderPromptText(result, fallbackTitle: prompt.title)
        let resultHints = UgotMCPToolSelectionHints.parse(from: result)
        toolHints = UgotMCPToolSelectionHints.merged([prompt.toolHints, resultHints])
      } catch {
        contextText = prompt.summary.isEmpty ? prompt.title : prompt.summary
      }
      let attachment = UgotMCPContextAttachment(
        kind: .prompt,
        connectorId: prompt.connectorId,
        connectorTitle: prompt.connectorTitle,
        title: prompt.title,
        summary: prompt.summary,
        contextText: contextText,
        arguments: arguments,
        uri: "mcp-prompt:\(prompt.name)",
        intentEffect: prompt.intentEffect,
        toolHints: toolHints
      )
      await MainActor.run {
        mcpContextAttachments.append(attachment)
      }
    }
  }

  private func applyMCPResource(_ resource: UgotMCPResourceDescriptor) {
    Task {
      var contextText = "# \(resource.title)\n\nURI: \(resource.uri)"
      var workspaceStatus: AgentWorkspaceStatus?
      do {
        let accessToken = try? await UgotAuthStore.validAccessToken()
        guard let connector = GalleryConnector.connector(for: resource.connectorId),
              let endpoint = URL(string: connector.endpoint) else {
          throw NSError(domain: "UgotMCPResource", code: 401)
        }
        guard connector.authMode != .ugotBearer || accessToken != nil else {
          throw NSError(domain: "UgotMCPResource", code: 401)
        }
        let client = UgotMCPRuntimeClient.make(
          connectorId: connector.id,
          endpoint: endpoint,
          accessToken: accessToken ?? ""
        )
        try await client.initialize()
        if let result = try await client.readResource(uri: resource.uri) {
          contextText = UgotMCPResourceRenderer.renderResourceText(result, resource: resource)
          let contents = result["contents"] as? [[String: Any]] ?? []
          if !contents.isEmpty {
            let vfsResult: [String: Any] = [
              "content": contents.map { item in
                [
                  "type": "resource",
                  "resource": item,
                ]
              },
            ]
            _ = UgotAgentVFS.shared.ingestMCPResult(
              sessionId: sessionId,
              connectorId: resource.connectorId,
              toolName: "resources/read",
              result: vfsResult,
              persistTextBlocks: false
            )
            workspaceStatus = UgotAgentVFS.shared.workspaceStatus(sessionId: sessionId)
          }
        }
      } catch {
        // Keep the fallback URI context so users can still attach the selected resource.
      }
      let attachment = UgotMCPContextAttachment(
        kind: .resource,
        connectorId: resource.connectorId,
        connectorTitle: resource.connectorTitle,
        title: resource.title,
        summary: resource.summary,
        contextText: contextText,
        arguments: [:],
        uri: resource.uri,
        intentEffect: "read"
      )
      await MainActor.run {
        if let workspaceStatus {
          agentWorkspaceStatus = workspaceStatus
        }
        mcpContextAttachments.append(attachment)
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

  init(activity: AgentTurnActivity) {
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

  static func mcpContextAttached(_ attachments: [UgotMCPContextAttachment]) -> InlineChatEvent {
    let promptCount = attachments.filter { $0.kind == .prompt }.count
    let resourceCount = attachments.filter { $0.kind == .resource }.count
    let compactNames = attachments
      .prefix(3)
      .map(\.displayName)
      .joined(separator: ", ")
    let suffix = attachments.count > 3 ? " 외 \(attachments.count - 3)개" : ""
    let title: String
    if promptCount > 0 && resourceCount > 0 {
      title = "Prompt와 Resource를 첨부했어요"
    } else if promptCount > 0 {
      title = "Prompt를 첨부했어요"
    } else {
      title = "Resource를 첨부했어요"
    }
    return InlineChatEvent(
      symbol: promptCount > 0 ? "text.badge.star" : "doc.richtext",
      title: title,
      detail: "\(compactNames)\(suffix)을 이번 요청의 컨텍스트로 사용할게요."
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

  static func mcpConnectorStatus(_ event: UgotMCPConnectorStatusEvent) -> InlineChatEvent {
    let symbol: String
    let title: String
    switch event.status {
    case .checking:
      symbol = "network"
      title = "\(event.connectorTitle) 연결 확인 중"
    case .ready:
      symbol = "checkmark.circle"
      title = "\(event.connectorTitle) 연결됨"
    case .failed:
      symbol = "exclamationmark.triangle"
      title = "\(event.connectorTitle) 연결 실패"
    }
    return InlineChatEvent(
      symbol: symbol,
      title: title,
      detail: event.detail
    )
  }

  static func mcpConnectorStatusSummary(_ events: [UgotMCPConnectorStatusEvent]) -> InlineChatEvent {
    let ordered = events.sorted { lhs, rhs in
      if lhs.connectorTitle != rhs.connectorTitle { return lhs.connectorTitle < rhs.connectorTitle }
      return lhs.connectorId < rhs.connectorId
    }
    let symbol: String
    if ordered.contains(where: { $0.status == .failed }) {
      symbol = "exclamationmark.triangle"
    } else if !ordered.isEmpty, ordered.allSatisfy({ $0.status == .ready }) {
      symbol = "checkmark.circle"
    } else {
      symbol = "network"
    }
    let detail = ordered
      .map { event -> String in
        let state: String
        switch event.status {
        case .checking: state = "확인 중"
        case .ready: state = "연결됨"
        case .failed: state = "실패"
        }
        return "\(event.connectorTitle) \(state)"
      }
      .joined(separator: " · ")
    return InlineChatEvent(
      symbol: symbol,
      title: "MCP 연결 상태",
      detail: detail
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
  let modelThinkingMode: GalleryModelThinkingMode
  let thinkingText: String

  @State private var isExpanded = false

  var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      VStack(alignment: .leading, spacing: 8) {
        if modelThinkingMode == .on, !thinkingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          AgentThinkingBlock(
            text: thinkingText,
            mode: .compact,
            showsProgress: activity != nil
          )
        }

        if let activity {
          AgentStateDetailRow(
            symbol: activity.symbol,
            title: activity.title,
            detail: "",
            showsProgress: activity.title.contains("중")
          )
        }

        if let compactionStatus {
          AgentStateDetailRow(
            symbol: "archivebox",
            title: "Compact",
            detail: compactionStatus.estimatedTokens.map { "\($0) tokens" } ?? "",
            showsProgress: false
          )
        }

        if !workspaceStatus.isEmpty {
          AgentStateDetailRow(
            symbol: "folder.badge.gearshape",
            title: "Workspace",
            detail: "\(workspaceStatus.fileCount) files",
            showsProgress: false
          )
        }

        if !activeSkillTitles.isEmpty || !activeConnectorTitles.isEmpty {
          AgentStateDetailRow(
            symbol: "switch.2",
            title: "Tools",
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
        Text("Trace")
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
          AgentStateChip(title: modelThinkingMode == .on ? "thinking" : "fast", symbol: modelThinkingMode == .on ? "brain.head.profile" : "bolt")
          if toolCount > 0 {
            AgentStateChip(title: "\(toolCount) tools", symbol: "switch.2")
          }
        }
      }
      .contentShape(Rectangle())
    }
    .font(.caption)
    .padding(8)
    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
  }

  private var activeToolDetail: String {
    var parts: [String] = []
    if !activeSkillTitles.isEmpty {
      parts.append(activeSkillTitles.joined(separator: ", "))
    }
    if !activeConnectorTitles.isEmpty {
      parts.append(activeConnectorTitles.joined(separator: ", "))
    }
    return parts.joined(separator: "\n")
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
        if !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          Text(detail)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
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
    let displayText: String
    if message.role == .user {
      displayText = UserMCPContextAttachmentEnvelope.promptText(message.text)
    } else {
      displayText = AssistantThinkingEnvelope.displayContent(message.text)
    }
    return "\(message.role.promptLabel): \(displayText.trimmedMiddleForPrompt(limit: limit))"
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
      .map { "\($0.role.promptLabel): \(AssistantThinkingEnvelope.displayContent($0.text))" }
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
    let text = AssistantThinkingEnvelope.displayContent(message.text).trimmingCharacters(in: .whitespacesAndNewlines)
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
    let displayText: String
    if message.role == .user {
      displayText = UserMCPContextAttachmentEnvelope.promptText(message.text)
    } else {
      displayText = AssistantThinkingEnvelope.displayContent(message.text)
    }
    return "\(message.role.promptLabel): \(displayText.oneLineForPrompt(limit: limit))"
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

private struct AssistantMessageDisplayParts {
  let thinking: String?
  let content: String
}

private enum AssistantThinkingEnvelope {
  private static let marker = "[UGOT_ASSISTANT_THINKING_V1]"
  private static let contentMarker = "[UGOT_ASSISTANT_CONTENT]"

  static func wrap(content: String, thinking: String) -> String {
    let trimmedThinking = thinking.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedThinking.isEmpty else { return content }
    let payload: [String: Any] = [
      "schema": 1,
      "type": "thinking",
      "thinking": trimmedThinking,
    ]
    let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
    let json = String(data: data, encoding: .utf8) ?? "{}"
    return "\(marker)\n\(json)\n\(contentMarker)\n\(content)"
  }

  static func parse(_ text: String) -> AssistantMessageDisplayParts {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix(marker), let markerRange = text.range(of: contentMarker) else {
      return AssistantMessageDisplayParts(thinking: nil, content: text)
    }
    let header = text[..<markerRange.lowerBound]
    let jsonText = header
      .replacingOccurrences(of: marker, with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let contentStart = markerRange.upperBound
    let content = String(text[contentStart...])
      .trimmingCharacters(in: CharacterSet.newlines)
    guard let data = jsonText.data(using: .utf8),
          let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let thinking = payload["thinking"] as? String,
          !thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return AssistantMessageDisplayParts(thinking: nil, content: content)
    }
    return AssistantMessageDisplayParts(thinking: thinking, content: content)
  }

  static func displayContent(_ text: String) -> String {
    parse(text).content
  }
}

private struct AgentThinkingBlock: View {
  let text: String
  let mode: ThinkingDisplayMode
  let showsProgress: Bool
  @State private var isExpanded = true

  var body: some View {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if mode == .compact {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        if showsProgress {
          ProgressView().controlSize(.mini)
        } else {
          Image(systemName: "brain.head.profile")
            .font(.caption2.weight(.semibold))
          .foregroundStyle(Color.accentColor)
        }
        Text("Trace")
          .font(.caption.weight(.semibold))
          .foregroundStyle(Color.accentColor)
        Text(trimmed.oneLineForPrompt(limit: 90))
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      .padding(8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    } else {
      DisclosureGroup(isExpanded: $isExpanded) {
        Text(trimmed)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.top, 6)
      } label: {
        HStack(spacing: 6) {
          if showsProgress {
            ProgressView().controlSize(.mini)
          } else {
            Image(systemName: "brain.head.profile")
              .foregroundStyle(Color.accentColor)
          }
          Text("Trace")
            .font(.caption.weight(.semibold))
          Spacer(minLength: 8)
        }
      }
      .font(.caption)
      .padding(9)
      .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
  }
}

private struct UserMCPContextAttachmentEnvelope {
  private static let marker = "[UGOT_USER_MCP_CONTEXT_V1]"

  struct Item: Identifiable, Hashable {
    let index: Int
    let kind: String
    let symbol: String
    let title: String
    let connectorTitle: String
    let connectorId: String
    let summary: String
    let contextText: String
    let arguments: [String: String]
    let uri: String?
    let intentEffect: String
    let toolHints: UgotMCPToolSelectionHints

    var id: String { "\(index)::\(kind)::\(connectorTitle)::\(title)" }
    var kindLabel: String { kind == "prompt" ? "Prompt" : "Resource" }

    var contextAttachment: UgotMCPContextAttachment {
      UgotMCPContextAttachment(
        kind: kind == "prompt" ? .prompt : .resource,
        connectorId: connectorId,
        connectorTitle: connectorTitle,
        title: title,
        summary: summary,
        contextText: contextText,
        arguments: arguments,
        uri: uri,
        intentEffect: intentEffect,
        toolHints: toolHints
      )
    }
  }

  let text: String
  let items: [Item]

  static func persistedText(_ attachments: [UgotMCPContextAttachment]) -> String {
    let items = attachments.enumerated().map { index, attachment in
      [
        "index": index,
        "kind": attachment.kind.rawValue,
        "symbol": attachment.symbol,
        "title": attachment.displayName,
        "connectorTitle": attachment.connectorTitle,
        "connectorId": attachment.connectorId,
        "summary": attachment.summary,
        "contextText": attachment.contextText.trimmedMiddleForPrompt(limit: 8_000),
        "arguments": attachment.arguments,
        "uri": attachment.uri ?? "",
        "intentEffect": attachment.intentEffect,
        "toolHints": attachment.toolHints.asJSONObject,
      ] as [String: Any]
    }
    let payload: [String: Any] = [
      "schema": 1,
      "items": items,
    ]
    let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
    let json = String(data: data, encoding: .utf8) ?? "{}"
    return "\(marker)\n\(json)"
  }

  static func parse(_ rawText: String) -> UserMCPContextAttachmentEnvelope {
    guard let markerRange = rawText.range(of: marker) else {
      return UserMCPContextAttachmentEnvelope(
        text: rawText.trimmingCharacters(in: .whitespacesAndNewlines),
        items: []
      )
    }

    let visibleText = String(rawText[..<markerRange.lowerBound])
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let jsonText = String(rawText[markerRange.upperBound...])
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = jsonText.data(using: .utf8),
          let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let rawItems = payload["items"] as? [[String: Any]] else {
      return UserMCPContextAttachmentEnvelope(text: visibleText, items: [])
    }
    let items = rawItems.enumerated().compactMap { fallbackIndex, raw -> Item? in
      guard let kind = raw["kind"] as? String,
            let symbol = raw["symbol"] as? String,
            let title = raw["title"] as? String,
            let connectorTitle = raw["connectorTitle"] as? String else {
        return nil
      }
      let arguments = raw["arguments"] as? [String: String] ?? [:]
      let rawURI = (raw["uri"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let rawIntentEffect = (raw["intentEffect"] as? String) ?? (raw["intent_effect"] as? String)
      let toolHints = UgotMCPToolSelectionHints.parse(from: raw)
      return Item(
        index: (raw["index"] as? Int) ?? fallbackIndex,
        kind: kind,
        symbol: symbol,
        title: title,
        connectorTitle: connectorTitle,
        connectorId: (raw["connectorId"] as? String) ?? "",
        summary: (raw["summary"] as? String) ?? "",
        contextText: (raw["contextText"] as? String) ?? "",
        arguments: arguments,
        uri: rawURI.isEmpty ? nil : rawURI,
        intentEffect: UgotMCPIntentEffect.normalized(
          rawIntentEffect,
          default: "read"
        ),
        toolHints: toolHints
      )
    }
    return UserMCPContextAttachmentEnvelope(text: visibleText, items: items)
  }

  static func promptText(_ rawText: String) -> String {
    let parsed = parse(rawText)
    guard !parsed.items.isEmpty else { return parsed.text }
    let attachmentSummary = parsed.items
      .map { "\($0.kindLabel): \($0.title) (\($0.connectorTitle))" }
      .joined(separator: ", ")
    if parsed.text.isEmpty {
      return "Attached MCP context: \(attachmentSummary)"
    }
    return "\(parsed.text)\nAttached MCP context: \(attachmentSummary)"
  }
}

private struct SentMCPContextAttachmentChip: View {
  let item: UserMCPContextAttachmentEnvelope.Item
  let onPreview: () -> Void

  var body: some View {
    Button(action: onPreview) {
      HStack(spacing: 6) {
        Image(systemName: item.symbol)
        Text(item.title)
          .lineLimit(1)
        Text(item.kindLabel)
          .font(.caption2.weight(.bold))
          .opacity(0.72)
        Image(systemName: "chevron.up.forward")
          .font(.caption2.weight(.bold))
          .opacity(0.65)
      }
    }
    .buttonStyle(.plain)
    .font(.caption.weight(.semibold))
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .foregroundStyle(.white)
    .background(Color.white.opacity(0.16), in: Capsule())
    .overlay(Capsule().stroke(Color.white.opacity(0.24)))
  }
}

private struct MessageBubble: View {
  let message: UnifiedChatMessage
  @State private var previewedMCPContextAttachment: UgotMCPContextAttachment?

  @ViewBuilder
  var body: some View {
    if let transcript = UgotAgentToolTranscript(message: message) {
      ToolObservationEventRow(transcript: transcript)
    } else if let event = InlineChatEvent(message: message) {
      InlineChatEventRow(event: event)
    } else {
      HStack {
        if message.role == .user { Spacer(minLength: 40) }
        VStack(alignment: .leading, spacing: 8) {
          if message.role == .assistant {
            AssistantMarkdownText(text: AssistantThinkingEnvelope.displayContent(message.text))
              .font(.body)
              .textSelection(.enabled)
          } else {
            let userInput = UserMCPContextAttachmentEnvelope.parse(message.text)
            if !userInput.text.isEmpty {
              Text(userInput.text)
                .font(.body)
                .textSelection(.enabled)
            }
            if !userInput.items.isEmpty {
              HStack(spacing: 7) {
                ForEach(userInput.items) { item in
                  SentMCPContextAttachmentChip(
                    item: item,
                    onPreview: { previewedMCPContextAttachment = item.contextAttachment }
                  )
                }
              }
            }
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
      .sheet(item: $previewedMCPContextAttachment) { attachment in
        MCPContextAttachmentPreviewSheet(attachment: attachment)
          .presentationDetents([.medium, .large])
      }
    }
  }
}

private struct ToolObservationEventRow: View {
  let transcript: UgotAgentToolTranscript
  @State private var isExpanded = false

  var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      VStack(alignment: .leading, spacing: 8) {
        metadataLine(title: "Connector", value: transcript.connectorTitle)
        metadataLine(title: "Tool", value: transcript.toolName, monospaced: true)
        if !cleanArguments.isEmpty {
          metadataBlock(title: "Input", value: cleanArguments)
        }
        if !cleanOutput.isEmpty {
          metadataBlock(title: "Output", value: cleanOutput)
        }
        let links = outputLinks
        if !links.isEmpty {
          VStack(alignment: .leading, spacing: 6) {
            Text("Links")
              .font(.caption2.weight(.semibold))
              .foregroundStyle(.tertiary)
            ForEach(Array(links.prefix(3)), id: \.absoluteString) { url in
              Link(destination: url) {
                HStack(spacing: 6) {
                  Image(systemName: "safari")
                  Text("링크 열기")
                    .fontWeight(.semibold)
                  Text(url.host ?? url.absoluteString)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                  Spacer(minLength: 0)
                }
                .font(.caption2)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
              }
            }
          }
        }
      }
      .padding(.top, 6)
    } label: {
      HStack(spacing: 7) {
        Image(systemName: iconName)
          .font(.caption.weight(.semibold))
          .foregroundStyle(statusColor)
        Text(displayTitle)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Text(statusTitle)
          .font(.caption2.weight(.semibold))
          .foregroundStyle(statusColor)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(statusColor.opacity(0.10), in: Capsule())
        if !transcript.hasWidget {
          Text("data-only")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
        }
        Spacer(minLength: 0)
      }
    }
    .font(.caption)
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(Color(.secondarySystemGroupedBackground).opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .accessibilityElement(children: .combine)
  }

  private var displayTitle: String {
    let title = transcript.toolTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    if !title.isEmpty,
       !title.lowercased().contains("mcp"),
       !title.lowercased().contains("tool") {
      return title
    }
    return transcript.toolName
      .replacingOccurrences(of: "_", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var iconName: String {
    if transcript.status != "success" { return "exclamationmark.triangle" }
    if transcript.hasWidget { return "rectangle.on.rectangle" }
    return transcript.didMutate ? "checkmark.shield" : "wrench.and.screwdriver"
  }

  private var statusTitle: String {
    switch transcript.status {
    case "success": return "완료"
    case "blocked": return "중단"
    default: return transcript.status
    }
  }

  private var statusColor: Color {
    switch transcript.status {
    case "success": return .green
    case "blocked": return .orange
    default: return .orange
    }
  }

  private var cleanArguments: String {
    transcript.argumentsPreview
      .trimmingCharacters(in: CharacterSet(charactersIn: "`").union(.whitespacesAndNewlines))
  }

  private var cleanOutput: String {
    transcript.outputText
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmedMiddleForPrompt(limit: 1_200)
  }

  private var outputLinks: [URL] {
    ExternalURLExtractor.urls(in: transcript.outputText)
  }

  @ViewBuilder
  private func metadataLine(title: String, value: String, monospaced: Bool = false) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Text(title)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.tertiary)
      Text(value)
        .font(monospaced ? .caption2.monospaced() : .caption2)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
      Spacer(minLength: 0)
    }
  }

  @ViewBuilder
  private func metadataBlock(title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.tertiary)
      Text(value)
        .font(.caption2.monospaced())
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

private enum ExternalURLExtractor {
  static func urls(in text: String) -> [URL] {
    guard let regex = try? NSRegularExpression(pattern: #"https?://[^\s<>"'`]+"#) else {
      return []
    }
    var seen = Set<String>()
    let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
    let trailingPunctuation: Set<Character> = [".", ",", ";", ")", "]", "}", ">", "…"]
    return regex.matches(in: text, range: nsRange).compactMap { match -> URL? in
      guard let range = Range(match.range, in: text) else { return nil }
      var raw = String(text[range])
      while let last = raw.last, trailingPunctuation.contains(last) {
        raw.removeLast()
      }
      guard let url = URL(string: raw),
            let scheme = url.scheme?.lowercased(),
            ["http", "https"].contains(scheme),
            url.host?.isEmpty == false,
            seen.insert(url.absoluteString).inserted else {
        return nil
      }
      return url
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
  let modelThinkingMode: GalleryModelThinkingMode

  var body: some View {
    HStack(alignment: .bottom, spacing: 8) {
      VStack(alignment: .leading, spacing: 8) {
        if text.isEmpty {
          HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(modelThinkingMode == .on ? "Thinking…" : "Working…")
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

private struct MCPContextAttachmentChip: View {
  let attachment: UgotMCPContextAttachment
  let onPreview: () -> Void
  let onRemove: () -> Void

  var body: some View {
    HStack(spacing: 6) {
      Button(action: onPreview) {
        HStack(spacing: 6) {
          Image(systemName: attachment.symbol)
          Text(attachment.displayName)
            .lineLimit(1)
          Text(attachment.kind == .prompt ? "Prompt" : "Resource")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.secondary)
          Image(systemName: "chevron.up.forward")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.secondary)
        }
      }
      .buttonStyle(.plain)
      Button(action: onRemove) {
        Image(systemName: "xmark.circle.fill")
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
    }
    .font(.caption.weight(.semibold))
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(Color.accentColor.opacity(0.10), in: Capsule())
    .contentShape(Capsule())
    .accessibilityLabel("Open MCP context attachment")
  }
}

private struct MCPContextAttachmentPreviewSheet: View {
  let attachment: UgotMCPContextAttachment
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          VStack(alignment: .leading, spacing: 6) {
            Label(attachment.connectorTitle, systemImage: attachment.symbol)
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
            Text(attachment.title)
              .font(.headline)
            if !attachment.summary.isEmpty {
              Text(attachment.summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
          }

          VStack(alignment: .leading, spacing: 8) {
            MCPPreviewMetaRow(title: "Type", value: attachment.kind == .prompt ? "Prompt" : "Resource")
            if let uri = attachment.uri, !uri.isEmpty {
              MCPPreviewMetaRow(title: "URI", value: uri)
            }
            if !attachment.arguments.isEmpty {
              VStack(alignment: .leading, spacing: 6) {
                Text("Arguments")
                  .font(.caption.weight(.semibold))
                  .foregroundStyle(.secondary)
                ForEach(attachment.arguments.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                  MCPPreviewMetaRow(title: key, value: value)
                }
              }
            }
          }
          .padding(12)
          .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

          VStack(alignment: .leading, spacing: 8) {
            Text("Context")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
            AssistantMarkdownText(text: attachment.contextText)
              .font(.body)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
      }
      .navigationTitle("MCP 첨부 내용")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("닫기") { dismiss() }
        }
      }
    }
  }
}

private struct MCPPreviewMetaRow: View {
  let title: String
  let value: String

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .frame(width: 72, alignment: .leading)
      Text(value)
        .font(.caption)
        .textSelection(.enabled)
      Spacer(minLength: 0)
    }
  }
}

private struct PendingMCPPromptArgumentsPresentation: Identifiable, Hashable {
  let id = UUID()
  let prompt: UgotMCPPromptDescriptor
}

private struct MCPPromptArgumentsSheet: View {
  private struct Choice: Hashable, Identifiable {
    let label: String
    let value: String
    var id: String { value }
  }

  let prompt: UgotMCPPromptDescriptor
  let automaticArguments: [String: String]
  let onCancel: () -> Void
  let onAttach: ([String: String]) -> Void
  let onCompleteArgument: (UgotMCPPromptDescriptor, String, String, [String: String]) async -> UgotMCPPromptCompletionResult

  @State private var values: [String: String]
  @State private var completionChoices: [String: [Choice]] = [:]
  @State private var completionResults: [String: UgotMCPPromptCompletionResult] = [:]
  @State private var completionSearchText: [String: String] = [:]
  @State private var loadingCompletionNames: Set<String> = []
  @State private var completedCompletionNames: Set<String> = []

  init(
    prompt: UgotMCPPromptDescriptor,
    automaticArguments: [String: String] = [:],
    onCancel: @escaping () -> Void,
    onAttach: @escaping ([String: String]) -> Void,
    onCompleteArgument: @escaping (UgotMCPPromptDescriptor, String, String, [String: String]) async -> UgotMCPPromptCompletionResult
  ) {
    self.prompt = prompt
    self.automaticArguments = automaticArguments
    self.onCancel = onCancel
    self.onAttach = onAttach
    self.onCompleteArgument = onCompleteArgument
    _values = State(initialValue: Self.defaultValues(for: prompt, automaticArguments: automaticArguments))
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          VStack(alignment: .leading, spacing: 6) {
            Label(prompt.connectorTitle, systemImage: prompt.connectorSymbol)
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
            Text(prompt.title)
              .font(.headline)
            if !prompt.summary.isEmpty {
              Text(prompt.summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
          }
          .padding(.vertical, 4)
        }

        if visibleArguments.isEmpty {
          Section("옵션") {
            Label("언어와 현재 위젯 대상은 자동으로 적용돼요", systemImage: "checkmark.circle")
              .foregroundStyle(.secondary)
          }
        } else {
          Section("옵션") {
            ForEach(visibleArguments) { argument in
              argumentInput(argument)
            }
          }
        }
      }
      .navigationTitle("Prompt 첨부")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("취소", action: onCancel)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("첨부") {
            onAttach(cleanedValues)
          }
          .disabled(!canAttach)
        }
      }
      .task(id: prompt.id) {
        await loadCompletionChoices()
      }
    }
  }

  @ViewBuilder
  private func argumentInput(_ argument: UgotMCPPromptArgumentDescriptor) -> some View {
    if shouldLoadCompletion(for: argument),
       (loadingCompletionNames.contains(argument.name) ||
         completedCompletionNames.contains(argument.name) ||
         completionChoices[argument.name] != nil) {
      completionArgumentInput(argument, choices: completionChoices[argument.name] ?? [])
    } else if let choices = choices(for: argument.name) {
      Picker(argumentTitle(argument), selection: binding(for: argument.name)) {
        ForEach(choices) { choice in
          Text(choice.label).tag(choice.value)
        }
      }
    } else if isBooleanArgument(argument.name) {
      Toggle(argumentTitle(argument), isOn: boolBinding(for: argument.name))
    } else {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 6) {
          Text(argumentTitle(argument))
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
          if argument.isRequired {
            Text("필수")
              .font(.caption2.weight(.bold))
              .foregroundStyle(.orange)
          }
        }
        TextField(argumentTitle(argument), text: binding(for: argument.name), axis: .vertical)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        if !argument.summary.isEmpty {
          Text(argument.summary)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .padding(.vertical, 4)
    }
  }

  @ViewBuilder
  private func completionArgumentInput(
    _ argument: UgotMCPPromptArgumentDescriptor,
    choices: [Choice]
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 6) {
        Text(argumentTitle(argument))
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        if argument.isRequired {
          Text("필수")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.orange)
        }
        if loadingCompletionNames.contains(argument.name) {
          ProgressView()
            .controlSize(.small)
        }
      }

      HStack(spacing: 8) {
        TextField("대상 검색", text: completionSearchBinding(for: argument.name))
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .textFieldStyle(.roundedBorder)
          .onSubmit {
            Task { await reloadCompletionChoices(for: argument) }
          }
        Button("검색") {
          Task { await reloadCompletionChoices(for: argument) }
        }
        .disabled(loadingCompletionNames.contains(argument.name))
      }

      if choices.isEmpty {
        if loadingCompletionNames.contains(argument.name) {
          loadingArgumentInput(argument)
        } else {
          TextField(argumentTitle(argument), text: binding(for: argument.name))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        }
      } else if isMultiSelectArgument(argument.name) {
        multiSelectInput(argument, choices: choices, showHeader: false)
      } else {
        singleSelectInput(argument, choices: choices)
      }

      if let result = completionResults[argument.name], result.hasMore {
        Text("더 많은 대상이 있어요. 검색어를 입력해 목록을 좁혀보세요.")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else if !argument.summary.isEmpty {
        Text(argument.summary)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 4)
  }

  @ViewBuilder
  private func singleSelectInput(
    _ argument: UgotMCPPromptArgumentDescriptor,
    choices: [Choice]
  ) -> some View {
    let selected = (values[argument.name] ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    VStack(alignment: .leading, spacing: 4) {
      ForEach(choices) { choice in
        Button {
          values[argument.name] = choice.value
        } label: {
          HStack(spacing: 10) {
            Text(choice.label)
              .foregroundStyle(.primary)
              .frame(maxWidth: .infinity, alignment: .leading)
            if selected.caseInsensitiveCompare(choice.value) == .orderedSame {
              Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.accentColor)
            } else {
              Image(systemName: "circle")
                .foregroundStyle(.tertiary)
            }
          }
          .contentShape(Rectangle())
          .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        if choice.id != choices.last?.id {
          Divider()
        }
      }
    }
  }

  @ViewBuilder
  private func loadingArgumentInput(_ argument: UgotMCPPromptArgumentDescriptor) -> some View {
    HStack(spacing: 10) {
      ProgressView()
      VStack(alignment: .leading, spacing: 2) {
        Text(argumentTitle(argument))
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Text("선택 가능한 대상을 불러오는 중")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 6)
  }

  @ViewBuilder
  private func multiSelectInput(
    _ argument: UgotMCPPromptArgumentDescriptor,
    choices: [Choice],
    showHeader: Bool = true
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      if showHeader {
        HStack(spacing: 6) {
          Text(argumentTitle(argument))
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
          if argument.isRequired {
            Text("필수")
              .font(.caption2.weight(.bold))
              .foregroundStyle(.orange)
          }
        }
      }
      ForEach(choices) { choice in
        Toggle(choice.label, isOn: multiSelectBinding(for: argument.name, value: choice.value))
      }
      if !argument.summary.isEmpty {
        Text(argument.summary)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 4)
  }

  private var visibleArguments: [UgotMCPPromptArgumentDescriptor] {
    prompt.arguments.filter { !isSystemArgument($0) }
  }

  private var cleanedValues: [String: String] {
    values.reduce(into: [String: String]()) { result, pair in
      let value = pair.value.trimmingCharacters(in: .whitespacesAndNewlines)
      if !value.isEmpty {
        result[pair.key] = value
      }
    }
  }

  private var canAttach: Bool {
    visibleArguments.allSatisfy { argument in
      !argument.isRequired || !(values[argument.name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }

  private func binding(for name: String) -> Binding<String> {
    Binding(
      get: { values[name] ?? defaultValue(for: name) },
      set: { values[name] = $0 }
    )
  }

  private func completionSearchBinding(for name: String) -> Binding<String> {
    Binding(
      get: { completionSearchText[name] ?? "" },
      set: { completionSearchText[name] = $0 }
    )
  }

  private func boolBinding(for name: String) -> Binding<Bool> {
    Binding(
      get: { (values[name] ?? defaultValue(for: name)).lowercased() != "false" },
      set: { values[name] = $0 ? "true" : "false" }
    )
  }

  private func multiSelectBinding(for name: String, value: String) -> Binding<Bool> {
    Binding(
      get: { selectedValues(for: name).contains(value) },
      set: { isOn in
        var selected = selectedValues(for: name)
        if isOn {
          selected.append(value)
        } else {
          selected.removeAll { $0 == value }
        }
        let deduped = selected.reduce(into: [String]()) { result, item in
          if !result.contains(item) { result.append(item) }
        }
        values[name] = deduped.joined(separator: ", ")
      }
    )
  }

  private func selectedValues(for name: String) -> [String] {
    (values[name] ?? "")
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  private func argumentTitle(_ argument: UgotMCPPromptArgumentDescriptor) -> String {
    switch argument.name {
    case "tone": return "톤"
    case "focus": return "초점"
    case "context": return "맥락"
    case "members": return "대상"
    case "target_name": return "대상"
    case "include_examples": return "예시 포함"
    default:
      return argument.name.replacingOccurrences(of: "_", with: " ").capitalized
    }
  }

  private func isSystemArgument(_ argument: UgotMCPPromptArgumentDescriptor) -> Bool {
    let name = argument.name.lowercased()
    if ["language", "locale", "openai/locale"].contains(name) {
      return true
    }
    if name == "target_name" {
      return false
    }
    if name.contains("target") && argument.summary.localizedCaseInsensitiveContains("widget") && hasAutomaticArgument(for: argument.name) {
      return true
    }
    return false
  }

  private func hasAutomaticArgument(for name: String) -> Bool {
    !(automaticArguments[name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func isBooleanArgument(_ name: String) -> Bool {
    ["include_examples"].contains(name.lowercased()) || name.lowercased().hasPrefix("include_")
  }

  private func isMultiSelectArgument(_ name: String) -> Bool {
    let lowercased = name.lowercased()
    return ["members", "member_names", "participants", "people", "targets"].contains(lowercased) ||
      lowercased.hasSuffix("_members") ||
      lowercased.hasSuffix("_names")
  }

  private func shouldLoadCompletion(for argument: UgotMCPPromptArgumentDescriptor) -> Bool {
    if isBooleanArgument(argument.name) { return false }
    if choices(for: argument.name) != nil { return false }
    return true
  }

  @MainActor
  private func loadCompletionChoices() async {
    let arguments = visibleArguments.filter(shouldLoadCompletion(for:))
    guard !arguments.isEmpty else { return }

    for argument in arguments {
      await reloadCompletionChoices(for: argument)
    }
  }

  @MainActor
  private func reloadCompletionChoices(for argument: UgotMCPPromptArgumentDescriptor) async {
    let name = argument.name
    loadingCompletionNames.insert(name)
    let partialValue = completionSearchText[name]?.trimmingCharacters(in: .whitespacesAndNewlines)
    let result = await onCompleteArgument(
      prompt,
      name,
      partialValue ?? "",
      cleanedValues
    )
    let mappedChoices = stableCompletionChoices(
      result.values,
      selectedValue: values[name] ?? defaultValue(for: name)
    )
    if shouldUseFirstCompletionAsInitialValue(argument, choices: mappedChoices) {
      values[name] = mappedChoices[0].value
    }
    completionResults[name] = result
    completionChoices[name] = mappedChoices
    completedCompletionNames.insert(name)
    loadingCompletionNames.remove(name)
  }

  private func shouldUseFirstCompletionAsInitialValue(
    _ argument: UgotMCPPromptArgumentDescriptor,
    choices: [Choice]
  ) -> Bool {
    guard !isMultiSelectArgument(argument.name),
          !choices.isEmpty else {
      return false
    }
    let current = (values[argument.name] ?? defaultValue(for: argument.name))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let searchText = (completionSearchText[argument.name] ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return current.isEmpty && searchText.isEmpty
  }

  private func stableCompletionChoices(
    _ values: [String],
    selectedValue: String
  ) -> [Choice] {
    let selected = selectedValue.trimmingCharacters(in: .whitespacesAndNewlines)
    var seen = Set<String>()
    var choices = values.compactMap { raw -> Choice? in
      let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !value.isEmpty else { return nil }
      let key = value.lowercased()
      guard seen.insert(key).inserted else { return nil }
      return Choice(label: value, value: value)
    }
    if !selected.isEmpty {
      let key = selected.lowercased()
      if seen.insert(key).inserted {
        choices.append(Choice(label: selected, value: selected))
      }
    }
    return choices
  }

  private func choices(for name: String) -> [Choice]? {
    switch name.lowercased() {
    case "tone":
      return [
        Choice(label: "실용적", value: "practical"),
        Choice(label: "따뜻하게", value: "warm"),
        Choice(label: "간결하게", value: "concise"),
        Choice(label: "자세히", value: "detailed"),
      ]
    case "focus":
      return [
        Choice(label: "전체", value: "overall"),
        Choice(label: "직업", value: "career"),
        Choice(label: "관계", value: "relationship"),
        Choice(label: "건강", value: "health"),
        Choice(label: "시기", value: "timing"),
      ]
    case "context":
      return [
        Choice(label: "관계", value: "relationship"),
        Choice(label: "팀워크", value: "teamwork"),
        Choice(label: "가족", value: "family"),
      ]
    default:
      return nil
    }
  }

  private func defaultValue(for name: String) -> String {
    switch name.lowercased() {
    case "language", "locale", "openai/locale":
      return UgotMCPLocale.preferredLanguageTag.split(separator: "-").first.map(String.init) ?? UgotMCPLocale.preferredLanguageTag
    case "tone": return "practical"
    case "focus": return "overall"
    case "context": return "relationship"
    case "include_examples": return "true"
    default: return ""
    }
  }

  private static func defaultValues(
    for prompt: UgotMCPPromptDescriptor,
    automaticArguments: [String: String] = [:]
  ) -> [String: String] {
    var values: [String: String] = [:]
    for argument in prompt.arguments {
      let lowercased = argument.name.lowercased()
      switch lowercased {
      case "language", "locale", "openai/locale":
        values[argument.name] = UgotMCPLocale.preferredLanguageTag.split(separator: "-").first.map(String.init) ?? UgotMCPLocale.preferredLanguageTag
      case "tone":
        values[argument.name] = "practical"
      case "focus":
        values[argument.name] = "overall"
      case "context":
        values[argument.name] = "relationship"
      case "include_examples":
        values[argument.name] = "true"
      default:
        values[argument.name] = ""
      }
    }
    for (key, value) in automaticArguments {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty {
        values[key] = trimmed
      }
    }
    return values
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
  let mcpResourceItems: [UgotMCPResourceDescriptor]
  @Binding var mcpContextAttachments: [UgotMCPContextAttachment]
  let isLoadingMCPPrompts: Bool
  let onRecordAudio: () -> Void
  let onVoiceInput: () -> Void
  let onSelectMCPPrompt: (UgotMCPPromptDescriptor) -> Void
  let onSelectMCPResource: (UgotMCPResourceDescriptor) -> Void
  let onSend: (String) -> Void

  @State private var draft: String
  @State private var previewedMCPContextAttachment: UgotMCPContextAttachment?
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
    mcpResourceItems: [UgotMCPResourceDescriptor],
    mcpContextAttachments: Binding<[UgotMCPContextAttachment]>,
    isLoadingMCPPrompts: Bool,
    onRecordAudio: @escaping () -> Void,
    onVoiceInput: @escaping () -> Void,
    onSelectMCPPrompt: @escaping (UgotMCPPromptDescriptor) -> Void,
    onSelectMCPResource: @escaping (UgotMCPResourceDescriptor) -> Void,
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
    self.mcpResourceItems = mcpResourceItems
    _mcpContextAttachments = mcpContextAttachments
    self.isLoadingMCPPrompts = isLoadingMCPPrompts
    self.onRecordAudio = onRecordAudio
    self.onVoiceInput = onVoiceInput
    self.onSelectMCPPrompt = onSelectMCPPrompt
    self.onSelectMCPResource = onSelectMCPResource
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
    .sheet(item: $previewedMCPContextAttachment) { attachment in
      MCPContextAttachmentPreviewSheet(attachment: attachment)
        .presentationDetents([.medium, .large])
    }
  }

  private var canSend: Bool {
    !isGenerating && (
      !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !attachments.isEmpty ||
        !mcpContextAttachments.isEmpty
    )
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
    if !attachments.isEmpty || !mcpContextAttachments.isEmpty {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          ForEach(attachments) { attachment in
            AttachmentChip(attachment: attachment) {
              attachments.removeAll { $0.id == attachment.id }
            }
          }
          ForEach(mcpContextAttachments) { attachment in
            MCPContextAttachmentChip(
              attachment: attachment,
              onPreview: { previewedMCPContextAttachment = attachment },
              onRemove: { mcpContextAttachments.removeAll { $0.id == attachment.id } }
            )
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
      if isLoadingMCPPrompts && mcpPromptItems.isEmpty && mcpResourceItems.isEmpty {
        Label("MCP 항목 불러오는 중", systemImage: "hourglass")
      } else if mcpPromptItems.isEmpty && mcpResourceItems.isEmpty {
        Label("사용 가능한 MCP 항목 없음", systemImage: "text.badge.xmark")
      } else {
        ForEach(groupedPromptConnectors, id: \.connectorId) { group in
          Section("\(group.connectorTitle) · 프롬프트") {
            ForEach(group.items) { item in
              Button {
                onSelectMCPPrompt(item)
              } label: {
                Label(item.title, systemImage: "text.badge.star")
              }
            }
          }
        }
        ForEach(groupedResourceConnectors, id: \.connectorId) { group in
          Section("\(group.connectorTitle) · 리소스") {
            ForEach(group.items) { item in
              Button {
                onSelectMCPResource(item)
              } label: {
                Label(item.title, systemImage: resourceSymbol(for: item))
              }
            }
          }
        }
      }
    } label: {
      Image(systemName: isLoadingMCPPrompts ? "square.stack.3d.up.badge.clock" : "square.stack.3d.up")
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(mcpPromptItems.isEmpty && mcpResourceItems.isEmpty && !isLoadingMCPPrompts ? Color.secondary : Color.accentColor)
        .frame(width: 32, height: 32)
        .background(Color(.tertiarySystemFill), in: Circle())
    }
    .accessibilityLabel("MCP prompts and resources")
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

  private var groupedResourceConnectors: [ResourceConnectorGroup] {
    Dictionary(grouping: mcpResourceItems, by: \.connectorId)
      .compactMap { connectorId, items -> ResourceConnectorGroup? in
        guard let first = items.first else { return nil }
        return ResourceConnectorGroup(
          connectorId: connectorId,
          connectorTitle: first.connectorTitle,
          items: items.sorted { $0.title < $1.title }
        )
      }
      .sorted { $0.connectorTitle < $1.connectorTitle }
  }

  private func resourceSymbol(for item: UgotMCPResourceDescriptor) -> String {
    let mimeType = (item.mimeType ?? "").lowercased()
    if mimeType.contains("markdown") { return "doc.richtext" }
    if mimeType.hasPrefix("text/") { return "doc.text" }
    if mimeType.hasPrefix("image/") { return "photo" }
    if mimeType.hasPrefix("audio/") { return "waveform" }
    if mimeType.hasPrefix("video/") { return "film" }
    return "doc"
  }
}

private struct PromptConnectorGroup: Hashable {
  let connectorId: String
  let connectorTitle: String
  let items: [UgotMCPPromptDescriptor]
}


private struct ResourceConnectorGroup: Hashable {
  let connectorId: String
  let connectorTitle: String
  let items: [UgotMCPResourceDescriptor]
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
