import SwiftUI
import GallerySharedCore

struct GalleryHomeView: View {
  @ObservedObject var authViewModel: UgotAuthViewModel
  @State private var selectedConnectorIds: Set<String> = Set(GalleryConnector.defaultSelectedIds)
  @State private var recentSessions: [GallerySessionSummary] = []
  @State private var selectedModelId: String = GalleryModel.samples[0].id
  @State private var newChatSessionId: String?

  private let models = GalleryModel.samples
  private let agentSkills = GalleryAgentSkill.samples
  private let connectors = GalleryConnector.samples
  private let sessionStore = GallerySessionStore()

  private var selectedModel: GalleryModel {
    models.first { $0.id == selectedModelId } ?? models[0]
  }

  private var currentEntryHint: UnifiedChatEntryHint {
    UnifiedChatEntryHint(
      activateImage: selectedModel.supportsImage,
      activateAudio: selectedModel.supportsAudio,
      activateSkills: true,
      activateAgentSkillIds: GalleryAgentSkill.defaultSelectedIds,
      activateMcpConnectorIds: Array(selectedConnectorIds)
    )
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          heroCard
          startChatSection
          recentSessionsSection
        }
        .padding()
      }
      .navigationTitle("UGOT AI")
      .background(Color(.systemGroupedBackground))
      .onAppear { refreshRecentSessions() }
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button("Sign out") { authViewModel.signOut() }
          .font(.caption.weight(.semibold))
      }
    }
    }
  }

  private var heroCard: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 8) {
          Text("UGOT AI")
            .font(.largeTitle.bold())
          Text("A private assistant for everyday questions, notes, and tools.")
            .font(.body)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Image(systemName: "message.and.waveform.fill")
          .font(.system(size: 32, weight: .bold))
          .foregroundStyle(.white)
          .frame(width: 62, height: 62)
          .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
      }
    }
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      LinearGradient(
        colors: [Color.indigo.opacity(0.25), Color.blue.opacity(0.18), Color.cyan.opacity(0.14)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      ),
      in: RoundedRectangle(cornerRadius: 28, style: .continuous)
    )
  }

  private var startChatSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      SectionTitle("Chat")
      Button {
        newChatSessionId = GallerySessionStore.makeNewSessionId(
          taskId: selectedModel.taskId,
          modelName: selectedModel.name,
          entryHint: currentEntryHint
        )
      } label: {
        VStack(alignment: .leading, spacing: 14) {
          HStack {
            Label("New chat", systemImage: "plus.message.fill")
              .font(.title3.bold())
            Spacer()
            Image(systemName: "arrow.right.circle.fill")
              .font(.title2)
              .foregroundStyle(Color.accentColor)
          }
          Text("Ask anything and continue privately.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
      }
      .buttonStyle(.plain)
      .navigationDestination(
        isPresented: Binding(
          get: { newChatSessionId != nil },
          set: { isPresented in
            if !isPresented {
              newChatSessionId = nil
              refreshRecentSessions()
            }
          }
        )
      ) {
        if let sessionId = newChatSessionId {
          chatDestination(
            model: selectedModel,
            hint: currentEntryHint,
            sessionId: sessionId,
            restoreExistingSession: false
          )
        }
      }
    }
  }

  private var recentSessionsSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        SectionTitle("Continue")
        Spacer()
        if !recentSessions.isEmpty {
          Button("Refresh") { refreshRecentSessions() }
            .font(.caption.weight(.semibold))
        }
      }

      if recentSessions.isEmpty {
        Text("Recent chats will appear here.")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .padding(14)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
      } else {
        ForEach(recentSessions.prefix(4)) { session in
          NavigationLink {
            chatDestination(
              model: modelForSession(session),
              hint: hintForSession(session),
              sessionId: session.id,
              restoreExistingSession: true
            )
          } label: {
            RecentSessionRow(session: session) {
              sessionStore.delete(id: session.id)
              refreshRecentSessions()
            }
          }
          .buttonStyle(.plain)
        }
      }
    }
  }

  private var controlsSection: some View {
    VStack(alignment: .leading, spacing: 16) {
      SectionTitle("Chat settings")
      modelPicker
      connectorPicker
    }
    .padding(16)
    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
  }

  private var modelPicker: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Model")
        .font(.subheadline.weight(.semibold))
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 10) {
          ForEach(models) { model in
            Button {
              selectedModelId = model.id
            } label: {
              VStack(alignment: .leading, spacing: 4) {
                Text(model.shortName).font(.caption.weight(.bold))
                Text(model.downloadState.rawValue).font(.caption2)
              }
              .padding(.horizontal, 12)
              .padding(.vertical, 10)
              .background(selectedModelId == model.id ? Color.accentColor.opacity(0.16) : Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
              .overlay(RoundedRectangle(cornerRadius: 14).stroke(selectedModelId == model.id ? Color.accentColor : Color.clear))
            }
            .buttonStyle(.plain)
          }
        }
      }
    }
  }

  private var connectorPicker: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(UnifiedChatChromePolicyKt.buildConnectorLauncherLabel(activeConnectorCount: Int32(selectedConnectorIds.count)))
        .font(.subheadline.weight(.semibold))
      FlowLayout(spacing: 10) {
        ForEach(connectors) { connector in
          Button { toggle(connector.id) } label: {
            Label(connector.title, systemImage: connector.symbol)
              .font(.subheadline.weight(.semibold))
              .padding(.horizontal, 12)
              .padding(.vertical, 9)
              .background(
                selectedConnectorIds.contains(connector.id) ? Color.accentColor.opacity(0.16) : Color(.tertiarySystemGroupedBackground),
                in: Capsule()
              )
              .overlay(Capsule().stroke(selectedConnectorIds.contains(connector.id) ? Color.accentColor : Color.clear))
          }
          .buttonStyle(.plain)
        }
      }
    }
  }

  private var localModelsSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        SectionTitle("Local models")
        Spacer()
        NavigationLink("Manage") {
          GalleryModelManagerView(
            models: models,
            agentSkills: agentSkills,
            connectors: connectors,
            selectedConnectorIds: selectedConnectorIds
          )
        }
        .font(.caption.weight(.semibold))
      }
      ForEach(models.prefix(2)) { model in
        CompactModelCard(model: model)
      }
    }
  }

  private var runtimeSection: some View {
    let encoded = UnifiedChatEntryHintKt.encodeUnifiedChatEntryHint(entryHint: currentEntryHint)
    return VStack(alignment: .leading, spacing: 10) {
      SectionTitle("Runtime + shared core")
      RuntimeStatusCard()
      Text("Current chat entry hint")
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(encoded)
        .font(.caption.monospaced())
        .lineLimit(3)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }
  }

  private func chatDestination(
    model: GalleryModel,
    hint: UnifiedChatEntryHint,
    sessionId: String? = nil,
    restoreExistingSession: Bool = true
  ) -> some View {
    GalleryChatView(
      model: model,
      agentSkills: agentSkills,
      connectors: connectors,
      entryHint: hint,
      sessionIdOverride: sessionId,
      restoreExistingSession: restoreExistingSession
    )
  }

  private func refreshRecentSessions() {
    recentSessions = sessionStore.listSessions()
  }

  private func modelForSession(_ session: GallerySessionSummary) -> GalleryModel {
    models.first { $0.name == session.modelName } ?? models[0]
  }

  private func hintForSession(_ session: GallerySessionSummary) -> UnifiedChatEntryHint {
    UnifiedChatEntryHint(
      activateImage: session.entryHint.activateImage,
      activateAudio: session.entryHint.activateAudio,
      activateSkills: session.entryHint.activateSkills,
      activateAgentSkillIds: session.entryHint.activateAgentSkillIds,
      activateMcpConnectorIds: session.activeConnectorIds
    )
  }

  private func toggle(_ connectorId: String) {
    if selectedConnectorIds.contains(connectorId) {
      selectedConnectorIds.remove(connectorId)
    } else {
      selectedConnectorIds.insert(connectorId)
    }
  }
}

