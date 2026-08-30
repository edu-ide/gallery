package com.ugot.chatkit.mcp.runtime

import com.ugot.chatkit.runtime.ChatRuntimeAvailability
import com.ugot.chatkit.runtime.ChatRuntimeDescriptor
import com.ugot.chatkit.runtime.ChatRuntimeEvent
import com.ugot.chatkit.runtime.ChatRuntimeEventListener
import com.ugot.chatkit.runtime.ChatRuntimeEventType
import com.ugot.chatkit.runtime.ChatRuntimeExecutionKey
import com.ugot.chatkit.runtime.ChatRuntimeExecutor
import com.ugot.chatkit.runtime.ChatRuntimeProviderKind
import com.ugot.chatkit.runtime.ChatRuntimeRequest
import com.ugot.chatkit.runtime.ChatRuntimeResetResult
import com.ugot.chatkit.runtime.ChatRuntimeSessionConfig
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class McpAgentChatRuntimeExecutorTest {
  @Test
  fun activeConnectorRunsHiddenPlanToolAndVisibleFinal() = runBlocking {
    val delegate = RecordingRuntime()
    val gateway = RecordingGateway(readOnly = true, hasWidget = true)
    val executor = McpAgentChatRuntimeExecutor(delegate, gateway, CONNECTOR_ID, "Fortune")
    val events = mutableListOf<ChatRuntimeEvent>()

    executor.execute(request(), ChatRuntimeEventListener(events::add))

    assertEquals(listOf("show_today", "{}"), gateway.lastCall)
    assertTrue(delegate.inputs.first().contains("Return ONLY one JSON object"))
    assertTrue(delegate.inputs.last().contains("MCP tool 'show_today'"))
    assertEquals("final answer", events.filter { it.type == ChatRuntimeEventType.TEXT_DELTA }.joinToString("") { it.text })
    assertTrue(events.any { it.type == ChatRuntimeEventType.WIDGET_AVAILABLE })
    assertEquals(ChatRuntimeEventType.COMPLETED, events.last().type)
  }

  @Test
  fun mutatingToolWaitsForSharedApprovalResolution() = runBlocking {
    val delegate = RecordingRuntime()
    val gateway = RecordingGateway(readOnly = false, hasWidget = false)
    val executor = McpAgentChatRuntimeExecutor(delegate, gateway, CONNECTOR_ID, "Fortune")
    val events = mutableListOf<ChatRuntimeEvent>()
    val job = launch { executor.execute(request(), ChatRuntimeEventListener(events::add)) }

    while (events.none { it.type == ChatRuntimeEventType.APPROVAL_REQUIRED }) yield()
    val permission = events.firstNotNullOf { it.permission }
    assertTrue(executor.resolvePermission(KEY, permission.requestId, allow = true))
    job.join()

    assertEquals("show_today", gateway.lastCall?.first())
    assertEquals(ChatRuntimeEventType.COMPLETED, events.last().type)
  }

  @Test
  fun unstructuredPlannerOutputFallsBackToStrongSafeReadMatch() = runBlocking {
    val delegate = RecordingRuntime(planningResponse = "I can help with today's fortune.")
    val gateway = RecordingGateway(readOnly = true, hasWidget = true)
    val executor = McpAgentChatRuntimeExecutor(delegate, gateway, CONNECTOR_ID, "Fortune")
    val events = mutableListOf<ChatRuntimeEvent>()

    executor.execute(
      request(input = "Show me the fortune for today"),
      ChatRuntimeEventListener(events::add),
    )

    assertEquals(listOf("show_today", "{}"), gateway.lastCall)
    assertTrue(delegate.inputs.none { it.contains("Return ONLY one JSON object") })
    assertTrue(events.any { it.type == ChatRuntimeEventType.WIDGET_AVAILABLE })
    assertEquals(ChatRuntimeEventType.COMPLETED, events.last().type)
  }

  @Test
  fun unstructuredPlannerOutputRequiresApprovalWhenReadAnnotationIsMissing() = runBlocking {
    val delegate = RecordingRuntime(planningResponse = "I can help with today's fortune.")
    val gateway = RecordingGateway(readOnly = false, hasWidget = true)
    val executor = McpAgentChatRuntimeExecutor(delegate, gateway, CONNECTOR_ID, "Fortune")
    val events = mutableListOf<ChatRuntimeEvent>()
    val job =
      launch {
        executor.execute(
          request(input = "Show me the fortune for today"),
          ChatRuntimeEventListener(events::add),
        )
      }

    while (events.none { it.type == ChatRuntimeEventType.APPROVAL_REQUIRED }) yield()
    assertEquals(null, gateway.lastCall)
    val permission = events.firstNotNullOf { it.permission }
    assertTrue(executor.resolvePermission(KEY, permission.requestId, allow = true))
    job.join()

    assertEquals(listOf("show_today", "{}"), gateway.lastCall)
    assertTrue(events.any { it.type == ChatRuntimeEventType.WIDGET_AVAILABLE })
    assertEquals(ChatRuntimeEventType.COMPLETED, events.last().type)
  }

  @Test
  fun inactiveConnectorUsesModelWithoutListingTools() = runBlocking {
    val delegate = RecordingRuntime()
    val gateway = RecordingGateway(readOnly = true, hasWidget = false)
    val executor = McpAgentChatRuntimeExecutor(delegate, gateway, CONNECTOR_ID, "Fortune")
    val events = mutableListOf<ChatRuntimeEvent>()

    executor.execute(request(activeConnector = false), ChatRuntimeEventListener(events::add))

    assertEquals(0, gateway.listCount)
    assertEquals(listOf("hello"), delegate.inputs)
    assertEquals(ChatRuntimeEventType.COMPLETED, events.last().type)
  }

  private class RecordingGateway(
    private val readOnly: Boolean,
    private val hasWidget: Boolean,
  ) : McpToolGateway {
    override val widgetUri: String = "ui://fortune/today"
    var listCount = 0
    var lastCall: List<String>? = null

    override fun getWidgetStateJson(): String = "{\"ready\":true}"

    override suspend fun listTools(): List<McpToolDescriptor> {
      listCount += 1
      return listOf(
        McpToolDescriptor(
          name = "show_today",
          title = "Today",
          description = "Show today's result",
          inputSchemaJson = "{}",
          requiredParameters = emptyList(),
          isReadOnly = readOnly,
          isDestructive = false,
          widgetUri = if (hasWidget) widgetUri else null,
        )
      )
    }

    override suspend fun callToolJsonAsync(name: String, argsJson: String?): String {
      lastCall = listOf(name, argsJson.orEmpty())
      return "{\"content\":[{\"type\":\"text\",\"text\":\"lucky\"}]}"
    }
  }

  private class RecordingRuntime(
    private val planningResponse: String =
      "{\"tool_name\":\"show_today\",\"arguments\":{},\"confidence\":0.9,\"requires_tool\":true}"
  ) : ChatRuntimeExecutor {
    val inputs = mutableListOf<String>()
    override val descriptor =
      ChatRuntimeDescriptor(
        id = "local:test",
        providerId = "local",
        displayName = "Test model",
        modelId = "test-model",
        providerKind = ChatRuntimeProviderKind.LOCAL_MODEL,
        availability = ChatRuntimeAvailability.READY,
      )
    override val activeExecutionKey: ChatRuntimeExecutionKey? = null

    override suspend fun execute(request: ChatRuntimeRequest, listener: ChatRuntimeEventListener) {
      inputs += request.input
      val text =
        when {
          request.input.contains("Return ONLY one JSON object") ->
            planningResponse
          request.input.contains("external MCP tool") -> "final answer"
          else -> "direct answer"
        }
      listener.onEvent(ChatRuntimeEvent(KEY, ChatRuntimeEventType.TEXT_DELTA, text))
      listener.onEvent(ChatRuntimeEvent(KEY, ChatRuntimeEventType.COMPLETED))
    }

    override fun interrupt(key: ChatRuntimeExecutionKey): Boolean = true

    override suspend fun resetSession(config: ChatRuntimeSessionConfig) =
      ChatRuntimeResetResult(succeeded = true)

    override fun close() = Unit
  }

  private fun request(activeConnector: Boolean = true, input: String = "hello") =
    ChatRuntimeRequest(
      sessionId = KEY.sessionId,
      turnId = KEY.turnId,
      modelId = "test-model",
      input = input,
      context =
        mapOf(
          MCP_ACTIVE_CONNECTORS_CONTEXT_KEY to if (activeConnector) CONNECTOR_ID else ""
        ),
    )

  private companion object {
    const val CONNECTOR_ID = "fortune.ugot.uk/mcp"
    val KEY = ChatRuntimeExecutionKey("session", "turn")
  }
}
