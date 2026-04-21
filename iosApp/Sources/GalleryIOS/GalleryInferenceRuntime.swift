import Foundation
import GallerySharedCore
import Darwin

struct GalleryInferenceRequest {
  let modelName: String
  let modelDisplayName: String
  let modelFileName: String
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

/// LiteRT-LM iOS runtime adapter.
///
/// The public LiteRT-LM repository exposes a stable C API and iOS build targets. This adapter uses
/// that C ABI dynamically so the app can keep compiling even when the signed LiteRT-LM iOS
/// framework/dylib is supplied outside this repository. If the symbols are present in the app
/// image, it performs real `.litertlm` generation; otherwise it returns an actionable runtime
/// readiness message instead of falling back to a different engine.
struct LiteRTLMGalleryInferenceRuntime: GalleryInferenceRuntime {
  let id = "litert-lm-ios"
  let displayName = "LiteRT-LM iOS"
  var isAvailable: Bool { GalleryLiteRTLMBridge.isCompiledWithLiteRTLM() || LiteRTLMDynamicCAPI.shared.isLoaded }
  var statusMessage: String {
    if GalleryLiteRTLMBridge.isCompiledWithLiteRTLM() {
      return "LiteRT-LM native bridge is linked. Put .litertlm files in Documents/GalleryModels or bundle them as app resources."
    }
    return LiteRTLMDynamicCAPI.shared.statusMessage
  }

  func generate(request: GalleryInferenceRequest) async -> GalleryInferenceResult {
    await Task.detached(priority: .userInitiated) {
      GalleryInferenceResult(
        text: generateLiteRTLMText(request: request),
        runtimeName: id
      )
    }.value
  }

  private func generateLiteRTLMText(request: GalleryInferenceRequest) -> String {
    if GalleryLiteRTLMBridge.isCompiledWithLiteRTLM() {
      guard let modelPath = LiteRTLMDynamicCAPI.findModelPath(fileName: request.modelFileName) else {
        return "LiteRT-LM native bridge is linked, but \(request.modelFileName) was not found. Copy it to Documents/GalleryModels/\(request.modelFileName) or add it to the app bundle resources, then run chat again."
      }
      do {
        let text = try GalleryLiteRTLMBridge().generate(
          withModelPath: modelPath,
          prompt: request.prompt,
          cacheDir: LiteRTLMDynamicCAPI.cacheDirectoryPath()
        )
        if !text.isEmpty {
          return text
        }
        return "LiteRT-LM native bridge returned an empty response."
      } catch {
        return error.localizedDescription
      }
    }

    return LiteRTLMDynamicCAPI.shared.generate(request: request)
  }
}

enum GalleryRuntimeFactory {
  static let litertLM = LiteRTLMGalleryInferenceRuntime()
  static let fallback = StubGalleryInferenceRuntime()

  static func defaultRuntime() -> GalleryInferenceRuntime {
    litertLM
  }

  static func runtimeStatusSummary() -> String {
    if litertLM.isAvailable {
      return "Using \(litertLM.displayName)."
    }
    return "\(litertLM.displayName): \(litertLM.statusMessage)"
  }
}

private struct LiteRTLMInputData {
  var type: Int32
  var data: UnsafeRawPointer?
  var size: Int
}

private final class LiteRTLMDynamicCAPI {
  static let shared = LiteRTLMDynamicCAPI()

  private typealias EngineSettingsCreateFn =
    @convention(c) (
      UnsafePointer<CChar>?,
      UnsafePointer<CChar>?,
      UnsafePointer<CChar>?,
      UnsafePointer<CChar>?
    ) -> OpaquePointer?
  private typealias EngineSettingsDeleteFn = @convention(c) (OpaquePointer?) -> Void
  private typealias EngineSettingsSetCacheDirFn =
    @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> Void
  private typealias EngineCreateFn = @convention(c) (OpaquePointer?) -> OpaquePointer?
  private typealias EngineDeleteFn = @convention(c) (OpaquePointer?) -> Void
  private typealias SessionCreateFn = @convention(c) (OpaquePointer?, OpaquePointer?) -> OpaquePointer?
  private typealias SessionDeleteFn = @convention(c) (OpaquePointer?) -> Void
  private typealias SessionGenerateContentFn =
    @convention(c) (OpaquePointer?, UnsafeRawPointer?, Int) -> OpaquePointer?
  private typealias ResponsesDeleteFn = @convention(c) (OpaquePointer?) -> Void
  private typealias ResponsesGetNumCandidatesFn = @convention(c) (OpaquePointer?) -> Int32
  private typealias ResponsesGetTextAtFn = @convention(c) (OpaquePointer?, Int32) -> UnsafePointer<CChar>?

