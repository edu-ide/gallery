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
  var id: String { get }
  var displayName: String { get }
  var isAvailable: Bool { get }
  var statusMessage: String { get }

  func generate(request: GalleryInferenceRequest) async -> GalleryInferenceResult
}

struct StubGalleryInferenceRuntime: GalleryInferenceRuntime {
  let id = "stub"
  let displayName = "Stub Runtime"
  let isAvailable = true
  let statusMessage = "Development stub. Replace with a production runtime adapter."

  func generate(request: GalleryInferenceRequest) async -> GalleryInferenceResult {
    try? await Task.sleep(nanoseconds: 120_000_000)
    let connectors = request.activeConnectorIds.isEmpty ? "none" : request.activeConnectorIds.joined(separator: ", ")
    let modalities = [
      request.supportsImage ? "image" : nil,
      request.supportsAudio ? "audio" : nil,
    ].compactMap { $0 }.joined(separator: ", ")

    return GalleryInferenceResult(
      text: "Stub runtime response from \(request.modelDisplayName). Active connectors: \(connectors). Modalities: \(modalities.isEmpty ? "text" : modalities).",
      runtimeName: id
    )
  }
}

/// Placeholder adapter for Google's LiteRT-LM iOS runtime.
///
/// As of April 21, 2026, the public LiteRT-LM repository marks Swift as "In Dev / Coming Soon".
/// This adapter keeps the app architecture ready for the official Swift API without blocking the
/// iOS shell build. When the Swift package/API is published, replace `generate` with the real
/// model load + streaming generation call and flip `isAvailable` based on runtime/model readiness.
struct LiteRTLMGalleryInferenceRuntime: GalleryInferenceRuntime {
  let id = "litert-lm-ios"
  let displayName = "LiteRT-LM iOS"
  let isAvailable = false
  let statusMessage = "LiteRT-LM Swift API is not public yet; adapter scaffold is ready."

  func generate(request: GalleryInferenceRequest) async -> GalleryInferenceResult {
    GalleryInferenceResult(
      text: "LiteRT-LM iOS adapter is scaffolded, but the public Swift API is still marked Coming Soon. Falling back to the stub runtime for now.",
      runtimeName: id
    )
  }
}

enum GalleryRuntimeFactory {
  static let litertLM = LiteRTLMGalleryInferenceRuntime()
  static let fallback = StubGalleryInferenceRuntime()

  static func defaultRuntime() -> GalleryInferenceRuntime {
    litertLM.isAvailable ? litertLM : fallback
  }

  static func runtimeStatusSummary() -> String {
    if litertLM.isAvailable {
      return "Using \(litertLM.displayName)."
    }
    return "\(litertLM.displayName): \(litertLM.statusMessage)"
  }
}
