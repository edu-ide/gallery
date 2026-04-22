import Foundation
import GallerySharedCore
import SwiftUI

struct GalleryModel: Identifiable, Hashable {
  enum DownloadState: String {
    case notDownloaded = "Not downloaded"
    case downloaded = "Downloaded"
    case loaded = "Loaded"
  }

  let id: String
  let name: String
  let shortName: String
  let subtitle: String
  let taskId: String
  let supportsImage: Bool
  let supportsAudio: Bool
  let recommendedPrompt: String
  let parameterLabel: String
  let estimatedSize: String
  let modelFileName: String
  let downloadState: DownloadState

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
      recommendedPrompt: "Draft a short launch checklist for the iOS KMP shell.",
      parameterLabel: "E2B",
      estimatedSize: "~3.1 GB",
      modelFileName: "gemma-4-E2B-it.litertlm",
      downloadState: .loaded
    ),
    GalleryModel(
      id: "gemma-e4b",
      name: "Gemma-4-E4B-it",
      shortName: "Gemma E4B",
      subtitle: "Larger reasoning model placeholder for high quality chat.",
      taskId: "llm_chat",
      supportsImage: true,
      supportsAudio: true,
      recommendedPrompt: "Compare local mobile inference runtime options.",
      parameterLabel: "E4B",
      estimatedSize: "~5.8 GB",
      modelFileName: "gemma-4-E4B-it.litertlm",
      downloadState: .notDownloaded
    ),
    GalleryModel(
      id: "functiongemma",
      name: "FunctionGemma-270m-it",
      shortName: "FunctionGemma",
      subtitle: "Fast tool-calling model placeholder for mobile actions.",
      taskId: "agent_chat",
      supportsImage: false,
      supportsAudio: false,
      recommendedPrompt: "Turn on a connector and call a demo tool.",
      parameterLabel: "270M",
      estimatedSize: "~350 MB",
      modelFileName: "functiongemma-270m-it.litertlm",
      downloadState: .downloaded
    ),
  ]
}

struct GalleryTask: Identifiable, Hashable {
  let id: String
  let title: String
  let subtitle: String
  let symbol: String
  let tint: Color
  let model: GalleryModel
  let entryHint: UnifiedChatEntryHint
}

extension GalleryTask {
  static func samples(selectedConnectorIds: Set<String>, models: [GalleryModel]) -> [GalleryTask] {
    let connectors = Array(selectedConnectorIds)
    return [
      GalleryTask(
        id: "chat",
        title: "AI Chat",
        subtitle: "Chat with Gemma using the shared KMP session state.",
        symbol: "bubble.left.and.bubble.right.fill",
        tint: .blue,
        model: models[0],
        entryHint: UnifiedChatEntryHint(
          activateImage: false,
          activateAudio: false,
          activateSkills: true,
          activateAgentSkillIds: GalleryAgentSkill.defaultSelectedIds,
          activateMcpConnectorIds: connectors
        )
      ),
      GalleryTask(
        id: "ask-image",
        title: "Ask Image",
        subtitle: "Multimodal prompt shell with image capability enabled.",
        symbol: "photo.fill.on.rectangle.fill",
        tint: .purple,
        model: models[0],
        entryHint: UnifiedChatEntryHint(
          activateImage: true,
          activateAudio: false,
          activateSkills: true,
          activateAgentSkillIds: GalleryAgentSkill.defaultSelectedIds,
          activateMcpConnectorIds: connectors
        )
      ),
      GalleryTask(
        id: "agent-skills",
        title: "Agent Skills",
        subtitle: "Tool calling flow with connector chips and MCP cards.",
        symbol: "wand.and.stars.inverse",
        tint: .orange,
        model: models[2],
        entryHint: UnifiedChatEntryHint(
          activateImage: false,
          activateAudio: false,
          activateSkills: true,
          activateAgentSkillIds: GalleryAgentSkill.defaultSelectedIds,
          activateMcpConnectorIds: connectors
        )
      ),
      GalleryTask(
        id: "audio-scribe",
        title: "Audio Scribe",
        subtitle: "Audio-capable chat shell and microphone chrome.",
        symbol: "waveform.circle.fill",
        tint: .green,
        model: models[0],
        entryHint: UnifiedChatEntryHint(
          activateImage: false,
          activateAudio: true,
          activateSkills: true,
          activateAgentSkillIds: GalleryAgentSkill.defaultSelectedIds,
          activateMcpConnectorIds: connectors
        )
      ),
      GalleryTask(
        id: "prompt-lab",
        title: "Prompt Lab",
        subtitle: "Single-turn prompt experiments; runtime adapter pending.",
        symbol: "slider.horizontal.3",
        tint: .teal,
        model: models[1],
        entryHint: UnifiedChatEntryHint(
          activateImage: false,
          activateAudio: false,
          activateSkills: true,
          activateAgentSkillIds: [GalleryAgentSkill.summarizeId, GalleryAgentSkill.translateId],
          activateMcpConnectorIds: connectors
        )
      ),
      GalleryTask(
        id: "mobile-actions",
        title: "Mobile Actions",
        subtitle: "FunctionGemma action shell for future device controls.",
        symbol: "iphone.gen3.radiowaves.left.and.right",
        tint: .pink,
        model: models[2],
        entryHint: UnifiedChatEntryHint(
          activateImage: false,
          activateAudio: false,
          activateSkills: true,
          activateAgentSkillIds: [GalleryAgentSkill.mobileActionsId],
          activateMcpConnectorIds: connectors
        )
      ),
    ]
  }
}

