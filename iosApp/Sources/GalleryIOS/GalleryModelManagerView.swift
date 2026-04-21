import SwiftUI
import GallerySharedCore

struct GalleryModelManagerView: View {
  let models: [GalleryModel]
  let connectors: [GalleryConnector]
  let selectedConnectorIds: Set<String>

  var body: some View {
    List {
      Section {
        ForEach(models) { model in
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
            ModelManagerRow(model: model)
          }
        }
      } header: {
        Text("Available model placeholders")
      } footer: {
        Text("Download/load buttons are UI scaffolds until a production iOS runtime is connected. The current chat flow uses the runtime adapter seam.")
      }
    }
    .navigationTitle("Model Manager")
  }
}

private struct ModelManagerRow: View {
  let model: GalleryModel

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        Text(model.shortName)
          .font(.headline)
        Spacer()
        Text(model.downloadState.rawValue)
          .font(.caption.weight(.bold))
          .padding(.horizontal, 9)
          .padding(.vertical, 5)
          .background(stateColor.opacity(0.14), in: Capsule())
          .foregroundStyle(stateColor)
      }
      Text(model.subtitle)
        .font(.subheadline)
        .foregroundStyle(.secondary)
      HStack(spacing: 8) {
        Label(model.parameterLabel, systemImage: "cpu")
        Label(model.estimatedSize, systemImage: "internaldrive")
        if model.supportsImage { Label("Image", systemImage: "photo") }
        if model.supportsAudio { Label("Audio", systemImage: "waveform") }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .padding(.vertical, 6)
  }

  private var stateColor: Color {
    switch model.downloadState {
    case .notDownloaded: return .orange
    case .downloaded: return .blue
    case .loaded: return .green
    }
  }
}

#Preview {
  NavigationStack {
    GalleryModelManagerView(
      models: GalleryModel.samples,
      connectors: GalleryConnector.samples,
      selectedConnectorIds: Set(GalleryConnector.defaultSelectedIds)
    )
  }
}
