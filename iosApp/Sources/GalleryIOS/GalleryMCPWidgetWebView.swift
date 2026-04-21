import Foundation
import GallerySharedCore
import SwiftUI
import WebKit

struct GalleryMCPWidgetWebView: UIViewRepresentable {
  let snapshot: McpWidgetSnapshot

  func makeCoordinator() -> Coordinator {
    Coordinator(snapshot: snapshot)
  }

  func makeUIView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = true
    configuration.userContentController.add(context.coordinator, name: "mcpWidget")

    let webView = WKWebView(frame: .zero, configuration: configuration)
    context.coordinator.webView = webView
    webView.isOpaque = false
    webView.backgroundColor = .clear
    webView.scrollView.backgroundColor = .clear
    webView.scrollView.isScrollEnabled = true
    webView.navigationDelegate = context.coordinator
    load(snapshot: snapshot, into: webView)
    return webView
  }

  func updateUIView(_ uiView: WKWebView, context: Context) {
    guard context.coordinator.snapshot.widgetStateJson != snapshot.widgetStateJson else { return }
    context.coordinator.snapshot = snapshot
    load(snapshot: snapshot, into: uiView)
  }

  private func load(snapshot: McpWidgetSnapshot, into webView: WKWebView) {
    guard let payload = GalleryMCPWidgetPayload(snapshot: snapshot) else {
      webView.loadHTMLString("<html><body></body></html>", baseURL: nil)
      return
    }
    webView.loadHTMLString(payload.injectedHTML, baseURL: payload.baseURL)
  }

  final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    var snapshot: McpWidgetSnapshot
    weak var webView: WKWebView?

    init(snapshot: McpWidgetSnapshot) {
      self.snapshot = snapshot
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
      case "setWidgetState":
        // Future: persist widget state back into the KMP session. The current snapshot remains the
        // source of truth for restored views.
        break
      case "callTool":
        handleToolCall(payload)
      default:
        break
      }
    }

    private func handleToolCall(_ payload: [String: Any]) {
      guard snapshot.connectorId == GalleryConnector.fortuneMcpId,
            let requestId = payload["id"] as? String,
            let toolName = payload["name"] as? String else {
        return
      }
      let arguments = payload["arguments"] as? [String: Any] ?? [:]

      Task {
        do {
          guard let accessToken = UgotAuthStore.accessToken() else {
            throw WidgetBridgeError.missingAuth
          }
          let client = GalleryFortuneMCPClient(accessToken: accessToken)
          let result = try await client.callToolForWidget(name: toolName, arguments: arguments)
          await resolveToolCall(id: requestId, result: result)
        } catch {
          await rejectToolCall(id: requestId, message: error.localizedDescription)
        }
      }
    }

    @MainActor
    private func resolveToolCall(id: String, result: [String: Any]) {
      let resultJson = GalleryMCPWidgetPayload.jsonLiteral(result)
      evaluate("window.__galleryMcpResolveCall && window.__galleryMcpResolveCall(\(GalleryMCPWidgetPayload.jsString(id)), \(resultJson));")
    }

    @MainActor
    private func rejectToolCall(id: String, message: String) {
      evaluate("window.__galleryMcpRejectCall && window.__galleryMcpRejectCall(\(GalleryMCPWidgetPayload.jsString(id)), \(GalleryMCPWidgetPayload.jsString(message)));")
    }

    @MainActor
    private func evaluate(_ script: String) {
      webView?.evaluateJavaScript(script)
    }

    private enum WidgetBridgeError: LocalizedError {
      case missingAuth
      var errorDescription: String? { "UGOT 로그인이 필요해요." }
    }
  }
}

private struct GalleryMCPWidgetPayload {
  let html: String
  let baseURL: URL?
  let toolName: String?
  let toolInputJson: String
  let toolOutputJson: String
  let widgetStateJson: String

  init?(snapshot: McpWidgetSnapshot) {
    guard let state = snapshot.widgetStateDictionary else { return nil }
    let htmlBase64 = state["widgetHtmlBase64"] as? String
    let rawHtml = htmlBase64
      .flatMap { Data(base64Encoded: $0) }
      .flatMap { String(data: $0, encoding: .utf8) }
    guard let rawHtml, !rawHtml.isEmpty else { return nil }

    self.html = rawHtml
    self.baseURL = (state["widgetBaseUrl"] as? String).flatMap(URL.init(string:))
    self.toolName = state["toolName"] as? String
    self.toolInputJson = Self.jsonString(state["toolInput"] ?? [:])
    self.toolOutputJson = Self.jsonString(state["toolOutput"] ?? state["rawResult"] ?? NSNull())

    var widgetState = state
    widgetState.removeValue(forKey: "widgetHtmlBase64")
    widgetState.removeValue(forKey: "widgetBaseUrl")
    self.widgetStateJson = Self.jsonString(widgetState)
  }

