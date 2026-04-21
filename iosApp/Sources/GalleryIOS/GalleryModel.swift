import Foundation
import GallerySharedCore

struct GalleryModel: Identifiable, Hashable {
  let id: String
  let name: String
  let shortName: String
  let subtitle: String
  let taskId: String
  let supportsImage: Bool
  let supportsAudio: Bool
  let recommendedPrompt: String

  var capabilities: UnifiedChatModelCapabilities {
    UnifiedChatModelCapabilities(
      supportsImage: supportsImage,
      supportsAudio: supportsAudio
    )
  }
}

extension GalleryModel {
  static let samples: [GalleryModel] = [
    GalleryModel(
      id: "gemma-e2b",
      name: "Gemma-4-E2B-it",
      shortName: "Gemma E2B",
      subtitle: "Balanced on-device chat with tools and multimodal slots.",
      taskId: "llm_chat",
      supportsImage: true,
      supportsAudio: true,
      recommendedPrompt: "Draft a short launch checklist for the iOS KMP shell."
    ),
    GalleryModel(
      id: "gemma-e4b",
      name: "Gemma-4-E4B-it",
      shortName: "Gemma E4B",
      subtitle: "Larger reasoning model placeholder for high quality chat.",
      taskId: "llm_chat",
      supportsImage: true,
      supportsAudio: true,
      recommendedPrompt: "Compare local mobile inference runtime options."
    ),
    GalleryModel(
      id: "functiongemma",
      name: "FunctionGemma-270m-it",
      shortName: "FunctionGemma",
      subtitle: "Fast tool-calling model placeholder for mobile actions.",
      taskId: "agent_chat",
      supportsImage: false,
      supportsAudio: false,
      recommendedPrompt: "Turn on a connector and call a demo tool."
    ),
  ]
}

struct GalleryConnector: Identifiable, Hashable {
  let id: String
  let title: String
  let symbol: String
  let summary: String
}

extension GalleryConnector {
  static let samples: [GalleryConnector] = [
    GalleryConnector(
      id: "github",
      title: "GitHub",
      symbol: "chevron.left.forwardslash.chevron.right",
      summary: "Review PRs, issues, and repository context."
    ),
    GalleryConnector(
      id: "gmail",
      title: "Gmail",
      symbol: "envelope",
      summary: "Summarize mail threads and draft replies."
    ),
    GalleryConnector(
      id: "canva",
      title: "Canva",
      symbol: "rectangle.on.rectangle.angled",
      summary: "Generate or edit visual designs."
    ),
  ]
}
