import Foundation

enum UgotMCPLocale {
  static var preferredLanguageTag: String {
    let raw = Locale.preferredLanguages.first ?? Locale.current.identifier
    let normalized = raw
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "_", with: "-")
    return normalized.isEmpty ? "en" : normalized
  }

  static var acceptLanguageHeader: String {
    let tag = preferredLanguageTag
    let language = languageCode(from: tag)
    if language != tag {
      return "\(tag), \(language);q=0.9, en;q=0.7"
    }
    return "\(tag), en;q=0.7"
  }

  static func localizedString(
    in object: [String: Any],
    key: String,
    locale: String = preferredLanguageTag
  ) -> String? {
    if let direct = bestValue(in: object["\(key)_i18n"], locale: locale) {
      return direct
    }
    if let direct = bestValue(in: object["localized_\(key)"], locale: locale) {
      return direct
    }
    if let direct = bestLocalizationValue(in: object["localizations"], key: key, locale: locale) {
      return direct
    }
    if let direct = bestLocalizationValue(in: object["localized"], key: key, locale: locale) {
      return direct
    }
    if let meta = object["_meta"] as? [String: Any] {
      if let direct = bestValue(in: meta["\(key)_i18n"], locale: locale) {
        return direct
      }
      if let direct = bestLocalizationValue(in: meta["localizations"], key: key, locale: locale) {
        return direct
      }
      if let direct = bestLocalizationValue(in: meta["localized"], key: key, locale: locale) {
        return direct
      }
    }
    return (object[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
  }

  private static func bestValue(in raw: Any?, locale: String) -> String? {
    guard let values = raw as? [String: Any] else { return nil }
    for key in localeKeys(for: locale) {
      if let value = values[key] as? String,
         let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
        return trimmed
      }
    }
    return nil
  }

  private static func bestLocalizationValue(in raw: Any?, key: String, locale: String) -> String? {
    guard let localizations = raw as? [String: Any] else { return nil }
    for localeKey in localeKeys(for: locale) {
      if let localized = localizations[localeKey] as? [String: Any],
         let value = localized[key] as? String,
         let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
        return trimmed
      }
    }
    return nil
  }

  private static func localeKeys(for locale: String) -> [String] {
    let tag = locale
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "_", with: "-")
    let underscore = tag.replacingOccurrences(of: "-", with: "_")
    let language = languageCode(from: tag)
    var keys = [tag, underscore, language]
    if language != "en" {
      keys.append("en")
    }
    var seen = Set<String>()
    return keys.filter { !$0.isEmpty && seen.insert($0).inserted }
  }

  private static func languageCode(from tag: String) -> String {
    String(tag.split(separator: "-").first ?? Substring(tag)).lowercased()
  }
}


struct UgotMCPPromptArgumentDescriptor: Identifiable, Hashable {
  let name: String
  let summary: String
  let isRequired: Bool

  var id: String { name }
}

struct UgotMCPPromptCompletionResult: Hashable {
  let values: [String]
  let total: Int
  let hasMore: Bool

  static let empty = UgotMCPPromptCompletionResult(values: [], total: 0, hasMore: false)
}

enum UgotMCPIntentEffect {
  static func normalized(_ raw: String?, default defaultValue: String = "read") -> String {
    let value = raw?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacingOccurrences(of: "_", with: "-") ?? ""
    guard !value.isEmpty else { return defaultValue }

    if ["none", "no-tool", "notool", "model-only"].contains(value) { return "none" }
    if ["read", "readonly", "read-only", "view", "display", "search", "summarize", "summary", "explain"].contains(value) {
      return "read"
    }
    if ["write", "mutate", "mutation", "setting", "settings", "set", "update", "create", "send", "save"].contains(value) {
      return "write"
    }
    if ["destructive", "delete", "remove", "clear", "reset"].contains(value) {
      return "destructive"
    }
    return defaultValue
  }

  static func strongest(_ effects: [String]) -> String {
    effects
      .map { normalized($0) }
      .max { rank($0) < rank($1) } ?? "read"
  }