  private let handle: UnsafeMutableRawPointer?
  private let engineSettingsCreate: EngineSettingsCreateFn?
  private let engineSettingsDelete: EngineSettingsDeleteFn?
  private let engineSettingsSetCacheDir: EngineSettingsSetCacheDirFn?
  private let engineCreate: EngineCreateFn?
  private let engineDelete: EngineDeleteFn?
  private let sessionCreate: SessionCreateFn?
  private let sessionDelete: SessionDeleteFn?
  private let sessionGenerateContent: SessionGenerateContentFn?
  private let responsesDelete: ResponsesDeleteFn?
  private let responsesGetNumCandidates: ResponsesGetNumCandidatesFn?
  private let responsesGetTextAt: ResponsesGetTextAtFn?

  var isLoaded: Bool {
    engineSettingsCreate != nil &&
      engineSettingsDelete != nil &&
      engineCreate != nil &&
      engineDelete != nil &&
      sessionCreate != nil &&
      sessionDelete != nil &&
      sessionGenerateContent != nil &&
      responsesDelete != nil &&
      responsesGetNumCandidates != nil &&
      responsesGetTextAt != nil
  }

  var statusMessage: String {
    if isLoaded {
      return "LiteRT-LM C API symbols are loaded. Put .litertlm files in Documents/GalleryModels or bundle them as app resources."
    }
    return "LiteRT-LM iOS is the selected runtime, but this build does not yet include a signed LiteRT-LM C API framework/dylib."
  }

  private init() {
    handle = Self.openLiteRTLMHandle()
    engineSettingsCreate = Self.load(handle, "litert_lm_engine_settings_create", as: EngineSettingsCreateFn.self)
    engineSettingsDelete = Self.load(handle, "litert_lm_engine_settings_delete", as: EngineSettingsDeleteFn.self)
    engineSettingsSetCacheDir = Self.load(handle, "litert_lm_engine_settings_set_cache_dir", as: EngineSettingsSetCacheDirFn.self)
    engineCreate = Self.load(handle, "litert_lm_engine_create", as: EngineCreateFn.self)
    engineDelete = Self.load(handle, "litert_lm_engine_delete", as: EngineDeleteFn.self)
    sessionCreate = Self.load(handle, "litert_lm_engine_create_session", as: SessionCreateFn.self)
    sessionDelete = Self.load(handle, "litert_lm_session_delete", as: SessionDeleteFn.self)
    sessionGenerateContent = Self.load(handle, "litert_lm_session_generate_content", as: SessionGenerateContentFn.self)
    responsesDelete = Self.load(handle, "litert_lm_responses_delete", as: ResponsesDeleteFn.self)
    responsesGetNumCandidates = Self.load(handle, "litert_lm_responses_get_num_candidates", as: ResponsesGetNumCandidatesFn.self)
    responsesGetTextAt = Self.load(handle, "litert_lm_responses_get_response_text_at", as: ResponsesGetTextAtFn.self)
  }

