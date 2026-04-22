import Foundation
import GallerySharedCore
import SwiftUI
import WebKit

enum UgotMCPWidgetDebugLog {
  static let isEnabled = false

  static func append(_ message: String) {
    guard isEnabled else { return }
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] \(message)\n"
    guard let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
      .appendingPathComponent("UgotMCPWidgetDebug.log") else { return }
    if let data = line.data(using: .utf8), FileManager.default.fileExists(atPath: url.path) {
      if let handle = try? FileHandle(forWritingTo: url) {
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
        try? handle.close()
      }
    } else {
      try? line.write(to: url, atomically: true, encoding: .utf8)
    }
  }
}

struct UgotMCPWidgetWebView: UIViewRepresentable {
  let snapshot: McpWidgetSnapshot
  var onSizeChanged: ((CGFloat) -> Void)?
  var onModelContextChanged: ((String) -> Void)?
  var onRenderFailure: ((String) -> Void)?

  func makeCoordinator() -> Coordinator {
    Coordinator(
      snapshot: snapshot,
      onSizeChanged: onSizeChanged,
      onModelContextChanged: onModelContextChanged,
      onRenderFailure: onRenderFailure
    )
  }

  func makeUIView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = true
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
    configuration.userContentController.add(context.coordinator, name: "mcpWidget")

