package com.ugot.chatkit.mcp.runtime

import com.google.gson.Gson
import com.google.gson.reflect.TypeToken
import com.google.ai.edge.gallery.agent.vfs.AgentVfsFactory
import com.google.ai.edge.gallery.agent.vfs.AgentVfsMcpContentBlock
import com.google.ai.edge.gallery.agent.vfs.AgentVfsMcpIngestor
import com.google.ai.edge.gallery.agent.vfs.AgentVfsMcpResourceContent
import com.google.ai.edge.gallery.agent.vfs.AgentVfsMcpToolResult
import com.google.ai.edge.gallery.agent.vfs.AgentVfsPaths
import com.google.ai.edge.gallery.agent.vfs.OkioAgentVirtualFileSystem
import io.ktor.client.HttpClient
import io.ktor.client.engine.okhttp.OkHttp
import io.ktor.client.plugins.sse.SSE
import io.ktor.http.HttpHeaders
import io.modelcontextprotocol.kotlin.sdk.ExperimentalMcpApi
import io.modelcontextprotocol.kotlin.sdk.client.Client
import io.modelcontextprotocol.kotlin.sdk.client.ClientOptions
import io.modelcontextprotocol.kotlin.sdk.client.StreamableHttpClientTransport
import io.modelcontextprotocol.kotlin.sdk.client.mcpClient
import io.modelcontextprotocol.kotlin.sdk.types.BlobResourceContents
import io.modelcontextprotocol.kotlin.sdk.types.CallToolResult
import io.modelcontextprotocol.kotlin.sdk.types.ClientCapabilities
import io.modelcontextprotocol.kotlin.sdk.types.EmbeddedResource
import io.modelcontextprotocol.kotlin.sdk.types.Implementation
import io.modelcontextprotocol.kotlin.sdk.types.McpJson
import io.modelcontextprotocol.kotlin.sdk.types.ResourceLink
import io.modelcontextprotocol.kotlin.sdk.types.ReadResourceRequest
import io.modelcontextprotocol.kotlin.sdk.types.ReadResourceRequestParams
import io.modelcontextprotocol.kotlin.sdk.types.TextContent
import io.modelcontextprotocol.kotlin.sdk.types.TextResourceContents
import java.util.Locale
import kotlin.text.ifBlank
import java.util.TimeZone
import kotlinx.coroutines.runBlocking
import android.content.Context
import android.util.Log
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull

private const val TOOL_CATALOG_TTL_MS = 5 * 60 * 1000L
private const val MCP_UI_SESSION_LOG_TAG = "McpUiSession"

data class McpUiToolCallEvent(
  val toolName: String,
  val widgetStateJson: String,
  val artifactContextSummary: String = "",
)

data class McpToolDescriptor(
  val name: String,
  val title: String,
  val description: String,
  val inputSchemaJson: String,
  val requiredParameters: List<String>,
  val isReadOnly: Boolean,
  val isDestructive: Boolean,
  val widgetUri: String? = null,
) {
  val hasWidget: Boolean
    get() = widgetUri != null
}

interface McpToolGateway {
  val widgetUri: String

  fun getWidgetStateJson(): String

  suspend fun listTools(): List<McpToolDescriptor>

  suspend fun callToolJsonAsync(name: String, argsJson: String?): String
}

