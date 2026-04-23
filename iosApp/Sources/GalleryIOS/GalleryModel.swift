import Foundation
import GallerySharedCore
import Security
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

struct GalleryConnector: Identifiable, Hashable, Codable {
  enum AuthMode: String, Codable, CaseIterable, Identifiable {
    case none
    case ugotBearer
    case bearer

    var id: String { rawValue }

    var title: String {
      switch self {
      case .none: return "No auth"
      case .ugotBearer: return "UGOT login token"
      case .bearer: return "Bearer token"
      }
    }
  }

  let id: String
  let title: String
  let symbol: String
  let summary: String
  let endpoint: String
  let authMode: AuthMode
  let bearerToken: String?

  init(
    id: String,
    title: String,
    symbol: String,
    summary: String,
    endpoint: String,
    authMode: AuthMode = .none,
    bearerToken: String? = nil
  ) {
    self.id = id
    self.title = title
    self.symbol = symbol
    self.summary = summary
    self.endpoint = endpoint
    self.authMode = authMode
    self.bearerToken = bearerToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
      ? bearerToken
      : nil
  }

  var isBuiltIn: Bool {
    GalleryConnector.builtInConnectors.contains { $0.id == id }
  }

  func bearerTokenForRequest(ugotAccessToken: String) -> String? {
    switch authMode {
    case .none:
      return nil
    case .ugotBearer:
      return ugotAccessToken
    case .bearer:
      return bearerToken
    }
  }
}

extension GalleryConnector {
  static let fortuneMcpId = "fortune.ugot.uk/mcp"
  static let fortuneMcpEndpoint = "https://fortune.ugot.uk/mcp"
  static let mailMcpId = "mail.local/mcp"
  static let mailMcpEndpoint = ProcessInfo.processInfo.environment["UGOT_MAIL_MCP_ENDPOINT"]
    ?? "embedded://mail-mcp-rs"
  static let defaultSelectedIds = [fortuneMcpId, mailMcpId]

  static let builtInConnectors: [GalleryConnector] = [
    GalleryConnector(
      id: fortuneMcpId,
      title: "UGOT Fortune",
      symbol: "sparkles",
      summary: "오늘의 운세, 사주, 궁합, 저장 프로필, 기본 사용자 변경을 도와줘요.",
      endpoint: fortuneMcpEndpoint,
      authMode: .ugotBearer
    ),
    GalleryConnector(
      id: mailMcpId,
      title: "UGOT Mail",
      symbol: "envelope",
      summary: "메일 계정 연결 상태, OAuth 연동, 최근 메일 검색, 요약, 라벨 정리, 답장 초안을 도와줘요.",
      endpoint: mailMcpEndpoint,
      authMode: .none
    ),
  ]

  static var samples: [GalleryConnector] {
    builtInConnectors + GalleryConnectorStore.loadCustomConnectors()
  }

  static func connector(for id: String) -> GalleryConnector? {
    samples.first { $0.id == id }
  }

  static func endpoint(for id: String) -> String? {
    connector(for: id)?.endpoint
  }

  static func customId(for endpoint: String) -> String {
    let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
    return "custom.mcp/" + Data(trimmed.utf8).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}

enum GalleryConnectorStore {
  private static let key = "gallery.customMCPConnectors.v1"

  static func loadCustomConnectors() -> [GalleryConnector] {
    guard let data = UserDefaults.standard.data(forKey: key),
          let decoded = try? JSONDecoder().decode([GalleryConnector].self, from: data) else {
      return []
    }
    let builtInIds = Set(GalleryConnector.builtInConnectors.map(\.id))
    let valid = decoded.filter { connector in
      !builtInIds.contains(connector.id) && URL(string: connector.endpoint) != nil
    }
    var migratedLegacySecret = false
    let hydrated = valid.map { connector in
      guard connector.authMode == .bearer else { return connector.strippingSecret() }
      if let legacyToken = connector.bearerToken?.galleryNilIfBlank {
        GalleryConnectorSecretStore.saveBearerToken(legacyToken, connectorId: connector.id)
        migratedLegacySecret = true
      }
      let token = GalleryConnectorSecretStore.loadBearerToken(connectorId: connector.id)
      return connector.withBearerToken(token)
    }
    if migratedLegacySecret {
      saveCustomConnectors(hydrated)
    }
    return hydrated
  }

  static func saveCustomConnectors(_ connectors: [GalleryConnector]) {
    let builtInIds = Set(GalleryConnector.builtInConnectors.map(\.id))
    let sanitized = connectors.filter { connector in
      !builtInIds.contains(connector.id) && URL(string: connector.endpoint) != nil
    }.map { $0.strippingSecret() }
    guard let data = try? JSONEncoder().encode(sanitized) else { return }
    UserDefaults.standard.set(data, forKey: key)
  }

  static func upsert(_ connector: GalleryConnector) {
    if connector.authMode == .bearer, let bearerToken = connector.bearerToken?.galleryNilIfBlank {
      GalleryConnectorSecretStore.saveBearerToken(bearerToken, connectorId: connector.id)
    } else {
      GalleryConnectorSecretStore.deleteBearerToken(connectorId: connector.id)
    }
    var connectors = loadCustomConnectors()
    connectors.removeAll { $0.id == connector.id }
    connectors.append(connector)
    saveCustomConnectors(connectors.sorted { $0.title < $1.title })
  }

  static func delete(id: String) {
    GalleryConnectorSecretStore.deleteBearerToken(connectorId: id)
    var connectors = loadCustomConnectors()
    connectors.removeAll { $0.id == id }
    saveCustomConnectors(connectors)
  }
}

private extension GalleryConnector {
  func strippingSecret() -> GalleryConnector {
    GalleryConnector(
      id: id,
      title: title,
      symbol: symbol,
      summary: summary,
      endpoint: endpoint,
      authMode: authMode,
      bearerToken: nil
    )
  }

  func withBearerToken(_ token: String?) -> GalleryConnector {
    GalleryConnector(
      id: id,
      title: title,
      symbol: symbol,
      summary: summary,
      endpoint: endpoint,
      authMode: authMode,
      bearerToken: token
    )
  }
}

enum GalleryConnectorSelectionStore {
  private static let key = "gallery.selectedMCPConnectorIds.v1"

  static func loadSelectedIds(defaults: [String]) -> Set<String> {
    guard let values = UserDefaults.standard.array(forKey: key) as? [String] else {
      return Set(defaults)
    }
    let availableIds = Set(GalleryConnector.samples.map(\.id))
    let selected = Set(values).intersection(availableIds)
    return selected.isEmpty ? Set(defaults) : selected
  }

  static func saveSelectedIds(_ ids: Set<String>) {
    let availableIds = Set(GalleryConnector.samples.map(\.id))
    let sanitized = ids.intersection(availableIds).sorted()
    UserDefaults.standard.set(sanitized, forKey: key)
  }
}

private enum GalleryConnectorSecretStore {
  private static let service = "uk.ugot.galleryios.mcp-connectors"

  static func saveBearerToken(_ token: String, connectorId: String) {
    let data = Data(token.utf8)
    deleteBearerToken(connectorId: connectorId)
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: connectorId,
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    SecItemAdd(query as CFDictionary, nil)
  }

  static func loadBearerToken(connectorId: String) -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: connectorId,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess, let data = item as? Data else { return nil }
    return String(data: data, encoding: .utf8)?.galleryNilIfBlank
  }

  static func deleteBearerToken(connectorId: String) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: connectorId,
    ]
    SecItemDelete(query as CFDictionary)
  }
}

private extension String {
  var galleryNilIfBlank: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
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
