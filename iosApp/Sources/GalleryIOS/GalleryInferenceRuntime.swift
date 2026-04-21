import Foundation
import GallerySharedCore

struct GalleryInferenceRequest {
  let modelName: String
  let modelDisplayName: String
  let prompt: String
  let route: String
  let activeConnectorIds: [String]
  let supportsImage: Bool
  let supportsAudio: Bool
}

struct GalleryInferenceResult {
  let text: String
  let runtimeName: String
}

protocol GalleryInferenceRuntime {
  func generate(request: GalleryInferenceRequest) async -> GalleryInferenceResult
}

struct StubGalleryInferenceRuntime: GalleryInferenceRuntime {
  func generate(request: GalleryInferenceRequest) async -> GalleryInferenceResult {
    try? await Task.sleep(nanoseconds: 120_000_000)
    let connectors = request.activeConnectorIds.isEmpty ? "none" : request.activeConnectorIds.joined(separator: ", ")
    let modalities = [
      request.supportsImage ? "image" : nil,
      request.supportsAudio ? "audio" : nil,
    ].compactMap { $0 }.joined(separator: ", ")

    return GalleryInferenceResult(
      text: "Stub runtime response from \(request.modelDisplayName). Active connectors: \(connectors). Modalities: \(modalities.isEmpty ? "text" : modalities).",
      runtimeName: "stub-ios-runtime"
    )
  }
}
