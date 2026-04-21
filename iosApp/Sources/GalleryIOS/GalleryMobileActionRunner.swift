import Foundation
import GallerySharedCore
import UIKit

struct GalleryChatActionResult {
  let message: String
  let widgetSnapshot: McpWidgetSnapshot?

  init(message: String, widgetSnapshot: McpWidgetSnapshot? = nil) {
    self.message = message
    self.widgetSnapshot = widgetSnapshot
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

  private static func isMapOpenRequest(_ prompt: String) -> Bool {
    let normalized = prompt
      .lowercased()
      .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)

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
    var components = URLComponents(string: "https://maps.apple.com/")!
    if let query, !query.isEmpty {
      components.queryItems = [URLQueryItem(name: "q", value: query)]
    }
    return components.url ?? URL(string: "https://maps.apple.com/")!
  }

  private static func extractedMapQuery(from prompt: String) -> String? {
    var value = prompt
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
