import SwiftUI
import GallerySharedCore

struct GalleryHomeView: View {
  @State private var selectedConnectorIds: Set<String> = ["github"]
  @State private var recentSessions: [GallerySessionSummary] = []
  private let models = GalleryModel.samples
  private let connectors = GalleryConnector.samples
  private let sessionStore = GallerySessionStore()

  private var tasks: [GalleryTask] {
    GalleryTask.samples(selectedConnectorIds: selectedConnectorIds, models: models)
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          heroCard
          taskGridSection
          modelManagerSection
          recentSessionsSection
          connectorSection
          runtimeSection
        }
        .padding()
      }
      .navigationTitle("Gallery")
      .background(Color(.systemGroupedBackground))
      .onAppear { refreshRecentSessions() }
    }
  }

  private var heroCard: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 8) {
          Text("Google AI Edge Gallery")
            .font(.largeTitle.bold())
          Text("On-device AI playground for chat, multimodal prompts, skills, and model management.")
            .font(.body)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Image(systemName: "sparkles")
          .font(.system(size: 34, weight: .bold))
          .foregroundStyle(.white)
          .frame(width: 62, height: 62)
          .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
      }

      HStack(spacing: 10) {
        CapabilityBadge(title: "KMP shared", symbol: "link")
        CapabilityBadge(title: "Session history", symbol: "clock.arrow.circlepath")
        CapabilityBadge(title: "Runtime seam", symbol: "cpu")
      }

      Text(GalleryRuntimeFactory.runtimeStatusSummary())
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      LinearGradient(
        colors: [Color.blue.opacity(0.26), Color.purple.opacity(0.18), Color.cyan.opacity(0.16)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      ),
      in: RoundedRectangle(cornerRadius: 28, style: .continuous)
    )
  }

  private var taskGridSection: some View {
    VStack(alignment: .leading, spacing: 14) {
      SectionTitle("Tasks")
      LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
        ForEach(tasks) { task in
          NavigationLink {
            chatDestination(model: task.model, hint: task.entryHint)
          } label: {
            TaskTile(task: task)
          }
          .buttonStyle(.plain)
        }
      }
    }
  }

  private var modelManagerSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        SectionTitle("Model management")
        Spacer()
        NavigationLink("View all") {
          GalleryModelManagerView(
            models: models,
            connectors: connectors,
            selectedConnectorIds: selectedConnectorIds
          )
        }
        .font(.caption.weight(.semibold))
      }
      VStack(spacing: 10) {
        ForEach(models.prefix(2)) { model in
          NavigationLink {
            GalleryChatView(
              model: model,
              connectors: connectors,
              entryHint: UnifiedChatEntryHint(
                activateImage: model.supportsImage,
                activateAudio: false,
                activateSkills: model.id == "functiongemma",
                activateMcpConnectorIds: Array(selectedConnectorIds)
              )
            )
          } label: {
            CompactModelCard(model: model)
          }
          .buttonStyle(.plain)
        }
      }
    }
  }

  private var recentSessionsSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        SectionTitle("Recent sessions")
        Spacer()
        if !recentSessions.isEmpty {
          Button("Refresh") { refreshRecentSessions() }
            .font(.caption.weight(.semibold))
        }
      }

      if recentSessions.isEmpty {
        Text("Start a chat and send a message to save a session here.")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .padding(14)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
      } else {
        ForEach(recentSessions.prefix(4)) { session in
          NavigationLink {
            chatDestination(model: modelForSession(session), hint: hintForSession(session))
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

  private var connectorSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      let label = UnifiedChatChromePolicyKt.buildConnectorLauncherLabel(
        activeConnectorCount: Int32(selectedConnectorIds.count)
      )
      SectionTitle(label)
      Text("Connector choices seed the shared connector bar state in chat.")
        .font(.footnote)
        .foregroundStyle(.secondary)
      FlowLayout(spacing: 10) {
        ForEach(connectors) { connector in
          Button { toggle(connector.id) } label: {
            Label(connector.title, systemImage: connector.symbol)
              .font(.subheadline.weight(.semibold))
              .padding(.horizontal, 12)
              .padding(.vertical, 9)
              .background(
                selectedConnectorIds.contains(connector.id) ? Color.accentColor.opacity(0.16) : Color(.secondarySystemGroupedBackground),
                in: Capsule()
              )
              .overlay(Capsule().stroke(selectedConnectorIds.contains(connector.id) ? Color.accentColor : Color.clear))
          }
          .buttonStyle(.plain)
        }
      }
    }
  }

  private var runtimeSection: some View {
    let encoded = UnifiedChatEntryHintKt.encodeUnifiedChatEntryHint(
      entryHint: UnifiedChatEntryHint(
        activateImage: true,
        activateAudio: false,
        activateSkills: false,
        activateMcpConnectorIds: Array(selectedConnectorIds)
      )
    )
    return VStack(alignment: .leading, spacing: 10) {
      SectionTitle("Runtime + shared core")
      RuntimeStatusCard()
      Text("Encoded entry hint")
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

  private func chatDestination(model: GalleryModel, hint: UnifiedChatEntryHint) -> some View {
    GalleryChatView(model: model, connectors: connectors, entryHint: hint)
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

private struct TaskTile: View {
  let task: GalleryTask

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Image(systemName: task.symbol)
        .font(.title2)
        .foregroundStyle(.white)
        .frame(width: 44, height: 44)
        .background(task.tint, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
      Text(task.title)
        .font(.headline)
        .foregroundStyle(.primary)
      Text(task.subtitle)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(3)
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, minHeight: 158, alignment: .topLeading)
    .padding(14)
    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
  }
}

private struct CompactModelCard: View {
  let model: GalleryModel

  var body: some View {
    HStack(spacing: 14) {
      VStack(alignment: .leading, spacing: 5) {
        HStack {
          Text(model.shortName)
            .font(.headline)
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

private struct RecentSessionRow: View {
  let session: GallerySessionSummary
  let onDelete: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 5) {
        Text(session.title)
          .font(.headline)
          .lineLimit(1)
        Text("\(session.modelName) • \(session.messageCount) messages")
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
      Button(role: .destructive) {
        onDelete()
      } label: {
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
  GalleryHomeView()
}
