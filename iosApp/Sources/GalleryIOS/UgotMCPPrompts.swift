import Foundation

struct UgotMCPPromptDescriptor: Identifiable, Hashable {
  let connectorId: String
  let connectorTitle: String
  let connectorSymbol: String
  let name: String
  let title: String
  let summary: String
  let requiredArguments: [String]

  var id: String { "\(connectorId)::\(name)" }

  init(connector: GalleryConnector, prompt: [String: Any]) {
    connectorId = connector.id
    connectorTitle = connector.title
    connectorSymbol = connector.symbol
    name = prompt["name"] as? String ?? "prompt"
    title =
      (prompt["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ??
      name.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ").capitalized
    summary = (prompt["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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
