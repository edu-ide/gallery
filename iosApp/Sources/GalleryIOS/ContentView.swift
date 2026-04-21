import SwiftUI
import GallerySharedCore

struct ContentView: View {
  @StateObject private var authViewModel = UgotAuthViewModel()
  @State private var didStartSmokeRun = false

  var body: some View {
    Group {
      if authViewModel.isAuthenticated {
        GalleryHomeView(authViewModel: authViewModel)
      } else {
        UgotLoginView(authViewModel: authViewModel)
      }
    }
    .task {
      await authViewModel.restoreSession()
      await runLaunchSmokeTestIfRequested()
    }
  }

  private func runLaunchSmokeTestIfRequested() async {
    guard !didStartSmokeRun else { return }
    guard let prompt = ProcessInfo.processInfo.environment["GALLERY_IOS_SMOKE_PROMPT"], !prompt.isEmpty else {
      return
    }
    didStartSmokeRun = true

    if ProcessInfo.processInfo.environment["GALLERY_IOS_SMOKE_ACTION"] == "1" {
      await runActionSmoke(prompt: prompt)
      return
    }

    let model = GalleryModel.samples[0]
    let request = GalleryInferenceRequest(
      modelName: model.name,
      modelDisplayName: model.shortName,
      modelFileName: model.modelFileName,
      prompt: prompt,
      route: "ios-smoke",
      activeAgentSkillIds: GalleryAgentSkill.defaultSelectedIds,
      activeConnectorIds: GalleryConnector.defaultSelectedIds,
      supportsImage: false,
      supportsAudio: false,
      attachments: []
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

  private func runActionSmoke(prompt: String) async {
    let startedAt = ISO8601DateFormatter().string(from: Date())
    let skills = Set(GalleryAgentSkill.defaultSelectedIds)
    let connectors = Set(GalleryConnector.defaultSelectedIds)
    var result = await GalleryFortuneActionRunner.runIfNeeded(
      prompt: prompt,
      activeSkillIds: skills,
      activeConnectorIds: connectors
    )
    if result == nil {
      result = await GalleryMobileActionRunner.runIfNeeded(
        prompt: prompt,
        activeSkillIds: skills
      )
    }
    let finishedAt = ISO8601DateFormatter().string(from: Date())
    let snapshotState = result?.widgetSnapshot?.widgetStateJson ?? ""
    let body = """
    startedAt=\(startedAt)
    finishedAt=\(finishedAt)
    actionSmoke=true
    prompt=\(prompt)
    message=\(result?.message ?? "NO_ACTION")
    hasWidget=\(result?.widgetSnapshot != nil)
    hasWidgetHtml=\(snapshotState.contains("widgetHtmlBase64"))
    snapshotPrefix=\(snapshotState.prefix(500))
    """
    writeSmokeResult(body)
  }

  private func writeSmokeResult(_ body: String) {
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