struct GalleryConnector: Identifiable, Hashable {
  let id: String
  let title: String
  let symbol: String
  let summary: String
  let endpoint: String
}

extension GalleryConnector {
  static let fortuneMcpId = "fortune.ugot.uk/mcp"
  static let fortuneMcpEndpoint = "https://fortune.ugot.uk/mcp"
  static let mailMcpId = "mail.local/mcp"
  static let mailMcpEndpoint = ProcessInfo.processInfo.environment["UGOT_MAIL_MCP_ENDPOINT"]
    ?? "embedded://mail-mcp-rs"
  static let defaultSelectedIds = [fortuneMcpId, mailMcpId]

  static let samples: [GalleryConnector] = [
    GalleryConnector(
      id: fortuneMcpId,
      title: "UGOT Fortune",
      symbol: "sparkles",
      summary: "MCP endpoint: \(fortuneMcpEndpoint)",
      endpoint: fortuneMcpEndpoint
    ),
    GalleryConnector(
      id: mailMcpId,
      title: "UGOT Mail",
      symbol: "envelope",
      summary: "Embedded mail MCP backend: \(mailMcpEndpoint)",
      endpoint: mailMcpEndpoint
    ),
  ]

  static func connector(for id: String) -> GalleryConnector? {
    samples.first { $0.id == id }
  }

  static func endpoint(for id: String) -> String? {
    connector(for: id)?.endpoint
  }
}

struct GalleryAgentSkill: Identifiable, Hashable {
  let id: String
  let title: String
  let symbol: String
  let summary: String
}

extension GalleryAgentSkill {
  static let summarizeId = "summarize"
  static let translateId = "translate"
  static let mobileActionsId = "mobile_actions"

  static let defaultSelectedIds = [summarizeId, translateId, mobileActionsId]

  static let samples: [GalleryAgentSkill] = [
    GalleryAgentSkill(
      id: summarizeId,
      title: "Summarize",
      symbol: "text.badge.checkmark",
      summary: "Summarize long text inside chat."
    ),
    GalleryAgentSkill(
      id: translateId,
      title: "Translate",
      symbol: "character.book.closed",
      summary: "Translate and rewrite text inside chat."
    ),
    GalleryAgentSkill(
      id: mobileActionsId,
      title: "Mobile actions",
      symbol: "iphone.gen3.radiowaves.left.and.right",
      summary: "Allow device actions with confirmation."
    ),
  ]
}
