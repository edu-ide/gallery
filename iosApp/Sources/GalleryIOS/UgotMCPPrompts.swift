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

struct UgotMCPPromptDescriptor: Identifiable, Hashable {
  let connectorId: String
  let connectorTitle: String
  let connectorSymbol: String
  let name: String
  let title: String
  let summary: String
  let requiredArguments: [String]

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
    if let arguments = prompt["arguments"] as? [[String: Any]] {
      requiredArguments = arguments.compactMap { argument in
        guard (argument["required"] as? Bool) == true else { return nil }
        return argument["name"] as? String
      }
    } else {
      requiredArguments = []
    }
  }
}

enum UgotMCPPromptRenderer {
  static func renderPromptText(_ result: [String: Any], fallbackTitle: String) -> String {
    let messages = result["messages"] as? [[String: Any]] ?? []
    let renderedMessages = messages.compactMap(renderMessage).filter { !$0.isEmpty }
    if !renderedMessages.isEmpty {
      return renderedMessages.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if let description = result["description"] as? String,
       !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return description.trimmingCharacters(in: .whitespacesAndNewlines)
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
