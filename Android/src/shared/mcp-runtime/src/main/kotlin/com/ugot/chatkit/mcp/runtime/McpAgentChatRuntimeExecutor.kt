/*
 * Copyright 2026 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     https://www.apache.org/licenses/LICENSE-2.0
 */

package com.ugot.chatkit.mcp.runtime

import android.util.Log
import com.ugot.chatkit.mcp.core.AgentToolPlanningDescriptor
import com.ugot.chatkit.mcp.core.AgentToolPlanningRequest
import com.ugot.chatkit.mcp.core.buildAgentToolPlanningPrompt
import com.ugot.chatkit.mcp.core.parseAgentToolPlanningDecision
import com.ugot.chatkit.mcp.core.selectApprovalGatedToolFallbackCandidate
import com.ugot.chatkit.mcp.core.selectSafeReadToolFallback
import com.ugot.chatkit.runtime.ChatRuntimeCapabilities
import com.ugot.chatkit.runtime.ChatRuntimeEvent
import com.ugot.chatkit.runtime.ChatRuntimeEventListener
import com.ugot.chatkit.runtime.ChatRuntimeEventType
import com.ugot.chatkit.runtime.ChatRuntimeExecutionKey
import com.ugot.chatkit.runtime.ChatRuntimeExecutor
import com.ugot.chatkit.runtime.ChatRuntimeMessage
import com.ugot.chatkit.runtime.ChatRuntimeMessageRole
import com.ugot.chatkit.runtime.ChatRuntimePermissionRequest
import com.ugot.chatkit.runtime.ChatRuntimePermissionResolver
import com.ugot.chatkit.runtime.ChatRuntimeRequest
import com.ugot.chatkit.runtime.ChatRuntimeResetResult
import com.ugot.chatkit.runtime.ChatRuntimeSessionConfig
import com.ugot.chatkit.runtime.ChatRuntimeToolActivity
import com.ugot.chatkit.runtime.ChatRuntimeWidget
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

const val MCP_ACTIVE_CONNECTORS_CONTEXT_KEY = "mcp.activeConnectorIds"
private const val MAX_FINAL_USER_PROMPT_CHARS = 500
private const val MAX_FINAL_TOOL_RESULT_CHARS = 1_300
private const val MCP_AGENT_RUNTIME_LOG_TAG = "McpAgentRuntime"

/**
 * Shared model -> MCP planner -> tool -> observation -> final-answer loop.
 *
 * The wrapped model remains provider-neutral. Planning is run in an isolated history lane so its
 * JSON never appears in the visible conversation or the model's next normal turn.
 */