  static func rank(_ effect: String) -> Int {
    switch normalized(effect) {
    case "destructive": return 3
    case "write": return 2
    case "read": return 1
    default: return 0
    }
  }
}

struct UgotMCPContextAttachment: Identifiable, Hashable {
  enum Kind: String, Hashable {
    case prompt
    case resource
  }

  let id = UUID()
  let kind: Kind
  let connectorId: String
  let connectorTitle: String
  let title: String
  let summary: String
  let contextText: String
  let arguments: [String: String]
  let uri: String?
  let intentEffect: String

  init(
    kind: Kind,
    connectorId: String,
    connectorTitle: String,
    title: String,
    summary: String,
    contextText: String,
    arguments: [String: String],
    uri: String?,
    intentEffect: String = "read"
  ) {
    self.kind = kind
    self.connectorId = connectorId
    self.connectorTitle = connectorTitle
    self.title = title
    self.summary = summary
    self.contextText = contextText
    self.arguments = arguments
    self.uri = uri
    self.intentEffect = UgotMCPIntentEffect.normalized(intentEffect)
  }

  var symbol: String {
    switch kind {
    case .prompt: return "text.badge.star"
    case .resource: return "doc.richtext"
    }
  }

  var displayName: String { title }
}

struct UgotMCPPromptDescriptor: Identifiable, Hashable {
  let connectorId: String
  let connectorTitle: String
  let connectorSymbol: String
  let name: String
  let title: String
  let summary: String
  let arguments: [UgotMCPPromptArgumentDescriptor]
  let requiredArguments: [String]
  let intentEffect: String

  var id: String { "\(connectorId)::\(name)" }

  init(
    connector: GalleryConnector,
    prompt: [String: Any],
    locale: String = UgotMCPLocale.preferredLanguageTag
  ) {
    connectorId = connector.id
    connectorTitle = connector.title
    connectorSymbol = connector.symbol
    name = prompt["name"] as? String ?? "prompt"
    title =
      UgotMCPLocale.localizedString(in: prompt, key: "title", locale: locale) ??
      name.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ").capitalized
    summary = UgotMCPLocale.localizedString(in: prompt, key: "description", locale: locale) ?? ""
    intentEffect = UgotMCPIntentEffect.normalized(
      Self.intentEffectValue(in: prompt),
      default: "read"
    )
    if let rawArguments = prompt["arguments"] as? [[String: Any]] {
      arguments = rawArguments.compactMap { argument in
        guard let name = argument["name"] as? String else { return nil }
        return UgotMCPPromptArgumentDescriptor(
          name: name,
          summary: UgotMCPLocale.localizedString(in: argument, key: "description", locale: locale) ?? "",
          isRequired: (argument["required"] as? Bool) == true
        )
      }
      requiredArguments = arguments.filter(\.isRequired).map(\.name)
    } else {
      arguments = []
      requiredArguments = []
    }
  }

  private static func intentEffectValue(in prompt: [String: Any]) -> String? {
    let keys = ["mcp/intentEffect", "intentEffect", "intent_effect", "toolEffect", "tool_effect"]
    for key in keys {
      if let value = prompt[key] as? String,
         !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return value
      }
    }
    for containerKey in ["_meta", "meta"] {
      guard let meta = prompt[containerKey] as? [String: Any] else { continue }
      for key in keys {
        if let value = meta[key] as? String,
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          return value
        }
      }
    }
    return nil
  }
}


struct UgotMCPResourceDescriptor: Identifiable, Hashable {
  let connectorId: String
  let connectorTitle: String
  let connectorSymbol: String
  let uri: String
  let name: String
  let title: String
  let summary: String
  let mimeType: String?

  var id: String { "\(connectorId)::\(uri)" }

  var isUserVisible: Bool {
    let normalizedMime = (mimeType ?? "").lowercased()
    if UgotMCPClient.isSupportedWidgetMime(mimeType) { return false }
    if normalizedMime.contains("html") { return false }
    if title.localizedCaseInsensitiveContains("widget template") { return false }
    if uri.localizedCaseInsensitiveContains("widget") && normalizedMime.contains("html") { return false }
    return true
  }

