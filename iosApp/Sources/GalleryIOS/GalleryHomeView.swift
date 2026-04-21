import SwiftUI
import GallerySharedCore

struct GalleryHomeView: View {
  @State private var selectedConnectorIds: Set<String> = ["github"]
  private let models = GalleryModel.samples
  private let connectors = GalleryConnector.samples

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          heroCard
          quickStartSection
          modelSection
          connectorSection
          buildStatusSection
        }
        .padding()
      }
      .navigationTitle("Gallery")
      .background(Color(.systemGroupedBackground))
    }
  }

  private var heroCard: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("AI Edge Gallery", systemImage: "sparkles")
        .font(.title.bold())
      Text("Native iOS shell backed by the Kotlin Multiplatform shared core.")
        .font(.body)
        .foregroundStyle(.secondary)
      HStack(spacing: 10) {
        CapabilityBadge(title: "KMP linked", symbol: "link")
        CapabilityBadge(title: "SwiftUI", symbol: "iphone")
        CapabilityBadge(title: "iOS 17+", symbol: "checkmark.seal")
      }
    }
    .padding(18)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      LinearGradient(
        colors: [Color.blue.opacity(0.22), Color.purple.opacity(0.18)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      ),
      in: RoundedRectangle(cornerRadius: 22, style: .continuous)
    )
  }

  private var quickStartSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      SectionTitle("Start a task")
      HStack(spacing: 12) {
        QuickActionCard(
          title: "Chat",
          symbol: "bubble.left.and.bubble.right",
          destination: chatDestination(model: models[0], hint: UnifiedChatEntryHint(activateImage: false, activateAudio: false, activateSkills: false, activateMcpConnectorIds: Array(selectedConnectorIds)))
        )
        QuickActionCard(
          title: "Ask image",
          symbol: "photo",
          destination: chatDestination(
            model: models[0],
            hint: UnifiedChatEntryHint(
              activateImage: true,
              activateAudio: false,
              activateSkills: false,
              activateMcpConnectorIds: Array(selectedConnectorIds)
            )
          )
        )
        QuickActionCard(
          title: "Agent",
          symbol: "wand.and.stars",
          destination: chatDestination(
            model: models[2],
            hint: UnifiedChatEntryHint(
              activateImage: false,
              activateAudio: false,
              activateSkills: true,
              activateMcpConnectorIds: Array(selectedConnectorIds)
            )
          )
        )
      }
    }
  }

  private var modelSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      SectionTitle("Models")
      ForEach(models) { model in
        NavigationLink {
          chatDestination(
            model: model,
            hint: UnifiedChatEntryHint(
              activateImage: model.supportsImage,
              activateAudio: false,
              activateSkills: model.id == "functiongemma",
              activateMcpConnectorIds: Array(selectedConnectorIds)
            )
          )
        } label: {
          ModelRow(model: model)
        }
        .buttonStyle(.plain)
      }
    }
  }

  private var connectorSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      let label = UnifiedChatChromePolicyKt.buildConnectorLauncherLabel(
        activeConnectorCount: Int32(selectedConnectorIds.count)
      )
      SectionTitle(label)
      Text("Toggles here seed the shared connector bar state inside the chat screen.")
        .font(.footnote)
        .foregroundStyle(.secondary)
      FlowLayout(spacing: 10) {
        ForEach(connectors) { connector in
          Button {
            toggle(connector.id)
          } label: {
            Label(connector.title, systemImage: connector.symbol)
              .font(.subheadline.weight(.semibold))
              .padding(.horizontal, 12)
              .padding(.vertical, 9)
              .background(
                selectedConnectorIds.contains(connector.id) ? Color.accentColor.opacity(0.16) : Color(.secondarySystemGroupedBackground),
                in: Capsule()
              )
              .overlay(
                Capsule().stroke(selectedConnectorIds.contains(connector.id) ? Color.accentColor : Color.clear)
              )
          }
          .buttonStyle(.plain)
        }
      }
    }
  }

  private var buildStatusSection: some View {
    let encoded = UnifiedChatEntryHintKt.encodeUnifiedChatEntryHint(
      entryHint: UnifiedChatEntryHint(
        activateImage: true,
        activateAudio: false,
        activateSkills: false,
        activateMcpConnectorIds: Array(selectedConnectorIds)
      )
    )
    return VStack(alignment: .leading, spacing: 8) {
      SectionTitle("Shared core smoke test")
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

  private func toggle(_ connectorId: String) {
    if selectedConnectorIds.contains(connectorId) {
      selectedConnectorIds.remove(connectorId)
    } else {
      selectedConnectorIds.insert(connectorId)
    }
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

private struct QuickActionCard<Destination: View>: View {
  let title: String
  let symbol: String
  let destination: Destination

  var body: some View {
    NavigationLink {
      destination
    } label: {
      VStack(spacing: 10) {
        Image(systemName: symbol)
          .font(.title2)
          .frame(width: 44, height: 44)
          .background(Color.accentColor.opacity(0.14), in: Circle())
        Text(title)
          .font(.subheadline.weight(.semibold))
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 14)
      .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }
    .buttonStyle(.plain)
  }
}

private struct ModelRow: View {
  let model: GalleryModel

  var body: some View {
    HStack(spacing: 14) {
      VStack(alignment: .leading, spacing: 6) {
        Text(model.shortName)
          .font(.headline)
        Text(model.subtitle)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(2)
        HStack(spacing: 8) {
          if model.supportsImage { CapabilityBadge(title: "image", symbol: "photo") }
          if model.supportsAudio { CapabilityBadge(title: "audio", symbol: "waveform") }
          CapabilityBadge(title: "tools", symbol: "hammer")
        }
      }
      Spacer()
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
    HStack(spacing: spacing) {
      content
    }
  }
}

#Preview {
  GalleryHomeView()
}