class McpAgentChatRuntimeExecutor(
  private val delegate: ChatRuntimeExecutor,
  val session: McpToolGateway,
  private val connectorId: String,
  private val connectorTitle: String,
) : ChatRuntimeExecutor, ChatRuntimePermissionResolver {
  private data class PendingApproval(
    val executionKey: ChatRuntimeExecutionKey,
    val requestId: String,
    val decision: CompletableDeferred<Boolean>,
  )

  private val mutex = Mutex()
  private val activeExecution = AtomicReference<ChatRuntimeExecutionKey?>(null)
  private val pendingApproval = AtomicReference<PendingApproval?>(null)
  private val closed = AtomicBoolean(false)
  private var history: List<ChatRuntimeMessage> = emptyList()
  private var sessionConfig: ChatRuntimeSessionConfig? = null

  override val descriptor =
    delegate.descriptor.copy(
      capabilities =
        delegate.descriptor.capabilities.copy(
          tools = true,
        )
    )

  override val activeExecutionKey: ChatRuntimeExecutionKey?
    get() = activeExecution.get()

  override suspend fun execute(
    request: ChatRuntimeRequest,
    listener: ChatRuntimeEventListener,
  ) = mutex.withLock {
    check(!closed.get()) { "Runtime executor is closed" }
    val key = ChatRuntimeExecutionKey(request.sessionId, request.turnId)
    activeExecution.set(key)
    listener.onEvent(ChatRuntimeEvent(key, ChatRuntimeEventType.PREPARING))

    try {
      val connectorActive =
        request.context[MCP_ACTIVE_CONNECTORS_CONTEXT_KEY]
          .orEmpty()
          .split(',')
          .map(String::trim)
          .any { it == connectorId }
      if (!connectorActive) {
        val answer = runInference(request, request.input, forwardDeltas = true, listener = listener)
        recordVisibleTurn(request.input, answer)
        listener.onEvent(ChatRuntimeEvent(key, ChatRuntimeEventType.COMPLETED))
        return@withLock
      }

      val tools = session.listTools()
      if (tools.isEmpty()) {
        val answer = runInference(request, request.input, forwardDeltas = true, listener = listener)
        recordVisibleTurn(request.input, answer)
        listener.onEvent(ChatRuntimeEvent(key, ChatRuntimeEventType.COMPLETED))
        return@withLock
      }

      val planningTools = tools.map(McpToolDescriptor::toPlanningDescriptor)
      val deterministicReadTool =
        selectSafeReadToolFallback(userPrompt = request.input, tools = planningTools)
          ?.name
          ?.let { selected -> tools.firstOrNull { it.name == selected } }
      var planningText = ""
      var decision: com.ugot.chatkit.mcp.core.AgentToolPlanningDecision? = null
      var plannedTool: McpToolDescriptor? = null
      var fallbackTool: McpToolDescriptor? = deterministicReadTool

      if (deterministicReadTool == null) {
        listener.onEvent(
          ChatRuntimeEvent(
            executionKey = key,
            type = ChatRuntimeEventType.TOOL_ACTIVITY,
            toolActivity = ChatRuntimeToolActivity("도구 선택 중", connectorTitle),
          )
        )
        val planningPrompt =
          buildAgentToolPlanningPrompt(
            AgentToolPlanningRequest(
              userPrompt = request.input,
              connectorId = connectorId,
              connectorTitle = connectorTitle,
              tools = planningTools,
              stepIndex = 1,
              maxSteps = 1,
            )
          )
        planningText =
          runInference(request, planningPrompt, forwardDeltas = false, listener = listener)
        decision = parseAgentToolPlanningDecision(planningText)
        plannedTool =
          decision
            ?.takeIf { it.shouldUseTool }
            ?.toolName
            ?.let { selected -> tools.firstOrNull { it.name == selected } }
        fallbackTool =
          if (decision == null) {
            planningTools.selectApprovalGatedToolFallbackCandidate(request.input)
              ?.name
              ?.let { selected -> tools.firstOrNull { it.name == selected } }
          } else {
            null
          }
      }

      val tool = plannedTool ?: fallbackTool
      val toolArgumentsJson = plannedTool?.let { decision?.argumentsJson } ?: "{}"
      runCatching {
        Log.i(
          MCP_AGENT_RUNTIME_LOG_TAG,
          "Route=${if (deterministicReadTool != null) "deterministic-read" else "model"}, " +
            "plannerChars=${planningText.length}, parsed=${decision != null}, " +
            "planned=${plannedTool?.name ?: "none"}, fallback=${fallbackTool?.name ?: "none"}, " +
            "catalogSize=${tools.size}",
        )
      }

      if (tool == null) {
        resetDelegate(request)
        val answer = runInference(request, request.input, forwardDeltas = true, listener = listener)
        recordVisibleTurn(request.input, answer)
        listener.onEvent(ChatRuntimeEvent(key, ChatRuntimeEventType.COMPLETED))
        return@withLock
      }

      if (!tool.isReadOnly || tool.isDestructive) {
        val requestId = "${key.turnId}:${tool.name}"
        val approval = PendingApproval(key, requestId, CompletableDeferred())
        pendingApproval.set(approval)
        listener.onEvent(
          ChatRuntimeEvent(
            executionKey = key,
            type = ChatRuntimeEventType.APPROVAL_REQUIRED,
            permission =
              ChatRuntimePermissionRequest(
                requestId = requestId,
                title = tool.title,
                rationale = "${connectorTitle}에서 ${tool.name} 도구를 실행합니다.",
                riskLabel = if (tool.isDestructive) "삭제 또는 초기화가 발생할 수 있습니다." else "외부 상태가 변경될 수 있습니다.",
              ),
          )
        )
        if (!approval.decision.await()) {
          pendingApproval.compareAndSet(approval, null)
          resetDelegate(request)
          val deniedPrompt =
            "${request.input}\n\nThe requested external tool was denied by the user. Answer without claiming that it ran."
          val answer = runInference(request, deniedPrompt, forwardDeltas = true, listener = listener)
          recordVisibleTurn(request.input, answer)
          listener.onEvent(ChatRuntimeEvent(key, ChatRuntimeEventType.COMPLETED))
          return@withLock
        }
        pendingApproval.compareAndSet(approval, null)
      }

      listener.onEvent(
        ChatRuntimeEvent(
          executionKey = key,
          type = ChatRuntimeEventType.TOOL_ACTIVITY,
          toolActivity = ChatRuntimeToolActivity(tool.title, "${connectorTitle} 도구 실행 중"),
        )
      )
      val toolResult = session.callToolJsonAsync(tool.name, toolArgumentsJson)
      if (tool.hasWidget) {
        listener.onEvent(
          ChatRuntimeEvent(
            executionKey = key,
            type = ChatRuntimeEventType.WIDGET_AVAILABLE,
            widget =
              ChatRuntimeWidget(
                connectorId = connectorId,
                contentRef = session.widgetUri,
                title = tool.title,
                summary = tool.description.ifBlank { "${connectorTitle} interactive result" },
                stateJson = session.getWidgetStateJson(),
              ),
          )
        )
      }

      resetDelegate(request)
      val finalPrompt =
        buildString {
          appendLine(request.input.take(MAX_FINAL_USER_PROMPT_CHARS))
          appendLine()
          appendLine("The external MCP tool '${tool.name}' returned this result:")
          appendLine(toolResult.take(MAX_FINAL_TOOL_RESULT_CHARS))
          append("Answer the user directly from this result. Do not expose router JSON or invent fields.")
        }
      val answer = runInference(request, finalPrompt, forwardDeltas = true, listener = listener)
      recordVisibleTurn(request.input, answer)
      listener.onEvent(ChatRuntimeEvent(key, ChatRuntimeEventType.COMPLETED))
    } catch (error: Throwable) {
      listener.onEvent(
        ChatRuntimeEvent(
          executionKey = key,
          type = ChatRuntimeEventType.FAILED,
          text = error.message ?: "MCP tool loop failed",
        )
      )
    } finally {
      pendingApproval.getAndSet(null)?.decision?.complete(false)
      activeExecution.compareAndSet(key, null)
    }
  }

  private suspend fun runInference(
    request: ChatRuntimeRequest,
    prompt: String,
    forwardDeltas: Boolean,
    listener: ChatRuntimeEventListener,
  ): String {
    resetDelegate(request)
    val output = StringBuilder()
    var failure: String? = null
    delegate.execute(
      request.copy(input = prompt),
      ChatRuntimeEventListener { event ->
        when (event.type) {
          ChatRuntimeEventType.TEXT_DELTA -> {
            output.append(event.text)
            if (forwardDeltas) listener.onEvent(event)
          }
          ChatRuntimeEventType.THINKING_DELTA -> if (forwardDeltas) listener.onEvent(event)
          ChatRuntimeEventType.FAILED -> failure = event.text
          ChatRuntimeEventType.INTERRUPTED -> failure = "Interrupted"
          else -> Unit
        }
      },
    )
    failure?.let(::error)
    return output.toString()
  }

  private suspend fun resetDelegate(request: ChatRuntimeRequest) {
    val previous = sessionConfig
    val result =
      delegate.resetSession(
        ChatRuntimeSessionConfig(
          sessionId = request.sessionId,
          taskId = previous?.taskId ?: "mcp-agent",
          systemInstruction = previous?.systemInstruction,
          history = history,
          capabilities = descriptor.capabilities,
        )
      )
    check(result.succeeded) { result.message.ifBlank { "Runtime session reset failed" } }
  }

  private fun recordVisibleTurn(input: String, answer: String) {
    history =
      history +
        ChatRuntimeMessage(ChatRuntimeMessageRole.USER, input) +
        ChatRuntimeMessage(ChatRuntimeMessageRole.ASSISTANT, answer)
  }

  override fun interrupt(key: ChatRuntimeExecutionKey): Boolean {
    if (activeExecution.get() != key) return false
    pendingApproval.get()?.takeIf { it.executionKey == key }?.decision?.complete(false)
    delegate.interrupt(key)
    return true
  }

  override suspend fun resetSession(config: ChatRuntimeSessionConfig): ChatRuntimeResetResult =
    mutex.withLock {
      sessionConfig = config
      history = config.history
      delegate.resetSession(config.copy(capabilities = descriptor.capabilities))
    }

  override fun resolvePermission(
    executionKey: ChatRuntimeExecutionKey,
    requestId: String,
    allow: Boolean,
  ): Boolean {
    val approval = pendingApproval.get() ?: return false
    if (approval.executionKey != executionKey || approval.requestId != requestId) return false
    return approval.decision.complete(allow)
  }

  override fun close() {
    closed.set(true)
    pendingApproval.getAndSet(null)?.decision?.complete(false)
    activeExecution.get()?.let(delegate::interrupt)
    delegate.close()
  }
}

private fun McpToolDescriptor.toPlanningDescriptor(): AgentToolPlanningDescriptor =
  AgentToolPlanningDescriptor(
    name = name,
    title = title,
    description = description,
    isReadOnly = isReadOnly,
    isDestructive = isDestructive,
    hasWidget = hasWidget,
    requiredParameters = requiredParameters,
    parametersSummary = inputSchemaJson,
  )
