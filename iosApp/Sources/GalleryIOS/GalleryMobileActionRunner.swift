import Foundation
import GallerySharedCore
import UIKit

struct GalleryChatActionResult {
  let message: String
  let widgetSnapshot: McpWidgetSnapshot?
  let approvalRequest: UgotMCPToolApprovalRequest?

  init(
    message: String,
    widgetSnapshot: McpWidgetSnapshot? = nil,
    approvalRequest: UgotMCPToolApprovalRequest? = nil
  ) {
    self.message = message
    self.widgetSnapshot = widgetSnapshot
    self.approvalRequest = approvalRequest
  }
}

enum GalleryCapabilityRoute: Equatable {
  case nativeSkill(String)
  case mcpConnector(String)
  case model
}

enum GalleryCapabilityRouter {
  static func route(
    prompt: String,
    activeSkillIds: Set<String>,
    activeConnectorIds: Set<String>
  ) -> GalleryCapabilityRoute {
    let request = GalleryCapabilityRouteRequest(
      prompt: prompt,
      activeSkillIds: activeSkillIds,
      activeConnectorIds: activeConnectorIds
    )
    return GalleryCapabilityRegistry
      .definitions
      .filter { $0.matches(request) }
      .sorted { lhs, rhs in
        if lhs.priority == rhs.priority {
          return lhs.id < rhs.id
        }
        return lhs.priority > rhs.priority
      }
      .first?
      .route ?? request.activeConnectorIds.sorted().first.map(GalleryCapabilityRoute.mcpConnector) ?? .model
  }
}

private struct GalleryCapabilityRouteRequest {
  let prompt: String
  let activeSkillIds: Set<String>
  let activeConnectorIds: Set<String>
  let intent: GalleryPromptIntent

  init(
    prompt: String,
    activeSkillIds: Set<String>,
    activeConnectorIds: Set<String>
  ) {
    self.prompt = prompt
    self.activeSkillIds = activeSkillIds
    self.activeConnectorIds = activeConnectorIds
    self.intent = GalleryPromptIntent(prompt)
  }
}

private struct GalleryCapabilityDefinition {
  let id: String
  let route: GalleryCapabilityRoute
  let priority: Int
  let matches: (GalleryCapabilityRouteRequest) -> Bool
}

private enum GalleryCapabilityRegistry {
  static let definitions: [GalleryCapabilityDefinition] = [
    GalleryCapabilityDefinition(
      id: "native.mobile-actions.maps",
      route: .nativeSkill(GalleryAgentSkill.mobileActionsId),
      priority: 1_000,
      matches: { request in
        // Device/app intents are native capabilities. They must be matched
        // before any MCP connector can inspect generic verbs such as
        // "open/show", otherwise an active connector can hijack OS actions.
        request.intent.isMapOpenRequest
      }
    ),
    // MCP connector routing is intentionally generic. If a connector is active,
    // the MCP tool planner will search/plan against that connector's own tool
    // metadata and return nil when no tool is needed. This keeps connector
    // domain knowledge out of the mobile host.
  ]
}

private struct GalleryPromptIntent {
  let normalized: String

  init(_ prompt: String) {
    normalized = prompt
      .lowercased()
      .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
  }

  var isMapOpenRequest: Bool {
    GalleryMobileActionRunner.isMapOpenRequest(normalizedPrompt: normalized)
  }

  private func containsAny(_ terms: [String]) -> Bool {
    terms.contains { normalized.contains($0) }
  }
}

enum GalleryMobileActionRunner {
  static func runIfNeeded(prompt: String, activeSkillIds: Set<String>) async -> GalleryChatActionResult? {
    guard isMapOpenRequest(prompt) else { return nil }

    guard activeSkillIds.contains(GalleryAgentSkill.mobileActionsId) else {
      return GalleryChatActionResult(message: "Mobile actions skill을 켜면 지도 앱을 열 수 있어요.")
    }

    return await MainActor.run {
      let url = mapURL(for: prompt)
      UIApplication.shared.open(url, options: [:])
      return GalleryChatActionResult(message: "지도 앱을 열었어요.")
    }
  }

  static func isMapOpenRequest(_ prompt: String) -> Bool {
    let normalized = prompt
      .lowercased()
      .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
    return isMapOpenRequest(normalizedPrompt: normalized)
  }

  static func isMapOpenRequest(normalizedPrompt normalized: String) -> Bool {
    if normalized.contains("지도") {
      return normalized.contains("열") ||
        normalized.contains("켜") ||
        normalized.contains("보여") ||
        normalized.contains("찾아") ||
        normalized == "지도"
    }

    return normalized.contains("openmaps") ||
      normalized.contains("openmap") ||
      normalized.contains("showmaps") ||
      normalized.contains("showmap")
  }

  private static func mapURL(for prompt: String) -> URL {
    let query = extractedMapQuery(from: prompt)
    if prefersNaverMaps(prompt) {
      return naverMapURL(query: query)
    }
    var components = URLComponents(string: "https://maps.apple.com/")!
    if let query, !query.isEmpty {
      components.queryItems = [URLQueryItem(name: "q", value: query)]
    }
    return components.url ?? URL(string: "https://maps.apple.com/")!
  }

  private static func prefersNaverMaps(_ prompt: String) -> Bool {
    let normalized = prompt
      .lowercased()
      .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
    return normalized.contains("네이버") || normalized.contains("naver")
  }

  private static func naverMapURL(query: String?) -> URL {
    guard let query, !query.isEmpty else {
      return URL(string: "https://map.naver.com/")!
    }
    let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? query
    return URL(string: "https://map.naver.com/p/search/\(encoded)") ?? URL(string: "https://map.naver.com/")!
  }

  private static func extractedMapQuery(from prompt: String) -> String? {
    var value = prompt
      .replacingOccurrences(of: "네이버", with: "")
      .replacingOccurrences(of: "naver", with: "", options: .caseInsensitive)
      .replacingOccurrences(of: "지도", with: "")
      .replacingOccurrences(of: "열어봐", with: "")
      .replacingOccurrences(of: "열어줘", with: "")
      .replacingOccurrences(of: "열어", with: "")
      .replacingOccurrences(of: "켜줘", with: "")
      .replacingOccurrences(of: "켜", with: "")
      .replacingOccurrences(of: "보여줘", with: "")
      .replacingOccurrences(of: "보여", with: "")
      .replacingOccurrences(of: "찾아줘", with: "")
      .replacingOccurrences(of: "찾아", with: "")
      .replacingOccurrences(of: "open", with: "", options: .caseInsensitive)
      .replacingOccurrences(of: "maps", with: "", options: .caseInsensitive)
      .replacingOccurrences(of: "map", with: "", options: .caseInsensitive)
      .trimmingCharacters(in: .whitespacesAndNewlines)

    while value.contains("  ") {
      value = value.replacingOccurrences(of: "  ", with: " ")
    }

    return value.isEmpty ? nil : value
  }
}