    let webView = WKWebView(frame: .zero, configuration: configuration)
    context.coordinator.webView = webView
    webView.isOpaque = false
    webView.backgroundColor = .clear
    webView.scrollView.backgroundColor = .clear
    webView.scrollView.isScrollEnabled = false
    webView.scrollView.bounces = false
    webView.navigationDelegate = context.coordinator
    load(snapshot: snapshot, into: webView, coordinator: context.coordinator)
    return webView
  }

  func updateUIView(_ uiView: WKWebView, context: Context) {
    context.coordinator.onSizeChanged = onSizeChanged
    context.coordinator.onModelContextChanged = onModelContextChanged
    context.coordinator.onRenderFailure = onRenderFailure
    guard context.coordinator.snapshot.widgetStateJson != snapshot.widgetStateJson else { return }
    context.coordinator.snapshot = snapshot
    load(snapshot: snapshot, into: uiView, coordinator: context.coordinator)
  }

  private func load(snapshot: McpWidgetSnapshot, into webView: WKWebView, coordinator: Coordinator) {
    guard let payload = UgotMCPWidgetHostPayload(snapshot: snapshot) else {
      webView.loadHTMLString("<html><body></body></html>", baseURL: nil)
      return
    }
    coordinator.didReportRenderFailure = false
    UgotMCPWidgetDebugLog.append(
      "load hostShell html=\(payload.widgetHtmlLength) outer=\(payload.hostHTML.count) base=\(payload.hostBaseURL?.absoluteString ?? "nil") tool=\(payload.toolName ?? "")"
    )
    webView.loadHTMLString(payload.hostHTML, baseURL: payload.hostBaseURL)
  }

  final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    var snapshot: McpWidgetSnapshot
    var onSizeChanged: ((CGFloat) -> Void)?
    var onModelContextChanged: ((String) -> Void)?
    var onRenderFailure: ((String) -> Void)?
    weak var webView: WKWebView?
    var didReportRenderFailure = false
    private var lastReportedHeight: CGFloat = 0
    private var lastHeightReportTime: TimeInterval = 0

    init(
      snapshot: McpWidgetSnapshot,
      onSizeChanged: ((CGFloat) -> Void)?,
      onModelContextChanged: ((String) -> Void)?,
      onRenderFailure: ((String) -> Void)?
    ) {
      self.snapshot = snapshot
      self.onSizeChanged = onSizeChanged
      self.onModelContextChanged = onModelContextChanged
      self.onRenderFailure = onRenderFailure
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
      guard message.name == "mcpWidget",
            let payload = message.body as? [String: Any],
            let type = payload["type"] as? String else {
        return
      }

      switch type {
      case "openExternal":
        guard let rawURL = payload["url"] as? String, let url = URL(string: rawURL) else { return }
        DispatchQueue.main.async { UIApplication.shared.open(url) }
      case "modelContext":
        reportModelContext(payload)
      case "setWidgetState", "appMessage", "displayMode":
        break
      case "sizeChanged":
        reportSizeChanged(payload)
      case "callTool":
        handleLegacyToolCall(payload)
      case "mcpRequest":
        handleMCPRequest(payload)
      case "debug":
        let message = payload["message"] as? String ?? ""
        UgotMCPWidgetDebugLog.append("js \(message)")
        if message.contains("mount-error") ||
          message.contains("host-shell-load-error") ||
          message.contains("SyntaxError") ||
          message.contains("window.error") ||
          message.contains("unhandledrejection") {
          reportRenderFailure(message)
        }
      default:
        break
      }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      UgotMCPWidgetDebugLog.append("webview host didFinish")
      guard UgotMCPWidgetDebugLog.isEnabled else { return }
      inspect(webView, label: "host")
      DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self, weak webView] in
        guard let self, let webView else { return }
        self.inspect(webView, label: "host-delayed")
      }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
      UgotMCPWidgetDebugLog.append("webview didFail=\(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
      UgotMCPWidgetDebugLog.append("webview didFailProvisional=\(error.localizedDescription)")
    }

    private func inspect(_ webView: WKWebView, label: String) {
      let script = """
      (() => {
        const frame = document.getElementById('ugot-mcp-app-frame');
        let frameInfo = null;
        try {
          const doc = frame && (frame.contentDocument || frame.contentWindow?.document);
          frameInfo = doc ? {
            title: doc.title || '',
            readyState: doc.readyState || '',
            bodyLength: doc.body ? doc.body.innerHTML.length : -1,
            bodyText: doc.body ? doc.body.innerText.slice(0, 700) : '',
            bodyScrollHeight: doc.body ? doc.body.scrollHeight : -1,
            htmlScrollHeight: doc.documentElement ? doc.documentElement.scrollHeight : -1,
            frameStyleHeight: frame.style.height || '',
            scriptCount: doc.scripts ? doc.scripts.length : -1,
            hasOpenAI: !!frame.contentWindow?.openai,
            hasCompatOpenAI: !!frame.contentWindow?.__mcpAppsCompatOpenAI
          } : null;
        } catch (error) {
          frameInfo = { error: error && (error.message || String(error)) };
        }
        return {
          label: \(UgotMCPWidgetHostPayload.jsString(label)),
          title: document.title || '',
          readyState: document.readyState || '',
          bodyLength: document.body ? document.body.innerHTML.length : -1,
          bodyText: document.body ? document.body.innerText.slice(0, 300) : '',
          hasHost: !!window.UgotMCPAppsHost,
          frame: frameInfo
        };
      })()
      """
      webView.evaluateJavaScript(script) { result, error in
        if let error {
          UgotMCPWidgetDebugLog.append("webview inspect \(label) error=\(error.localizedDescription)")
        } else {
          UgotMCPWidgetDebugLog.append("webview inspect \(label)=\(String(describing: result))")
        }
      }
    }

    private func handleLegacyToolCall(_ payload: [String: Any]) {
      guard let requestId = payload["id"] as? String,
            let toolName = payload["name"] as? String else {
        return
      }
      let arguments = payload["arguments"] as? [String: Any] ?? [:]
      handleMCPRequest([
        "id": requestId,
        "method": "tools/call",
        "params": [
          "name": toolName,
          "arguments": arguments,
        ],
      ])
    }

    private func reportRenderFailure(_ message: String) {
      guard !didReportRenderFailure else { return }
      didReportRenderFailure = true
      DispatchQueue.main.async { [onRenderFailure] in
        onRenderFailure?(message)
      }
    }

    private func reportSizeChanged(_ payload: [String: Any]) {
      guard let rawHeight = payload["height"] as? NSNumber else { return }
      let height = max(180, min(12_000, CGFloat(truncating: rawHeight)))
      let now = ProcessInfo.processInfo.systemUptime
      guard abs(height - lastReportedHeight) > 1.0 || now - lastHeightReportTime > 0.5 else {
        return
      }
      lastReportedHeight = height
      lastHeightReportTime = now
      DispatchQueue.main.async { [onSizeChanged] in
        onSizeChanged?(height)
      }
    }

    private func reportModelContext(_ payload: [String: Any]) {
      guard let rawContext = payload["modelContext"] else { return }
      let rendered = Self.renderModelContext(rawContext)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !rendered.isEmpty else { return }
      UgotMCPWidgetDebugLog.append("modelContext chars=\(rendered.count) preview=\(String(rendered.prefix(500)))")
      DispatchQueue.main.async { [onModelContextChanged] in
        onModelContextChanged?(rendered)
      }
    }

    private static func renderModelContext(_ value: Any) -> String {
      guard let dict = value as? [String: Any] else {
        return compactJSON(value)
      }

      var sections: [String] = []
      if let content = dict["content"] as? [[String: Any]] {
        let contentText = content.compactMap(renderContentBlock).joined(separator: "\n\n")
        if !contentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          sections.append(contentText)
        }
      }
      if let structured = dict["structuredContent"] ?? dict["structured_content"] {
        let json = compactJSON(structured)
        if !json.isEmpty && json != "{}" {
          sections.append("Structured widget context:\n\(json)")
        }
      }
      if sections.isEmpty {
        sections.append(compactJSON(dict))
      }
      return sections.joined(separator: "\n\n")
    }

    private static func renderContentBlock(_ block: [String: Any]) -> String? {
      let type = (block["type"] as? String)?.lowercased() ?? ""
      switch type {
      case "text":
        return block["text"] as? String
      case "resource":
        if let resource = block["resource"] as? [String: Any] {
          return resourceContextSummary(resource)
        }
        return nil
      case "resource_link", "resourcelink":
        let name = block["name"] as? String
        let uri = block["uri"] as? String
        return [name, uri].compactMap { $0 }.joined(separator: " — ")
      case "image", "audio":
        let mimeType = block["mimeType"] as? String ?? block["mime_type"] as? String ?? type
        return "[\(type) context: \(mimeType)]"
      default:
        if let text = block["text"] as? String {
          return text
        }
        return compactJSON(block)
      }
    }

    private static func compactJSON(_ value: Any) -> String {
      let compact = UgotMCPClient.compactForWidget(value, maxStringLength: 12_000, maxArrayCount: 40)
      guard JSONSerialization.isValidJSONObject(compact),
            let data = try? JSONSerialization.data(withJSONObject: compact, options: [.sortedKeys]),
            let json = String(data: data, encoding: .utf8) else {
        return String(describing: value)
      }
      return json
    }

    private static func resourceContextSummary(_ resource: [String: Any]) -> String? {
      let uri = resource["uri"] as? String ?? "embedded-resource"
      let mimeType = resource["mimeType"] as? String ?? resource["mime_type"] as? String ?? "unknown"
      let text = resource["text"] as? String ?? ""
      var parts = ["Resource: \(uri) (\(mimeType)"]
      if !text.isEmpty {
        parts[0] += ", \(text.count) chars"
      }
      parts[0] += ")"
      if let keys = jsonTopLevelKeys(from: text), !keys.isEmpty {
        let joinedKeys = keys.joined(separator: ", ")
        parts.append("Keys: \(joinedKeys)")
      } else if !text.isEmpty {
        parts.append("Preview: \(String(text.prefix(500)))")
      }
      return parts.joined(separator: "\n")
    }

    private static func jsonTopLevelKeys(from text: String) -> [String]? {
      guard let data = text.data(using: .utf8),
            let parsed = try? JSONSerialization.jsonObject(with: data) else {
        return nil
      }
      if let dict = parsed as? [String: Any] {
        return Array(dict.keys.sorted().prefix(24))
      }
      if let array = parsed as? [Any],
         let dict = array.first as? [String: Any] {
        return Array(dict.keys.sorted().prefix(24)).map { "items[].\($0)" }
      }
      return nil
    }

    private func handleMCPRequest(_ payload: [String: Any]) {
      guard let requestId = payload["id"] as? String,
            let method = payload["method"] as? String else {
        return
      }
      let params = payload["params"] as? [String: Any] ?? [:]

      Task {
        do {
          let client = try await makeClient()
          let result: [String: Any]
          switch method {
          case "tools/call":
            guard let toolName = params["name"] as? String else {
              throw WidgetBridgeError.invalidRequest("tools/call missing name")
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            result = try await client.callTool(name: toolName, arguments: arguments)
          case "resources/list":
            result = ["resources": try await client.listResources()]
          case "resources/read":
            guard let uri = params["uri"] as? String else {
              throw WidgetBridgeError.invalidRequest("resources/read missing uri")
            }
            result = try await client.readResource(uri: uri) ?? ["contents": []]
          case "resources/templates/list":
            result = ["resourceTemplates": []]
          default:
            throw WidgetBridgeError.invalidRequest("Unsupported MCP method: \(method)")
          }
          let compact = UgotMCPClient.compactForWidget(result, maxStringLength: 180_000, maxArrayCount: 160)
          resolveMCPRequest(id: requestId, result: compact)
        } catch {
          rejectMCPRequest(id: requestId, message: error.localizedDescription)
        }
      }
    }

    private func makeClient() async throws -> UgotMCPClient {
      guard let accessToken = try await UgotAuthStore.validAccessToken() else {
        throw WidgetBridgeError.missingAuth
      }
      let state = snapshot.widgetStateDictionary ?? [:]
      let endpointString = (state["endpoint"] as? String) ??
        GalleryConnector.endpoint(for: snapshot.connectorId) ??
        snapshot.connectorId
      guard let endpoint = URL(string: endpointString) else {
        throw WidgetBridgeError.invalidRequest("Invalid MCP endpoint")
      }
      return UgotMCPClient(
        connectorId: snapshot.connectorId,
        endpoint: endpoint,
        accessToken: accessToken
      )
    }

    @MainActor
    private func resolveMCPRequest(id: String, result: Any) {
      let resultJson = UgotMCPWidgetHostPayload.jsonLiteral(result)
      let idJson = UgotMCPWidgetHostPayload.jsString(id)
      evaluate("window.UgotMCPAppsHost && window.UgotMCPAppsHost.resolveNative(\(idJson), \(resultJson)); window.__ugotMcpResolveRequest && window.__ugotMcpResolveRequest(\(idJson), \(resultJson));")
    }

    @MainActor
    private func rejectMCPRequest(id: String, message: String) {
      let idJson = UgotMCPWidgetHostPayload.jsString(id)
      let messageJson = UgotMCPWidgetHostPayload.jsString(message)
      evaluate("window.UgotMCPAppsHost && window.UgotMCPAppsHost.rejectNative(\(idJson), \(messageJson)); window.__ugotMcpRejectRequest && window.__ugotMcpRejectRequest(\(idJson), \(messageJson));")
    }

    @MainActor
    private func evaluate(_ script: String) {
      webView?.evaluateJavaScript(script)
    }

    private enum WidgetBridgeError: LocalizedError {
      case missingAuth
      case invalidRequest(String)

      var errorDescription: String? {
        switch self {
        case .missingAuth:
          return "UGOT 로그인이 필요해요."
        case .invalidRequest(let message):
          return message
        }
      }
    }
  }
}

