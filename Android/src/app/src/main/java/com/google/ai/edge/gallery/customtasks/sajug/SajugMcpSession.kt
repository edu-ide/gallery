package com.google.ai.edge.gallery.customtasks.sajug

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.webkit.JavascriptInterface
import com.google.gson.Gson
import com.google.gson.reflect.TypeToken
import io.ktor.client.HttpClient
import io.ktor.client.engine.okhttp.OkHttp
import io.ktor.client.plugins.sse.SSE
import io.ktor.http.HttpHeaders
import io.modelcontextprotocol.kotlin.sdk.ExperimentalMcpApi
import io.modelcontextprotocol.kotlin.sdk.client.Client
import io.modelcontextprotocol.kotlin.sdk.client.ClientOptions
import io.modelcontextprotocol.kotlin.sdk.client.StreamableHttpClientTransport
import io.modelcontextprotocol.kotlin.sdk.client.mcpClient
import io.modelcontextprotocol.kotlin.sdk.types.CallToolResult
import io.modelcontextprotocol.kotlin.sdk.types.ClientCapabilities
import io.modelcontextprotocol.kotlin.sdk.types.Implementation
import io.modelcontextprotocol.kotlin.sdk.types.McpJson
import io.modelcontextprotocol.kotlin.sdk.types.ReadResourceRequest
import io.modelcontextprotocol.kotlin.sdk.types.ReadResourceRequestParams
import io.modelcontextprotocol.kotlin.sdk.types.TextResourceContents
import io.modelcontextprotocol.kotlin.sdk.types.TextContent
import java.util.Locale
import java.util.TimeZone
import kotlinx.coroutines.runBlocking