  func generate(request: GalleryInferenceRequest) -> String {
    guard isLoaded else {
      return "\(statusMessage)\n\nExpected symbols include litert_lm_engine_create and litert_lm_session_generate_content. The adapter is already targeting LiteRT-LM, not Cactus/llama.cpp."
    }

    guard let modelPath = Self.findModelPath(fileName: request.modelFileName) else {
      return "LiteRT-LM C API is loaded, but \(request.modelFileName) was not found. Copy it to Documents/GalleryModels/\(request.modelFileName) or add it to the app bundle resources, then run chat again."
    }

    guard
      let engineSettingsCreate,
      let engineSettingsDelete,
      let engineCreate,
      let engineDelete,
      let sessionCreate,
      let sessionDelete,
      let sessionGenerateContent,
      let responsesDelete,
      let responsesGetNumCandidates,
      let responsesGetTextAt
    else {
      return statusMessage
    }

    var generated = ""
    modelPath.withCString { modelPathCString in
      "cpu".withCString { backendCString in
        let settings = engineSettingsCreate(modelPathCString, backendCString, nil, nil)
        guard let settings else {
          generated = "LiteRT-LM failed to create engine settings for \(request.modelFileName)."
          return
        }
        defer { engineSettingsDelete(settings) }

        if let cacheDir = Self.cacheDirectoryPath() {
          cacheDir.withCString { cacheCString in
            self.engineSettingsSetCacheDir?(settings, cacheCString)
          }
        }

        guard let engine = engineCreate(settings) else {
          generated = "LiteRT-LM failed to create an engine for \(request.modelFileName)."
          return
        }
        defer { engineDelete(engine) }

        guard let session = sessionCreate(engine, nil) else {
          generated = "LiteRT-LM failed to create a session for \(request.modelFileName)."
          return
        }
        defer { sessionDelete(session) }

        request.prompt.withCString { promptCString in
          var input = LiteRTLMInputData(
            type: 0,
            data: UnsafeRawPointer(promptCString),
            size: strlen(promptCString)
          )
          let responses = withUnsafePointer(to: &input) { inputPointer in
            sessionGenerateContent(session, UnsafeRawPointer(inputPointer), 1)
          }
          guard let responses else {
            generated = "LiteRT-LM generation returned no response."
            return
          }
          defer { responsesDelete(responses) }

          guard responsesGetNumCandidates(responses) > 0,
                let textPointer = responsesGetTextAt(responses, 0) else {
            generated = "LiteRT-LM generation completed with no text candidate."
            return
          }
          generated = String(cString: textPointer)
        }
      }
    }

    return generated.isEmpty ? "LiteRT-LM returned an empty response." : generated
  }

  private static func load<T>(_ handle: UnsafeMutableRawPointer?, _ symbol: String, as type: T.Type) -> T? {
    guard let handle else {
      return nil
    }
    guard let symbolPointer = dlsym(handle, symbol) else {
      return nil
    }
    return unsafeBitCast(symbolPointer, to: type)
  }

  private static func openLiteRTLMHandle() -> UnsafeMutableRawPointer? {
    let flags = RTLD_NOW | RTLD_LOCAL
    if let currentProcess = dlopen(nil, flags),
       dlsym(currentProcess, "litert_lm_engine_create") != nil {
      return currentProcess
    }

    for path in candidateLibraryPaths() {
      if let handle = dlopen(path, flags) {
        return handle
      }
    }
    return nil
  }

  private static func candidateLibraryPaths() -> [String] {
    var paths: [String] = []
    let bundle = Bundle.main
    let roots = [
      bundle.privateFrameworksPath,
      bundle.sharedFrameworksPath,
      bundle.bundlePath,
    ].compactMap { $0 }
    let names = [
      "liblitertlm.dylib",
      "libLiteRTLM.dylib",
      "LiteRTLM.framework/LiteRTLM",
      "LiteRT_LM.framework/LiteRT_LM",
      "LiteRTLMCore.framework/LiteRTLMCore",
    ]
    for root in roots {
      for name in names {
        paths.append((root as NSString).appendingPathComponent(name))
      }
    }
    return paths
  }

  static func findModelPath(fileName: String) -> String? {
    let fileBase = (fileName as NSString).deletingPathExtension
    let fileExtension = (fileName as NSString).pathExtension
    if let bundled = Bundle.main.path(forResource: fileBase, ofType: fileExtension) {
      return bundled
    }

    let fileManager = FileManager.default
    let searchRoots = [
      fileManager.urls(for: .documentDirectory, in: .userDomainMask).first,
      fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
      fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first,
    ].compactMap { $0 }

    let subdirectories = ["GalleryModels", "Models", ""]
    for root in searchRoots {
      for subdirectory in subdirectories {
        let candidate = subdirectory.isEmpty
          ? root.appendingPathComponent(fileName)
          : root.appendingPathComponent(subdirectory).appendingPathComponent(fileName)
        if fileManager.fileExists(atPath: candidate.path) {
          return candidate.path
        }
      }
    }
    return nil
  }

  static func cacheDirectoryPath() -> String? {
    let fileManager = FileManager.default
    guard let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
      return nil
    }
    let cacheDirectory = applicationSupport.appendingPathComponent("LiteRTLMCache", isDirectory: true)
    try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    return cacheDirectory.path
  }
}