  init(
    connector: GalleryConnector,
    resource: [String: Any],
    locale: String = UgotMCPLocale.preferredLanguageTag
  ) {
    connectorId = connector.id
    connectorTitle = connector.title
    connectorSymbol = connector.symbol
    uri = resource["uri"] as? String ?? resource["uriTemplate"] as? String ?? "resource"
    name = resource["name"] as? String ?? uri
    title =
      UgotMCPLocale.localizedString(in: resource, key: "title", locale: locale) ??
      UgotMCPLocale.localizedString(in: resource, key: "name", locale: locale) ??
      name.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ").capitalized
    summary = UgotMCPLocale.localizedString(in: resource, key: "description", locale: locale) ?? ""
    mimeType = resource["mimeType"] as? String ?? resource["mime_type"] as? String
  }
}

enum UgotMCPResourceRenderer {
  static func renderResourceText(
    _ result: [String: Any],
    resource: UgotMCPResourceDescriptor,
    maxCharacters: Int = 16_000
  ) -> String {
    let contents = result["contents"] as? [[String: Any]] ?? []
    let body = contents.compactMap(renderContent).filter { !$0.isEmpty }.joined(separator: "\n\n")
    var sections = ["# \(resource.title)"]
    if !resource.summary.isEmpty {
      sections.append(resource.summary)
    }
    sections.append("URI: \(resource.uri)")
    if let mimeType = resource.mimeType, !mimeType.isEmpty {
      sections.append("MIME: \(mimeType)")
    }
    if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      sections.append(body)
    }
    let text = sections.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    if text.count <= maxCharacters { return text }
    return String(text.prefix(maxCharacters)) + "\n\n…"
  }

  static func renderComposerSeed(
    _ result: [String: Any],
    resource: UgotMCPResourceDescriptor
  ) -> String {
    let text = renderResourceText(result, resource: resource)
    return """
    다음 MCP 리소스를 참고해서 답변해줘.

    \(text)
    """
    .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func renderContent(_ item: [String: Any]) -> String? {
    if let text = item["text"] as? String {
      return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if let resource = item["resource"] as? [String: Any] {
      return renderContent(resource)
    }
    if let blob = item["blob"] as? String, !blob.isEmpty {
      let mimeType = item["mimeType"] as? String ?? item["mime_type"] as? String ?? "binary"
      return "[\(mimeType) resource: \(blob.count) base64 characters]"
    }
    return nil
  }
}

enum UgotMCPPromptRenderer {
  static func renderPromptText(_ result: [String: Any], fallbackTitle: String) -> String {
    let messages = result["messages"] as? [[String: Any]] ?? []
    let renderedMessages = messages.compactMap(renderMessage).filter { !$0.isEmpty }
    if !renderedMessages.isEmpty {
      return renderedMessages.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if let description = UgotMCPLocale.localizedString(in: result, key: "description"),
       !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return description.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if let text = UgotMCPLocale.localizedString(in: result, key: "text"),
       !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return fallbackTitle
  }

  private static func renderMessage(_ message: [String: Any]) -> String? {
    if let content = message["content"] {
      return renderContent(content)
    }
    if let text = message["text"] as? String {
      return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return nil
  }

  private static func renderContent(_ content: Any) -> String? {
    if let string = content as? String {
      return string.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if let block = content as? [String: Any] {
      if let text = block["text"] as? String {
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
      }
      if let resource = block["resource"] as? [String: Any],
         let text = resource["text"] as? String {
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
      }
    }
    if let blocks = content as? [[String: Any]] {
      let rendered = blocks.compactMap(renderContent).filter { !$0.isEmpty }
      return rendered.isEmpty ? nil : rendered.joined(separator: "\n\n")
    }
    return nil
  }
}

private extension String {
  var nilIfEmpty: String? {
    isEmpty ? nil : self
  }
}