private struct CompactModelCard: View {
  let model: GalleryModel

  var body: some View {
    HStack(spacing: 14) {
      VStack(alignment: .leading, spacing: 5) {
        HStack {
          Text(model.shortName).font(.headline)
          Text(model.parameterLabel)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Color(.tertiarySystemGroupedBackground), in: Capsule())
        }
        Text(model.subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
      Spacer()
      VStack(alignment: .trailing, spacing: 5) {
        Text(model.downloadState.rawValue)
          .font(.caption.weight(.semibold))
          .foregroundStyle(model.downloadState == .loaded ? .green : .orange)
        Text(model.estimatedSize)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
    .padding(16)
    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
  }
}

private struct RuntimeStatusCard: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("\(GalleryRuntimeFactory.defaultRuntime().displayName) active", systemImage: "cpu")
        .font(.subheadline.weight(.semibold))
      Text(GalleryRuntimeFactory.runtimeStatusSummary())
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
  }
}

private struct RecentSessionRow: View {
  let session: GallerySessionSummary
  let onDelete: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 5) {
        Text(session.title).font(.headline).lineLimit(1)
        Text("\(session.messageCount) messages")
          .font(.caption)
          .foregroundStyle(.secondary)
        if !session.activeConnectorIds.isEmpty {
          Text("Connectors: \(session.activeConnectorIds.joined(separator: ", "))")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      Spacer()
      Button(role: .destructive) { onDelete() } label: {
        Image(systemName: "trash")
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.red)
          .frame(width: 34, height: 34)
          .background(Color.red.opacity(0.1), in: Circle())
      }
      .buttonStyle(.plain)
      Image(systemName: "chevron.right")
        .font(.footnote.weight(.bold))
        .foregroundStyle(.tertiary)
    }
    .padding(16)
    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
  }
}

private struct SectionTitle: View {
  let title: String
  init(_ title: String) { self.title = title }
  var body: some View {
    Text(title)
      .font(.headline)
      .foregroundStyle(.primary)
  }
}

private struct CapabilityBadge: View {
  let title: String
  let symbol: String
  var body: some View {
    Label(title, systemImage: symbol)
      .font(.caption.weight(.semibold))
      .padding(.horizontal, 10)
      .padding(.vertical, 7)
      .background(.regularMaterial, in: Capsule())
  }
}

struct FlowLayout<Content: View>: View {
  let spacing: CGFloat
  @ViewBuilder let content: Content

  init(spacing: CGFloat = 8, @ViewBuilder content: () -> Content) {
    self.spacing = spacing
    self.content = content()
  }

  var body: some View {
    HStack(spacing: spacing) { content }
  }
}

#Preview {
  GalleryHomeView(authViewModel: UgotAuthViewModel())
}