  var injectedHTML: String {
    let bridge = Self.bridgeScript(
      toolName: toolName,
      toolInputJson: toolInputJson,
      toolOutputJson: toolOutputJson,
      widgetStateJson: widgetStateJson
    )
    if html.range(of: "<head>", options: [.caseInsensitive]) != nil {
      return html.replacingOccurrences(
        of: "<head>",
        with: "<head>\n\(bridge)",
        options: [.caseInsensitive],
        range: nil
      )
    }
    return "\(bridge)\n\(html)"
  }

  static func bridgeScript(toolName: String?, toolInputJson: String, toolOutputJson: String, widgetStateJson: String) -> String {
    """
    <script>
    (function() {
      const parseJson = (raw, fallback) => {
        try { return raw ? JSON.parse(raw) : fallback; }
        catch (error) { console.warn('[McpUiHost] JSON parse failed', error); return fallback; }
      };
      const postNative = (payload) => {
        try { window.webkit.messageHandlers.mcpWidget.postMessage(payload || {}); }
        catch (error) { console.warn('[McpUiHost] native bridge missing', error); }
      };
      const postJsonRpc = (message) => window.postMessage(Object.assign({ jsonrpc: '2.0' }, message || {}), '*');
      const notifyMcpApp = (method, params) => postJsonRpc({ method, params: params || {} });
      const dispatchGlobals = (globals) => window.dispatchEvent(new CustomEvent('openai:set_globals', { detail: { globals } }));
      const pending = {};
      let callId = 1;
      const hostContext = {
        theme: window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light',
        locale: navigator.language || 'ko',
        platform: 'ios',
        displayMode: 'inline',
        userAgent: navigator.userAgent,
      };
      const updateWidgetState = (nextState) => {
        host.widgetState = nextState || {};
        postNative({ type: 'setWidgetState', widgetState: host.widgetState });
        dispatchGlobals({ widgetState: host.widgetState });
      };
      const host = {
        __hostType: 'mcp-apps',
        __connected: true,
        toolName: \(jsString(toolName)),
        toolInput: parseJson(\(jsString(toolInputJson)), {}),
        toolOutput: parseJson(\(jsString(toolOutputJson)), null),
        toolResponseMetadata: {},
        widgetState: parseJson(\(jsString(widgetStateJson)), {}),
        theme: hostContext.theme,
        locale: hostContext.locale,
        displayMode: 'inline',
        maxHeight: null,
        userAgent: navigator.userAgent,
        view: {},
        modelContext: null,
        callTool(name, args) {
          const id = String(callId++);
          notifyMcpApp('ui/notifications/tool-input', { arguments: args || {} });
          return new Promise((resolve, reject) => {
            pending[id] = { resolve, reject };
            postNative({ type: 'callTool', id, name, arguments: args || {} });
          });
        },
        setWidgetState(nextState) {
          const merged = Object.assign({}, host.widgetState || {}, nextState || {});
          updateWidgetState(merged);
          return Promise.resolve(merged);
        },
        requestDisplayMode({ mode } = {}) {
          host.displayMode = mode || 'inline';
          hostContext.displayMode = host.displayMode;
          document.documentElement.dataset.displayMode = host.displayMode;
          notifyMcpApp('ui/notifications/host-context-changed', hostContext);
          dispatchGlobals({ displayMode: host.displayMode, theme: host.theme, locale: host.locale });
          return Promise.resolve({ mode: host.displayMode });
        },
        requestModal(payload = {}) { return Promise.resolve(payload); },
        requestClose() { return Promise.resolve(true); },
        updateModelContext(payload = {}) { host.modelContext = payload; return Promise.resolve(payload); },
        sendFollowUpMessage(payload = {}) { return Promise.resolve(payload); },
        openExternal({ href, url } = {}) {
          const target = href || url;
          if (target) postNative({ type: 'openExternal', url: target });
          return Promise.resolve({ href: target });
        },
        notifyIntrinsicHeight(height) { host.maxHeight = height || null; return Promise.resolve({ height }); },
        notifyToolsListChanged() { return Promise.resolve(true); }
      };
      const mcpApp = {
        callTool(name, args) { return host.callTool(name, args || {}); },
        sendMessage(text, role) {
          host.lastMessage = { role: role || 'user', content: [{ type: 'text', text: String(text || '') }] };
          return Promise.resolve({});
        },
        updateContext(contentBlocks) { host.modelContext = { content: Array.isArray(contentBlocks) ? contentBlocks : [{ type: 'text', text: String(contentBlocks || '') }] }; return Promise.resolve({}); },
        openLink(url) { if (url) postNative({ type: 'openExternal', url }); return Promise.resolve({}); },
        get hostContext() { return hostContext; },
        get initialized() { return true; },
        onToolInput(callback) { if (typeof callback === 'function') callback({ arguments: host.toolInput || {} }); },
        onToolResult(callback) { if (typeof callback === 'function' && host.toolOutput != null) callback(host.toolOutput); },
        onToolCancelled(callback) {},
        onHostContextChanged(callback) { if (typeof callback === 'function') callback(hostContext); },
        onTeardown(callback) {},
      };
      window.__galleryMcpResolveCall = (id, result) => {
        const item = pending[id];
        if (!item) return;
        delete pending[id];
        host.toolOutput = result;
        host.toolResponseMetadata = result && result._meta ? result._meta : {};
        updateWidgetState(Object.assign({}, host.widgetState || {}, { lastToolOutput: result, currentToolName: host.toolName }));
        notifyMcpApp('ui/notifications/tool-result', result || {});
        dispatchGlobals({ toolOutput: host.toolOutput, toolResponseMetadata: host.toolResponseMetadata, widgetState: host.widgetState });
        item.resolve(result);
      };
      window.__galleryMcpRejectCall = (id, message) => {
        const item = pending[id];
        if (!item) return;
        delete pending[id];
        item.reject(new Error(message || 'Tool call failed'));
      };
      window.__mcpBridge = (message) => {
        if (!message || message.jsonrpc !== '2.0' || !message.method) return;
        const id = message.id;
        const respond = (result) => postJsonRpc({ id, result: result || {} });
        switch (message.method) {
          case 'ui/initialize':
            respond({ protocolVersion: '2026-01-26', hostInfo: { name: 'gallery-ios', version: '0.1.0' }, hostCapabilities: { serverTools: {}, openLinks: {}, logging: {} }, hostContext });
            notifyMcpApp('ui/notifications/host-context-changed', hostContext);
            notifyMcpApp('ui/notifications/tool-input', { arguments: host.toolInput || {} });
            if (host.toolOutput != null) notifyMcpApp('ui/notifications/tool-result', host.toolOutput || {});
            break;
          case 'tools/call':
            host.callTool(message.params && message.params.name, (message.params && message.params.arguments) || {}).then(respond);
            break;
          case 'ui/open-link':
            mcpApp.openLink(message.params && message.params.url); respond({}); break;
          case 'ping': respond({}); break;
          default: postJsonRpc({ id, error: { code: -32603, message: 'Unsupported MCP bridge method: ' + message.method } });
        }
      };
      window.mcpApp = mcpApp;
      window.__mcpAppsCompatOpenAI = host;
      window.openai = host;
      document.documentElement.lang = host.locale || document.documentElement.lang || 'ko';
      document.documentElement.dataset.displayMode = host.displayMode;
      dispatchGlobals({ toolName: host.toolName, toolInput: host.toolInput, toolOutput: host.toolOutput, toolResponseMetadata: host.toolResponseMetadata, widgetState: host.widgetState, theme: host.theme, locale: host.locale, displayMode: host.displayMode });
      setTimeout(() => {
        notifyMcpApp('ui/notifications/host-context-changed', hostContext);
        notifyMcpApp('ui/notifications/tool-input', { arguments: host.toolInput || {} });
        if (host.toolOutput != null) notifyMcpApp('ui/notifications/tool-result', host.toolOutput || {});
      }, 0);
    })();
    </script>
    """
  }

  static func jsString(_ value: String?) -> String {
    jsonLiteral(value ?? "")
  }

  static func jsonLiteral(_ value: Any) -> String {
    guard JSONSerialization.isValidJSONObject(["value": value]),
          let data = try? JSONSerialization.data(withJSONObject: value),
          let json = String(data: data, encoding: .utf8) else {
      return "null"
    }
    return json
  }

  static func jsonString(_ value: Any) -> String {
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
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