private struct UgotMCPWidgetHostPayload {
  let hostHTML: String
  let hostBaseURL: URL?
  let widgetHtmlLength: Int
  let toolName: String?

  init?(snapshot: McpWidgetSnapshot) {
    guard let state = snapshot.widgetStateDictionary else { return nil }
    let htmlBase64 = state["widgetHtmlBase64"] as? String
    let rawHtml = htmlBase64
      .flatMap { Data(base64Encoded: $0) }
      .flatMap { String(data: $0, encoding: .utf8) }
    guard let rawHtml, !rawHtml.isEmpty else { return nil }

    self.widgetHtmlLength = rawHtml.count
    self.toolName = state["toolName"] as? String

    var widgetState = state
    widgetState.removeValue(forKey: "widgetHtmlBase64")
    widgetState.removeValue(forKey: "widgetBaseUrl")
    widgetState.removeValue(forKey: "rawResult")
    widgetState.removeValue(forKey: "toolResult")
    widgetState.removeValue(forKey: "toolOutput")

    let toolResult = state["rawResult"] ?? state["toolResult"] ?? state["toolOutput"] ?? [:]
    let config: [String: Any] = [
      "widgetHtml": rawHtml,
      "widgetBaseUrl": state["widgetBaseUrl"] as? String ?? "",
      "toolName": state["toolName"] as? String ?? "",
      "toolInput": state["toolInput"] ?? [:],
      "toolResult": toolResult,
      "toolDefinition": state["toolDefinition"] ?? [:],
      "widgetState": widgetState,
      "locale": "ko",
      "maxHeight": 12_000,
    ]

    let configJson = Self.jsonString(config)
    let safeConfigJson = configJson
      .replacingOccurrences(of: "</", with: "<\\/")
      .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
      .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    let template = Self.hostShellTemplate()
    self.hostHTML = template.replacingOccurrences(of: "__UGOT_MCP_CONFIG__", with: safeConfigJson)
    self.hostBaseURL = Self.hostShellBaseURL()
  }

