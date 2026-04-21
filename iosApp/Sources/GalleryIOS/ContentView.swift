import SwiftUI
import GallerySharedCore

struct ContentView: View {
  private let sharedCoreStatus: String = {
    let state = ConnectorBarState(
      visibleConnectorIds: ["github", "gmail", "canva"],
      activeConnectorIds: Set(["github"])
    )
    let toggled = state.toggle(connectorId: "gmail")
    return "GallerySharedCore linked: \(toggled.activeConnectorIds.count) active connectors"
  }()

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 16) {
        Text("AI Edge Gallery")
          .font(.largeTitle.bold())

        Text("iOS host shell")
          .font(.title2)
          .foregroundStyle(.secondary)

        Text(sharedCoreStatus)
          .font(.body.monospaced())
          .padding()
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))

        Text("This target verifies the Kotlin Multiplatform shared core can be built and linked from a native SwiftUI iOS app.")
          .font(.body)
          .foregroundStyle(.secondary)

        Spacer()
      }
      .padding()
      .navigationTitle("Gallery")
    }
  }
}

#Preview {
  ContentView()
}
