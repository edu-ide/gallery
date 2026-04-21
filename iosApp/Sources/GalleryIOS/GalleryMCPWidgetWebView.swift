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
        handleLegacyToolCall(payload)
      case "mcpRequest":
        handleMCPRequest(payload)
      default:
        break
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
          case "tools/list":
            result = ["tools": try await client.listTools()]
          case "resources/list":
            result = ["resources": try await client.listResources()]
          case "resources/read":
            guard let uri = params["uri"] as? String else {
              throw WidgetBridgeError.invalidRequest("resources/read missing uri")
            }
            result = try await client.readResource(uri: uri) ?? ["contents": []]
          default:
            throw WidgetBridgeError.invalidRequest("Unsupported MCP method: \(method)")
          }
          let compact = GalleryMCPExtAppsClient.compactForWidget(result)
          await resolveMCPRequest(id: requestId, result: compact)
        } catch {
          await rejectMCPRequest(id: requestId, message: error.localizedDescription)
        }
      }
    }

    private func makeClient() async throws -> GalleryMCPExtAppsClient {
      guard let accessToken = try await UgotAuthStore.validAccessToken() else {
        throw WidgetBridgeError.missingAuth
      }
      let state = snapshot.widgetStateDictionary ?? [:]
      let endpointString = (state["endpoint"] as? String) ?? GalleryConnector.fortuneMcpEndpoint
      guard let endpoint = URL(string: endpointString) else {
        throw WidgetBridgeError.invalidRequest("Invalid MCP endpoint")
      }
      return GalleryMCPExtAppsClient(
        connectorId: snapshot.connectorId,
        endpoint: endpoint,
        accessToken: accessToken
      )
    }

    @MainActor
    private func resolveMCPRequest(id: String, result: Any) {
      let resultJson = GalleryMCPWidgetPayload.jsonLiteral(result)
      let idJson = GalleryMCPWidgetPayload.jsString(id)
      evaluate("window.__galleryMcpResolveRequest && window.__galleryMcpResolveRequest(\(idJson), \(resultJson)); window.__galleryMcpResolveCall && window.__galleryMcpResolveCall(\(idJson), \(resultJson));")
    }

    @MainActor
    private func rejectMCPRequest(id: String, message: String) {
      let idJson = GalleryMCPWidgetPayload.jsString(id)
      let messageJson = GalleryMCPWidgetPayload.jsString(message)
      evaluate("window.__galleryMcpRejectRequest && window.__galleryMcpRejectRequest(\(idJson), \(messageJson)); window.__galleryMcpRejectCall && window.__galleryMcpRejectCall(\(idJson), \(messageJson));")
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
    let bridge = Self.innerBridgeScript(
      toolName: toolName,
      toolInputJson: toolInputJson,
      toolOutputJson: toolOutputJson,
      widgetStateJson: widgetStateJson
    )
    return Self.inject(script: bridge, into: html, baseURL: baseURL)
  }

  static func inject(script: String, into html: String, baseURL: URL?) -> String {
    var scriptAndBase = script
    if let baseURL {
      scriptAndBase += "\n<base href=\"\(escapeHTMLAttribute(baseURL.absoluteString))\">"
    }
    if html.range(of: "<head>", options: [.caseInsensitive]) != nil {
      return html.replacingOccurrences(
        of: "<head>",
        with: "<head>\n\(scriptAndBase)",
        options: [.caseInsensitive],
        range: nil
      )
    }
    return "\(scriptAndBase)\n\(html)"
  }

  static func hostWrapperHTML(
    widgetHTML: String,
    toolName: String?,
    toolInputJson: String,
    toolOutputJson: String,
    widgetStateJson: String
  ) -> String {
    let widgetHTMLBase64 = Data(widgetHTML.utf8).base64EncodedString()
    return """
    <!doctype html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
      <style>
        html, body { margin: 0; padding: 0; background: transparent; color-scheme: light dark; width: 100%; min-height: 100%; }
        #mcpFrame { width: 100%; min-height: 360px; height: 620px; border: 0; display: block; background: transparent; }
      </style>
    </head>
    <body>
      <iframe id="mcpFrame" sandbox="allow-scripts allow-same-origin allow-forms allow-popups allow-popups-to-escape-sandbox"></iframe>
      <script>
      (function() {
        const widgetHtmlBase64 = \(jsString(widgetHTMLBase64));
        const widgetHtml = new TextDecoder('utf-8').decode(Uint8Array.from(atob(widgetHtmlBase64), c => c.charCodeAt(0)));
        const parseJson = (raw, fallback) => {
          try { return raw ? JSON.parse(raw) : fallback; }
          catch (error) { console.warn('[McpUiHost] JSON parse failed', error); return fallback; }
        };
        const postNative = (payload) => {
          try { window.webkit.messageHandlers.mcpWidget.postMessage(payload || {}); }
          catch (error) { console.warn('[McpUiHost] native bridge missing', error); }
        };
        const frame = document.getElementById('mcpFrame');
        const pending = {};
        let nativeId = 1;
        let didSendInitialToolData = false;
        const widgetState = parseJson(\(jsString(widgetStateJson)), {});
        let toolOutput = parseJson(\(jsString(toolOutputJson)), null);
        const toolInput = parseJson(\(jsString(toolInputJson)), {});
        const toolName = \(jsString(toolName));
        const hostContext = {
          theme: window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light',
          locale: navigator.language || 'ko',
          timeZone: Intl.DateTimeFormat().resolvedOptions().timeZone || 'Asia/Seoul',
          platform: 'mobile',
          displayMode: 'inline',
          availableDisplayModes: ['inline', 'fullscreen'],
          containerDimensions: { maxHeight: 6000 },
          userAgent: navigator.userAgent,
          deviceCapabilities: { touch: true, hover: false },
          toolInfo: { tool: widgetState.toolDefinition || { name: toolName || 'tool', inputSchema: { type: 'object' } } }
        };
        function postToApp(message) {
          if (!frame.contentWindow) return;
          frame.contentWindow.postMessage(Object.assign({ jsonrpc: '2.0' }, message || {}), '*');
        }
        function notifyApp(method, params) { postToApp({ method, params: params || {} }); }
        function requestNative(method, params) {
          const id = String(nativeId++);
          return new Promise((resolve, reject) => {
            pending[id] = { resolve, reject, method };
            postNative({ type: 'mcpRequest', id, method, params: params || {} });
          });
        }
        function sendInitialToolData(force) {
          if (didSendInitialToolData && !force) return;
          didSendInitialToolData = true;
          notifyApp('ui/notifications/host-context-changed', hostContext);
          notifyApp('ui/notifications/tool-input', { arguments: toolInput || {} });
          if (toolOutput != null) notifyApp('ui/notifications/tool-result', toolOutput || {});
        }
        function resolveNative(id, result) {
          const item = pending[id];
          if (!item) return;
          delete pending[id];
          item.resolve(result || {});
        }
        function rejectNative(id, message) {
          const item = pending[id];
          if (!item) return;
          delete pending[id];
          item.reject(new Error(message || 'MCP request failed'));
        }
        window.__galleryMcpResolveRequest = resolveNative;
        window.__galleryMcpRejectRequest = rejectNative;
        window.__galleryMcpResolveCall = resolveNative;
        window.__galleryMcpRejectCall = rejectNative;
        function handleAppJsonRpc(message) {
          if (!message || message.jsonrpc !== '2.0' || !message.method) return;
          if (message.id == null) {
            if (message.method === 'ui/notifications/initialized') sendInitialToolData(true);
            if (message.method === 'ui/notifications/size-changed' && message.params && message.params.height) {
              const h = Math.max(180, Math.min(6000, Number(message.params.height) || 620));
              frame.style.height = h + 'px';
            }
            return;
          }
          const id = message.id;
          const params = message.params || {};
          const respond = (result) => postToApp({ id, result: result || {} });
          const reject = (error) => postToApp({ id, error: { code: -32603, message: String(error && error.message || error || 'MCP Apps host error') } });
          switch (message.method) {
            case 'ui/initialize':
              respond({
                protocolVersion: '2026-01-26',
                hostInfo: { name: 'gallery-ios', version: '0.1.0' },
                hostCapabilities: {
                  openLinks: {},
                  serverTools: { listChanged: false },
                  serverResources: { listChanged: false },
                  logging: {},
                  updateModelContext: { text: {}, image: {}, audio: {}, resource: {}, resourceLink: {}, structuredContent: {} },
                  message: { text: {}, image: {}, audio: {}, structuredContent: {} }
                },
                hostContext
              });
              break;
            case 'tools/call':
            case 'tools/list':
            case 'resources/list':
            case 'resources/read':
              requestNative(message.method, params).then((result) => {
                if (message.method === 'tools/call') {
                  toolOutput = result || {};
                  notifyApp('ui/notifications/tool-result', toolOutput);
                }
                respond(result);
              }).catch(reject);
              break;
            case 'ui/open-link':
              if (params.url) postNative({ type: 'openExternal', url: params.url });
              respond({});
              break;
            case 'ui/request-display-mode':
              hostContext.displayMode = params.mode === 'fullscreen' ? 'fullscreen' : 'inline';
              notifyApp('ui/notifications/host-context-changed', { displayMode: hostContext.displayMode });
              respond({ mode: hostContext.displayMode });
              break;
            case 'ui/update-model-context':
              window.__galleryModelContext = params;
              respond({});
              break;
            case 'ui/message':
              window.__galleryLastAppMessage = params;
              respond({});
              break;
            case 'ping':
              respond({});
              break;
            default:
              reject('Unsupported MCP Apps method: ' + message.method);
          }
        }
        window.addEventListener('message', (event) => {
          if (event.source !== frame.contentWindow) return;
          if (event.data && event.data.__galleryWidgetMessage === 'setWidgetState') {
            postNative({ type: 'setWidgetState', widgetState: event.data.widgetState || {} });
            return;
          }
          handleAppJsonRpc(event.data);
        });
        frame.addEventListener('load', () => setTimeout(() => sendInitialToolData(false), 25));
        frame.srcdoc = widgetHtml;
      })();
      </script>
    </body>
    </html>
    """
  }

  static func innerBridgeScript(toolName: String?, toolInputJson: String, toolOutputJson: String, widgetStateJson: String) -> String {
    """
    <script>
    (function() {
      const parseJson = (raw, fallback) => {
        try { return raw ? JSON.parse(raw) : fallback; }
        catch (error) { console.warn('[McpUiAppCompat] JSON parse failed', error); return fallback; }
      };
      const pending = {};
      let requestId = 1;
      const postNative = (payload) => {
        try { window.webkit.messageHandlers.mcpWidget.postMessage(payload || {}); }
        catch (error) { console.warn('[McpUiAppCompat] native bridge missing', error); }
      };
      const dispatchGlobals = (globals) => window.dispatchEvent(new CustomEvent('openai:set_globals', { detail: { globals } }));
      function nativeRequest(method, params) {
        const id = String(requestId++);
        return new Promise((resolve, reject) => {
          pending[id] = { resolve, reject, method };
          postNative({ type: 'mcpRequest', id, method, params: params || {} });
        });
      }
      function rpc(method, params) {
        if (window.parent && window.parent !== window) {
          const id = String(requestId++);
          return new Promise((resolve, reject) => {
            pending[id] = { resolve, reject, method };
            window.parent.postMessage({ jsonrpc: '2.0', id, method, params: params || {} }, '*');
          });
        }
        return nativeRequest(method, params);
      }
      window.__galleryMcpResolveRequest = (id, result) => {
        const item = pending[id];
        if (!item) return;
        delete pending[id];
        item.resolve(result || {});
      };
      window.__galleryMcpRejectRequest = (id, message) => {
        const item = pending[id];
        if (!item) return;
        delete pending[id];
        item.reject(new Error(message || 'MCP request failed'));
      };
      window.__galleryMcpResolveCall = window.__galleryMcpResolveRequest;
      window.__galleryMcpRejectCall = window.__galleryMcpRejectRequest;
      const hostContext = {
        theme: window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light',
        locale: navigator.language || 'ko',
        platform: 'mobile',
        displayMode: 'inline',
        userAgent: navigator.userAgent,
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
          return rpc('tools/call', { name, arguments: args || {} }).then((result) => {
            host.toolOutput = result || {};
            host.toolResponseMetadata = result && result._meta ? result._meta : {};
            dispatchGlobals({ toolOutput: host.toolOutput, toolResponseMetadata: host.toolResponseMetadata, widgetState: host.widgetState });
            return result;
          });
        },
        setWidgetState(nextState) {
          host.widgetState = Object.assign({}, host.widgetState || {}, nextState || {});
          window.parent.postMessage({ __galleryWidgetMessage: 'setWidgetState', widgetState: host.widgetState }, '*');
          dispatchGlobals({ widgetState: host.widgetState });
          return Promise.resolve(host.widgetState);
        },
        requestDisplayMode({ mode } = {}) {
          return rpc('ui/request-display-mode', { mode: mode || 'inline' }).then((result) => {
            host.displayMode = result && result.mode || mode || 'inline';
            hostContext.displayMode = host.displayMode;
            document.documentElement.dataset.displayMode = host.displayMode;
            dispatchGlobals({ displayMode: host.displayMode, theme: host.theme, locale: host.locale });
            return { mode: host.displayMode };
          });
        },
        requestModal(payload = {}) { return Promise.resolve(payload); },
        requestClose() { return Promise.resolve(true); },
        updateModelContext(payload = {}) { host.modelContext = payload; return rpc('ui/update-model-context', payload).catch(() => ({})); },
        sendFollowUpMessage(payload = {}) {
          const message = typeof payload === 'string' ? { role: 'user', content: [{ type: 'text', text: payload }] } : payload;
          return rpc('ui/message', message).catch(() => ({}));
        },
        openExternal({ href, url } = {}) {
          const target = href || url;
          return target ? rpc('ui/open-link', { url: target }).catch(() => ({})) : Promise.resolve({});
        },
        notifyIntrinsicHeight(height) { host.maxHeight = height || null; window.parent.postMessage({ jsonrpc: '2.0', method: 'ui/notifications/size-changed', params: { height } }, '*'); return Promise.resolve({ height }); },
        notifyToolsListChanged() { return Promise.resolve(true); }
      };
      const mcpApp = {
        callTool(name, args) { return host.callTool(name, args || {}); },
        sendMessage(text, role) { return host.sendFollowUpMessage({ role: role || 'user', content: [{ type: 'text', text: String(text || '') }] }); },
        updateContext(contentBlocks) { return host.updateModelContext({ content: Array.isArray(contentBlocks) ? contentBlocks : [{ type: 'text', text: String(contentBlocks || '') }] }); },
        openLink(url) { return host.openExternal({ url }); },
        get hostContext() { return hostContext; },
        get initialized() { return true; },
        onToolInput(callback) { if (typeof callback === 'function') callback({ arguments: host.toolInput || {} }); },
        onToolResult(callback) { if (typeof callback === 'function' && host.toolOutput != null) callback(host.toolOutput); },
        onToolCancelled(callback) {},
        onHostContextChanged(callback) { if (typeof callback === 'function') callback(hostContext); },
        onTeardown(callback) {},
      };
      window.addEventListener('message', (event) => {
        if (event.source !== window.parent) return;
        const message = event.data;
        if (!message || message.jsonrpc !== '2.0') return;
        if (message.id != null && pending[message.id]) {
          const item = pending[message.id];
          delete pending[message.id];
          if (message.error) item.reject(new Error(message.error.message || 'MCP request failed'));
          else item.resolve(message.result || {});
          return;
        }
        if (message.method === 'ui/notifications/tool-input') {
          host.toolInput = message.params && message.params.arguments || {};
          dispatchGlobals({ toolInput: host.toolInput });
        } else if (message.method === 'ui/notifications/tool-result') {
          host.toolOutput = message.params || {};
          host.toolResponseMetadata = host.toolOutput && host.toolOutput._meta ? host.toolOutput._meta : {};
          dispatchGlobals({ toolOutput: host.toolOutput, toolResponseMetadata: host.toolResponseMetadata });
        } else if (message.method === 'ui/notifications/host-context-changed') {
          Object.assign(hostContext, message.params || {});
          host.theme = hostContext.theme || host.theme;
          host.locale = hostContext.locale || host.locale;
          host.displayMode = hostContext.displayMode || host.displayMode;
          dispatchGlobals({ theme: host.theme, locale: host.locale, displayMode: host.displayMode });
        }
      });
      window.mcpApp = mcpApp;
      window.__mcpAppsCompatOpenAI = host;
      window.openai = host;
      document.documentElement.lang = host.locale || document.documentElement.lang || 'ko';
      document.documentElement.dataset.displayMode = host.displayMode;
      dispatchGlobals({ toolName: host.toolName, toolInput: host.toolInput, toolOutput: host.toolOutput, toolResponseMetadata: host.toolResponseMetadata, widgetState: host.widgetState, theme: host.theme, locale: host.locale, displayMode: host.displayMode });
    })();
    </script>
    """
  }

  static func jsString(_ value: String?) -> String {
    jsonLiteral(value ?? "")
  }

  static func escapeHTMLAttribute(_ value: String) -> String {
    value
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
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
