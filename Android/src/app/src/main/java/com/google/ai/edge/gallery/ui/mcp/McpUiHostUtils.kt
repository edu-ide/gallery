package com.google.ai.edge.gallery.ui.mcp

import com.google.gson.Gson

data class McpUiWidgetResource(
  val uri: String,
  val mimeType: String?,
)

object McpUiHostUtils {
  const val STANDARD_WIDGET_MIME_TYPE = "text/html;profile=mcp-app"
  const val LEGACY_WIDGET_MIME_TYPE = "text/html+skybridge"

  private val gson = Gson()

  fun selectPreferredWidgetResource(resources: List<McpUiWidgetResource>): McpUiWidgetResource? {
    return resources
      .filter { isSupportedWidgetMimeType(it.mimeType) }
      .sortedWith(
        compareByDescending<McpUiWidgetResource> { mimeTypePriority(it.mimeType) }
          .thenByDescending { isVersionedUri(it.uri) }
      )
      .firstOrNull()
  }

  fun injectHostBridge(
    html: String,
    toolName: String? = null,
    toolInputJson: String = "{}",
    toolOutputJson: String = "null",
    widgetStateJson: String = "{}",
  ): String {
    val bridgeScript =
      """
      <script>
      (function() {
        const bridge = window.McpUiHost;
        if (!bridge) {
          console.warn("[McpUiHost] Android bridge missing");
          return;
        }

        const parseJson = (raw, fallback) => {
          try {
            return raw ? JSON.parse(raw) : fallback;
          } catch (error) {
            console.warn("[McpUiHost] Failed to parse JSON", error);
            return fallback;
          }
        };

        const dispatchGlobals = (globals) => {
          window.dispatchEvent(
            new CustomEvent("openai:set_globals", {
              detail: { globals },
            }),
          );
        };

        const emitToolStarted = (toolName, args) => {
          window.dispatchEvent(
            new CustomEvent("openai:tool_call_started", {
              detail: { toolName, args },
            }),
          );
        };

        const postJsonRpc = (message) => {
          window.postMessage(
            Object.assign({ jsonrpc: "2.0" }, message || {}),
            "*",
          );
        };

        const notifyMcpApp = (method, params) => {
          postJsonRpc({ method, params: params || {} });
        };

        const hostContext = {
          theme: bridge.getTheme ? bridge.getTheme() : "light",
          locale: bridge.getLocale ? bridge.getLocale() : "en",
          platform: "mobile",
          displayMode: "inline",
          userAgent: navigator.userAgent,
        };

        const createToolErrorResult = (message) => ({
          content: [{ type: "text", text: message || "Tool call failed" }],
          isError: true,
        });

        const updateWidgetState = (nextState) => {
          host.widgetState = nextState;
          bridge.setWidgetState(JSON.stringify(nextState));
          dispatchGlobals({ widgetState: host.widgetState });
        };

        const runToolCall = (name, args) => {
          emitToolStarted(name, args || {});
          host.toolName = name;
          host.toolInput = args || {};
          notifyMcpApp("ui/notifications/tool-input", { arguments: host.toolInput });

          const raw = bridge.callTool(name, JSON.stringify(host.toolInput));
          const result = parseJson(raw, createToolErrorResult("Tool call failed"));

          host.toolOutput = result;
          host.toolResponseMetadata = result && result._meta ? result._meta : {};

          const nextState =
            Object.assign({}, host.widgetState || {}, {
              lastToolOutput: result,
              currentToolName: name,
            });
          updateWidgetState(nextState);

          notifyMcpApp("ui/notifications/tool-result", result || {});
          dispatchGlobals({
            toolName: host.toolName,
            toolInput: host.toolInput,
            toolOutput: host.toolOutput,
            toolResponseMetadata: host.toolResponseMetadata,
            widgetState: host.widgetState,
          });

          return result;
        };

        const sendBridgeResponse = (id, payload) => {
          postJsonRpc({
            id,
            ...(payload && payload.error ? { error: payload.error } : { result: payload && payload.result ? payload.result : {} }),
          });
        };

        const sendBridgeResult = (id, result) => {
          sendBridgeResponse(id, { result });
        };

        const sendBridgeError = (id, message) => {
          sendBridgeResponse(id, {
            error: {
              code: -32603,
              message: message || "Bridge request failed",
            },
          });
        };

        const host = {
          __hostType: 'mcp-apps',
          __connected: true,
          toolName: ${toJsLiteral(toolName)},
          toolInput: parseJson(${toJsLiteral(toolInputJson)}, {}),
          toolOutput: parseJson(${toJsLiteral(toolOutputJson)}, null),
          toolResponseMetadata: {},
          widgetState: parseJson(${toJsLiteral(widgetStateJson)}, {}),
          theme: hostContext.theme,
          locale: hostContext.locale,
          displayMode: "inline",
          maxHeight: null,
          userAgent: navigator.userAgent,
          view: {},
          modelContext: null,
          callTool(name, args) {
            return Promise.resolve(runToolCall(name, args || {}));
          },
          setWidgetState(nextState) {
            const merged = Object.assign({}, host.widgetState || {}, nextState || {});
            updateWidgetState(merged);
            return Promise.resolve(merged);
          },
          requestDisplayMode({ mode } = {}) {
            const nextMode = mode || "inline";
            host.displayMode = nextMode;
            hostContext.displayMode = nextMode;
            document.documentElement.dataset.displayMode = nextMode;
            notifyMcpApp("ui/notifications/host-context-changed", hostContext);
            dispatchGlobals({ displayMode: host.displayMode, theme: host.theme, locale: host.locale });
            return Promise.resolve({ mode: nextMode });
          },
          requestModal(payload = {}) {
            return Promise.resolve(payload);
          },
          requestClose() {
            return Promise.resolve(true);
          },
          updateModelContext(payload = {}) {
            host.modelContext = payload;
            return Promise.resolve(payload);
          },
          sendFollowUpMessage(payload = {}) {
            console.log("[McpUiHost] sendFollowUpMessage", payload);
            return Promise.resolve(payload);
          },
          openExternal({ href, url } = {}) {
            const target = href || url;
            if (target) bridge.openExternal(target);
            return Promise.resolve({ href: target });
          },
          notifyIntrinsicHeight(height) {
            host.maxHeight = height || null;
            return Promise.resolve({ height });
          },
          notifyToolsListChanged() {
            return Promise.resolve(true);
          }
        };

        const mcpApp = {
          callTool(name, args) {
            return Promise.resolve(runToolCall(name, args || {}));
          },
          sendMessage(text, role) {
            host.lastMessage = {
              role: role || "user",
              content: [{ type: "text", text: String(text || "") }],
            };
            return Promise.resolve({});
          },
          updateContext(contentBlocks) {
            const content = Array.isArray(contentBlocks)
              ? contentBlocks
              : [{ type: "text", text: String(contentBlocks || "") }];
            host.modelContext = { content };
            return Promise.resolve({});
          },
          openLink(url) {
            if (url) bridge.openExternal(url);
            return Promise.resolve({});
          },
          get hostContext() {
            return hostContext;
          },
          get initialized() {
            return true;
          },
          onToolInput(callback) {
            if (typeof callback === "function") {
              window.addEventListener("message", (event) => {
                if (event.data && event.data.jsonrpc === "2.0" && event.data.method === "ui/notifications/tool-input") {
                  callback(event.data.params || {});
                }
              });
              callback({ arguments: host.toolInput || {} });
            }
          },
          onToolResult(callback) {
            if (typeof callback === "function") {
              window.addEventListener("message", (event) => {
                if (event.data && event.data.jsonrpc === "2.0" && event.data.method === "ui/notifications/tool-result") {
                  callback(event.data.params || {});
                }
              });
              if (host.toolOutput != null) {
                callback(host.toolOutput);
              }
            }
          },
          onToolCancelled(callback) {
            if (typeof callback === "function") {
              window.addEventListener("message", (event) => {
                if (event.data && event.data.jsonrpc === "2.0" && event.data.method === "ui/notifications/tool-cancelled") {
                  callback(event.data.params || {});
                }
              });
            }
          },
          onHostContextChanged(callback) {
            if (typeof callback === "function") {
              window.addEventListener("message", (event) => {
                if (event.data && event.data.jsonrpc === "2.0" && event.data.method === "ui/notifications/host-context-changed") {
                  callback(event.data.params || {});
                }
              });
              callback(hostContext);
            }
          },
          onTeardown(callback) {
            if (typeof callback === "function") {
              window.addEventListener("message", (event) => {
                if (event.data && event.data.jsonrpc === "2.0" && event.data.method === "ui/resource-teardown") {
                  callback(event.data.params || {});
                }
              });
            }
          },
        };

        window.__mcpBridge = (message) => {
          if (!message || message.jsonrpc !== "2.0" || !message.method) {
            return;
          }

          const params = message.params || {};

          try {
            switch (message.method) {
              case "ui/initialize":
                sendBridgeResult(message.id, {
                  protocolVersion: "2026-01-26",
                  hostInfo: { name: "gallery-android", version: "0.1.0" },
                  hostCapabilities: {
                    serverTools: {},
                    openLinks: {},
                    logging: {},
                  },
                  hostContext,
                });
                notifyMcpApp("ui/notifications/host-context-changed", hostContext);
                notifyMcpApp("ui/notifications/tool-input", { arguments: host.toolInput || {} });
                if (host.toolOutput != null) {
                  notifyMcpApp("ui/notifications/tool-result", host.toolOutput || {});
                }
                break;
              case "tools/call":
                sendBridgeResult(message.id, runToolCall(params.name, params.arguments || {}));
                break;
              case "ui/message":
                mcpApp.sendMessage(
                  params.content && params.content[0] ? params.content[0].text : "",
                  params.role,
                );
                sendBridgeResult(message.id, {});
                break;
              case "ui/update-model-context":
                mcpApp.updateContext(params.content || []);
                sendBridgeResult(message.id, {});
                break;
              case "ui/open-link":
                mcpApp.openLink(params.url);
                sendBridgeResult(message.id, {});
                break;
              case "ui/request-display-mode":
                host.requestDisplayMode({ mode: params.mode }).then((result) => sendBridgeResult(message.id, result));
                break;
              case "ping":
                sendBridgeResult(message.id, {});
                break;
              default:
                sendBridgeError(message.id, "Unsupported MCP bridge method: " + message.method);
                break;
            }
          } catch (error) {
            sendBridgeError(message.id, error && error.message ? error.message : String(error));
          }
        };

        window.mcpApp = mcpApp;
        window.__mcpAppsCompatOpenAI = host;
        window.openai = host;
        document.documentElement.lang = host.locale || document.documentElement.lang || "en";
        document.documentElement.dataset.displayMode = host.displayMode;
        dispatchGlobals({
          toolName: host.toolName,
          toolInput: host.toolInput,
          toolOutput: host.toolOutput,
          toolResponseMetadata: host.toolResponseMetadata,
          widgetState: host.widgetState,
          theme: host.theme,
          locale: host.locale,
          displayMode: host.displayMode
        });
      })();
      </script>
      """.trimIndent()

    return if (html.contains("<head>", ignoreCase = true)) {
      html.replaceFirst(Regex("<head>", RegexOption.IGNORE_CASE), "<head>\n$bridgeScript")
    } else {
      "$bridgeScript\n$html"
    }
  }

  private fun isSupportedWidgetMimeType(mimeType: String?): Boolean {
    return mimeType == STANDARD_WIDGET_MIME_TYPE || mimeType == LEGACY_WIDGET_MIME_TYPE
  }

  private fun mimeTypePriority(mimeType: String?): Int {
    return when (mimeType) {
      STANDARD_WIDGET_MIME_TYPE -> 2
      LEGACY_WIDGET_MIME_TYPE -> 1
      else -> 0
    }
  }

  private fun isVersionedUri(uri: String): Boolean = uri.contains("?v=")

  private fun toJsLiteral(value: String?): String = gson.toJson(value)
}