class McpUiSession private constructor(
  private val httpClient: HttpClient,
  private val client: Client,
  private val widgetHtmlByUri: Map<String, String>,
  initialWidgetUri: String,
  override val widgetBaseUrl: String,
  private val agentVfsSessionId: String,
  private val connectorId: String,
  private val agentVfs: OkioAgentVirtualFileSystem?,
) : McpWidgetSessionHost, McpToolGateway {
  private val agentVfsSessionRoot: String =
    "/session/${AgentVfsPaths.sanitizeOpaqueSegment(agentVfsSessionId, fallback = "session")}"

  @Volatile private var toolName: String? = null
  @Volatile private var toolInputJson: String = "{}"
  @Volatile private var toolOutputJson: String = "null"
  @Volatile private var widgetStateJson: String = """{}"""
  @Volatile private var currentWidgetUri: String = initialWidgetUri
  @Volatile private var cachedTools: List<McpToolDescriptor>? = null
  @Volatile private var cachedToolsAtMs: Long = 0L
  private val widgetUriByTool = java.util.concurrent.ConcurrentHashMap<String, String>()
  private val _toolCallEvents = MutableSharedFlow<McpUiToolCallEvent>(extraBufferCapacity = 1)
  val toolCallEvents: SharedFlow<McpUiToolCallEvent> = _toolCallEvents.asSharedFlow()

  override val widgetUri: String
    get() = currentWidgetUri

  val widgetHtml: String
    get() = widgetHtmlByUri.getValue(currentWidgetUri)

  override val injectedWidgetHtml: String
    get() = McpUiHostUtils.injectHostBridge(widgetHtml)

  companion object {
    private val gson = Gson()
    private val mapType = object : TypeToken<Map<String, Any?>>() {}.type

    @OptIn(ExperimentalMcpApi::class)
    suspend fun create(
      endpoint: String,
      widgetBaseUrl: String,
      authToken: String? = null,
      clientName: String = "gallery-mcp-ui-client",
      clientVersion: String = "0.1.0",
      agentVfsRootPath: String? = null,
      agentVfsSessionId: String = "mcp-ui-session",
      connectorId: String = widgetBaseUrl,
    ): McpUiSession {
      val httpClient = HttpClient(OkHttp) {
        install(SSE)
      }
      val transport =
        StreamableHttpClientTransport(
          client = httpClient,
          url = endpoint,
          requestBuilder = {
            if (!authToken.isNullOrBlank()) {
              headers.append(HttpHeaders.Authorization, "Bearer $authToken")
            }
          },
        )
      val client =
        mcpClient(
          clientInfo = Implementation(name = clientName, version = clientVersion),
          clientOptions = ClientOptions(capabilities = ClientCapabilities()),
          transport = transport,
        )

      val resources = client.listResources().resources
      val resourceCandidates =
        resources.map { McpUiWidgetResource(uri = it.uri, mimeType = it.mimeType) }
      val preferredResource =
        McpUiHostUtils.selectPreferredWidgetResource(resourceCandidates)
          ?: error("No compatible widget resource found")

      val widgetHtmlByUri =
        resourceCandidates
          .filter { McpUiHostUtils.isSupportedWidgetMimeType(it.mimeType) }
          .mapNotNull { resource ->
            runCatching {
                val contents =
                  client.readResource(
                    ReadResourceRequest(ReadResourceRequestParams(uri = resource.uri))
                  ).contents
                val html = contents.filterIsInstance<TextResourceContents>().firstOrNull()?.text
                html?.let { resource.uri to it }
              }
              .getOrNull()
          }
          .toMap()
      check(widgetHtmlByUri.containsKey(preferredResource.uri)) {
        "Preferred widget resource did not return HTML"
      }

      return McpUiSession(
        httpClient = httpClient,
        client = client,
        widgetHtmlByUri = widgetHtmlByUri,
        initialWidgetUri = preferredResource.uri,
        widgetBaseUrl = widgetBaseUrl,
        agentVfsSessionId = agentVfsSessionId,
        connectorId = connectorId,
        agentVfs =
          agentVfsRootPath
            ?.takeIf { it.isNotBlank() }
            ?.let { rootPath -> AgentVfsFactory.createSystem(rootPath) { System.currentTimeMillis() } },
      )
    }
  }

  suspend fun close() {
    client.close()
    httpClient.close()
  }

  fun getToolOutputJson(): String = toolOutputJson

  fun getToolName(): String = toolName.orEmpty()

  fun getToolInputJson(): String = toolInputJson

  override fun getWidgetStateJson(): String = widgetStateJson

  fun getAgentVfsContextSummary(): String =
    agentVfs?.contextSummary(agentVfsSessionRoot).orEmpty()

  fun setWidgetStateJson(nextStateJson: String) {
    widgetStateJson = nextStateJson.ifBlank { "{}" }
  }

  override fun createJavascriptBridge(context: Context): Any = McpUiWebBridge(context, this)

  override suspend fun listTools(): List<McpToolDescriptor> {
    val now = System.currentTimeMillis()
    cachedTools?.takeIf { now - cachedToolsAtMs < TOOL_CATALOG_TTL_MS }?.let { return it }
    val tools = client.listTools().tools.map { tool ->
      val toolWidgetUri =
        tool.meta
          ?.entries
          ?.firstNotNullOfOrNull { (key, value) ->
            if (
              key.contains("resourceUri", ignoreCase = true) ||
                key.contains("outputTemplate", ignoreCase = true)
            ) {
              (value as? JsonPrimitive)?.contentOrNull
            } else {
              null
            }
          }
          ?.takeIf(widgetHtmlByUri::containsKey)
      if (toolWidgetUri != null) {
        widgetUriByTool[tool.name] = toolWidgetUri
      } else {
        widgetUriByTool.remove(tool.name)
      }
      McpToolDescriptor(
        name = tool.name,
        title = tool.title ?: tool.annotations?.title ?: tool.name,
        description = tool.description.orEmpty(),
        inputSchemaJson = tool.inputSchema.toString(),
        requiredParameters = tool.inputSchema.required.orEmpty(),
        isReadOnly = tool.annotations?.readOnlyHint == true,
        isDestructive = tool.annotations?.destructiveHint == true,
        widgetUri = toolWidgetUri,
      )
    }
    runCatching {
      Log.i(
        MCP_UI_SESSION_LOG_TAG,
        "Loaded ${tools.size} tools: " +
          tools.joinToString { tool ->
            "${tool.name}(required=${tool.requiredParameters.joinToString(",")}," +
              "readOnly=${tool.isReadOnly},destructive=${tool.isDestructive})"
          },
      )
    }
    cachedTools = tools
    cachedToolsAtMs = now
    return tools
  }

  fun callToolJson(name: String, argsJson: String?): String =
    runBlocking { callToolJsonAsync(name, argsJson) }

  override suspend fun callToolJsonAsync(name: String, argsJson: String?): String {
    widgetUriByTool[name]?.let { nextWidgetUri -> currentWidgetUri = nextWidgetUri }
    val arguments: Map<String, Any?> =
      try {
        gson.fromJson<Map<String, Any?>>(argsJson?.takeIf { it.isNotBlank() } ?: "{}", mapType)
          ?: emptyMap<String, Any?>()
      } catch (_: Exception) {
        emptyMap<String, Any?>()
      }

    toolName = name
    toolInputJson = argsJson?.takeIf { it.isNotBlank() } ?: "{}"

    val meta: Map<String, Any?> =
      mapOf(
        "openai/locale" to Locale.getDefault().toLanguageTag(),
        "openai/timezone" to TimeZone.getDefault().id,
      )

    val result =
      try {
        client.callTool(name = name, arguments = arguments, meta = meta)
      } catch (error: Exception) {
        CallToolResult(
          content = listOf(TextContent(error.message ?: "Tool call failed")),
          isError = true,
        )
      }

    val encoded = McpJson.encodeToString(result)
    val artifactContextSummary = ingestToolResultArtifacts(name = name, result = result, rawResultJson = encoded)
    toolOutputJson = encoded
    widgetStateJson = mergeLastToolOutput(widgetStateJson, encoded, artifactContextSummary)
    _toolCallEvents.tryEmit(
      McpUiToolCallEvent(
        toolName = name,
        widgetStateJson = widgetStateJson,
        artifactContextSummary = artifactContextSummary,
      )
    )
    return encoded
  }

  private fun mergeLastToolOutput(currentStateJson: String, toolOutput: String, artifactContextSummary: String): String {
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
    currentState["currentToolName"] = toolName
    if (artifactContextSummary.isNotBlank()) {
      currentState["agentVfsContext"] = artifactContextSummary
    }
    return gson.toJson(currentState)
  }

  private fun ingestToolResultArtifacts(
    name: String,
    result: CallToolResult,
    rawResultJson: String,
  ): String {
    val vfs = agentVfs ?: return ""
    val mcpResult =
      AgentVfsMcpToolResult(
        structuredContentJson = result.structuredContent?.takeIf { it.isNotEmpty() }?.toString(),
        rawResultJson = rawResultJson,
        content = result.content.mapIndexedNotNull { index, block -> block.toAgentVfsContentBlock(index) },
      )
    val ingest =
      AgentVfsMcpIngestor(vfs)
        .ingestDefault(
          sessionId = agentVfsSessionId,
          connectorId = connectorId,
          toolName = name,
          toolCallId = null,
          result = mcpResult,
          persistTextBlocks = false,
        )
    if (ingest.nodes.isEmpty()) {
      return ""
    }
    return vfs.contextSummary(agentVfsSessionRoot)
  }

  private fun io.modelcontextprotocol.kotlin.sdk.types.ContentBlock.toAgentVfsContentBlock(
    index: Int
  ): AgentVfsMcpContentBlock? =
    when (this) {
      is TextContent -> AgentVfsMcpContentBlock(type = "text", text = text)
      is EmbeddedResource ->
        AgentVfsMcpContentBlock(
          type = "resource",
          resource = resource.toAgentVfsResourceContent(),
        )
      is ResourceLink ->
        AgentVfsMcpContentBlock(
          type = "resource_link",
          uri = uri,
          name = name.ifBlank { "resource-link-$index" },
          mimeType = mimeType,
        )
      else -> null
    }

  private fun io.modelcontextprotocol.kotlin.sdk.types.ResourceContents.toAgentVfsResourceContent(): AgentVfsMcpResourceContent =
    when (this) {
      is TextResourceContents ->
        AgentVfsMcpResourceContent(
          uri = uri,
          mimeType = mimeType,
          text = text,
        )
      is BlobResourceContents ->
        AgentVfsMcpResourceContent(
          uri = uri,
          mimeType = mimeType,
          blobBase64 = blob,
        )
      else ->
        AgentVfsMcpResourceContent(
          uri = uri,
          mimeType = mimeType,
        )
    }
}
