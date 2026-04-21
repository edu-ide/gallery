import SwiftUI
import GallerySharedCore

struct ContentView: View {
  @State private var didStartSmokeRun = false

  var body: some View {
    GalleryHomeView()
      .task {
        await runLaunchSmokeTestIfRequested()
      }
  }

  private func runLaunchSmokeTestIfRequested() async {
    guard !didStartSmokeRun else { return }
    guard let prompt = ProcessInfo.processInfo.environment["GALLERY_IOS_SMOKE_PROMPT"], !prompt.isEmpty else {
      return
    }
    didStartSmokeRun = true

    let model = GalleryModel.samples[0]
    let request = GalleryInferenceRequest(
      modelName: model.name,
      modelDisplayName: model.shortName,
      modelFileName: model.modelFileName,
      prompt: prompt,
      route: "ios-smoke",
      activeConnectorIds: GalleryConnector.defaultSelectedIds,
      supportsImage: false,
      supportsAudio: false
    )
    let startedAt = ISO8601DateFormatter().string(from: Date())
    let result = await GalleryRuntimeFactory.defaultRuntime().generate(request: request)
    let finishedAt = ISO8601DateFormatter().string(from: Date())
    let body = """
    startedAt=\(startedAt)
    finishedAt=\(finishedAt)
    runtime=\(result.runtimeName)
    prompt=\(prompt)
    response=\(result.text)
    """
    if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
      try? body.write(
        to: documents.appendingPathComponent("GallerySmokeResult.txt"),
        atomically: true,
        encoding: .utf8
      )
    }
  }
}

#Preview {
  ContentView()
}