  static func hostShellBaseURL() -> URL? {
    Bundle.main.url(forResource: "host-shell", withExtension: "html", subdirectory: "MCPAppsHost")?
      .deletingLastPathComponent()
  }

  static func hostShellTemplate() -> String {
    if let url = Bundle.main.url(forResource: "host-shell", withExtension: "html", subdirectory: "MCPAppsHost"),
       let template = try? String(contentsOf: url, encoding: .utf8) {
      return template
    }
    return """
    <!doctype html>
    <html>
    <head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1,viewport-fit=cover\"></head>
    <body style=\"margin:0;background:transparent;overflow:hidden;\">
      <div id=\"ugot-mcp-host-root\"></div>
      <script id=\"ugot-mcp-config\" type=\"application/json\">__UGOT_MCP_CONFIG__</script>
      <script src=\"host-shell.js\"></script>
    </body>
    </html>
    """
  }

  static func jsString(_ value: String?) -> String {
    jsonLiteral(value ?? "")
  }

  static func jsonLiteral(_ value: Any) -> String {
    if value is NSNull { return "null" }

    if let dictionary = value as? [String: Any], JSONSerialization.isValidJSONObject(dictionary),
       let data = try? JSONSerialization.data(withJSONObject: dictionary),
       let json = String(data: data, encoding: .utf8) {
      return json
    }

    if let array = value as? [Any], JSONSerialization.isValidJSONObject(array),
       let data = try? JSONSerialization.data(withJSONObject: array),
       let json = String(data: data, encoding: .utf8) {
      return json
    }

    let fragment: Any
    if let string = value as? String {
      fragment = string
    } else if let bool = value as? Bool {
      fragment = bool
    } else if let number = value as? NSNumber {
      fragment = number
    } else {
      fragment = String(describing: value)
    }

    guard JSONSerialization.isValidJSONObject([fragment]),
          let data = try? JSONSerialization.data(withJSONObject: [fragment]),
          let wrapped = String(data: data, encoding: .utf8),
          wrapped.count >= 2 else {
      return "null"
    }
    return String(wrapped.dropFirst().dropLast())
  }

  static func jsonString(_ value: Any) -> String {
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value),
          let json = String(data: data, encoding: .utf8) else {
      if value is NSNull { return "null" }
      return "{}"
    }
    return json
  }
}

private extension McpWidgetSnapshot {
  var widgetStateDictionary: [String: Any]? {
    guard let data = widgetStateJson.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }
}