internal class SajugMcpSession private constructor(
  private val httpClient: HttpClient,
  private val client: Client,
  val widgetHtml: String,
  val widgetUri: String,
) {
  @Volatile private var toolOutputJson: String = "null"
  @Volatile private var widgetStateJson: String = """{}"""

  val injectedWidgetHtml: String by lazy { injectBridge(widgetHtml) }

  companion object {
    const val TASK_ID = "demo_mcp_widget"
    private const val MCP_ENDPOINT = "http://10.0.2.2:8765/mcp/messages"
    private const val WIDGET_MIME_TYPE = "text/html+skybridge"
    const val WIDGET_BASE_URL = "http://10.0.2.2:8765/"

    private val gson = Gson()
    private val mapType = object : TypeToken<Map<String, Any?>>() {}.type

    @OptIn(ExperimentalMcpApi::class)
    suspend fun create(authToken: String? = null): SajugMcpSession {
      val httpClient = HttpClient(OkHttp) {
        install(SSE)
      }
      val transport =
        StreamableHttpClientTransport(
          client = httpClient,
          url = MCP_ENDPOINT,
          requestBuilder = {
            if (!authToken.isNullOrBlank()) {
              headers.append(HttpHeaders.Authorization, "Bearer $authToken")
            }
          },
        )
      val client =
        mcpClient(
          clientInfo = Implementation(name = "gallery-demo-mcp-client", version = "0.1.0"),
          clientOptions = ClientOptions(capabilities = ClientCapabilities()),
          transport = transport,
        )

      val resources = client.listResources().resources
      val resource =
        resources.firstOrNull {
          it.mimeType == WIDGET_MIME_TYPE && it.uri.contains("?v=")
        } ?: resources.firstOrNull { it.mimeType == WIDGET_MIME_TYPE }
        ?: error("No demo widget resource found")

      val contents =
        client.readResource(ReadResourceRequest(ReadResourceRequestParams(uri = resource.uri))).contents
      val html =
        contents.filterIsInstance<TextResourceContents>().firstOrNull()?.text
          ?: error("Demo widget resource did not return HTML")

      return SajugMcpSession(
        httpClient = httpClient,
        client = client,
        widgetHtml = html,
        widgetUri = resource.uri,
      )
    }
  }

  suspend fun close() {
    client.close()
    httpClient.close()
  }

  fun getToolOutputJson(): String = toolOutputJson

  fun getWidgetStateJson(): String = widgetStateJson

  fun setWidgetStateJson(nextStateJson: String) {
    widgetStateJson = nextStateJson.ifBlank { "{}" }
  }

  fun callToolJson(name: String, argsJson: String?): String {
    val arguments: Map<String, Any?> =
      try {
        gson.fromJson<Map<String, Any?>>(argsJson?.takeIf { it.isNotBlank() } ?: "{}", mapType)
          ?: emptyMap<String, Any?>()
      } catch (_: Exception) {
        emptyMap<String, Any?>()
      }

    val meta: Map<String, Any?> =
      mapOf(
        "openai/locale" to Locale.getDefault().toLanguageTag(),
        "openai/timezone" to TimeZone.getDefault().id,
      )

    val result =
      runBlocking {
        try {
          client.callTool(name = name, arguments = arguments, meta = meta)
        } catch (error: Exception) {
          CallToolResult(
            content = listOf(TextContent(error.message ?: "Tool call failed")),
            isError = true,
          )
        }
      }

    val encoded = McpJson.encodeToString(result)
    toolOutputJson = encoded
    widgetStateJson = mergeLastToolOutput(widgetStateJson, encoded)
    return encoded
  }

  private fun injectBridge(html: String): String {
    val bridgeScript =
      """
      <script>
      (function() {
        const bridge = window.SajugMcp;
        if (!bridge) {
          console.warn("[SajugBridge] Android bridge missing");
          return;
        }
        const parseJson = (raw, fallback) => {
          try {
            return raw ? JSON.parse(raw) : fallback;
          } catch (error) {
            console.warn("[SajugBridge] Failed to parse JSON", error);
            return fallback;
          }
        };
        const mergeWidgetState = (nextState) => {
          const merged = Object.assign({}, window.openai.widgetState || {}, nextState || {});
          bridge.setWidgetState(JSON.stringify(merged));
          window.openai.widgetState = merged;
          return merged;
        };
        window.openai = {
          toolOutput: parseJson(bridge.getToolOutput(), null),
          widgetState: parseJson(bridge.getWidgetState(), {}),
          theme: "light",
          callTool(name, args) {
            const raw = bridge.callTool(name, JSON.stringify(args || {}));
            const result = parseJson(raw, { isError: true, content: [{ type: "text", text: "Tool call failed" }] });
            this.toolOutput = result;
            mergeWidgetState({ lastToolOutput: result });
            return Promise.resolve(result);
          },
          setWidgetState(nextState) {
            mergeWidgetState(nextState);
            return Promise.resolve(window.openai.widgetState);
          },
          requestDisplayMode({ mode } = {}) {
            const nextMode = mode || "default";
            document.documentElement.dataset.displayMode = nextMode;
            return Promise.resolve({ mode: nextMode });
          },
          requestModal(payload = {}) {
            return Promise.resolve(payload);
          },
          requestClose() {
            return Promise.resolve(true);
          },
          sendFollowUpMessage(payload = {}) {
            console.log("[SajugBridge] sendFollowUpMessage", payload);
            return Promise.resolve(payload);
          },
          openExternal({ href } = {}) {
            if (href) bridge.openExternal(href);
            return Promise.resolve({ href });
          }
        };
      })();
      </script>
      """.trimIndent()

    return if (html.contains("<head>")) {
      html.replace("<head>", "<head>\n$bridgeScript")
    } else {
      "$bridgeScript\n$html"
    }
  }

  private fun mergeLastToolOutput(currentStateJson: String, toolOutput: String): String {
    val currentState: MutableMap<String, Any?> =
      try {
        (gson.fromJson<Map<String, Any?>>(currentStateJson, mapType)
            ?: emptyMap<String, Any?>())
          .toMutableMap()
      } catch (_: Exception) {
        mutableMapOf<String, Any?>()
      }
    currentState["lastToolOutput"] =
      try {
        gson.fromJson<Any?>(toolOutput, Any::class.java)
      } catch (_: Exception) {
        null
      }
    return gson.toJson(currentState)
  }
}

internal class SajugWebBridge(
  private val context: Context,
  private val session: SajugMcpSession,
) {
  private val mainHandler = Handler(Looper.getMainLooper())

  @JavascriptInterface
  fun callTool(name: String, argsJson: String?): String = session.callToolJson(name, argsJson)

  @JavascriptInterface
  fun getToolOutput(): String = session.getToolOutputJson()

  @JavascriptInterface
  fun getWidgetState(): String = session.getWidgetStateJson()

  @JavascriptInterface
  fun setWidgetState(nextStateJson: String) {
    session.setWidgetStateJson(nextStateJson)
  }

  @JavascriptInterface
  fun openExternal(url: String) {
    mainHandler.post {
      runCatching {
        context.startActivity(
          Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        )
      }
    }
  }
}
