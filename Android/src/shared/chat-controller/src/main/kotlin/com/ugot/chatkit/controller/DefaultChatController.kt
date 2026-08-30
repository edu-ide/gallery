/*
 * Copyright 2026 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     https://www.apache.org/licenses/LICENSE-2.0
 */

package com.ugot.chatkit.controller

import com.ugot.chatkit.runtime.ChatRuntimeAvailability
import com.ugot.chatkit.runtime.ChatRuntimeEvent
import com.ugot.chatkit.runtime.ChatRuntimeEventListener
import com.ugot.chatkit.runtime.ChatRuntimeEventType
import com.ugot.chatkit.runtime.ChatRuntimeExecutionKey
import com.ugot.chatkit.runtime.ChatRuntimeExecutor
import com.ugot.chatkit.runtime.ChatRuntimeMessage
import com.ugot.chatkit.runtime.ChatRuntimeMessageRole
import com.ugot.chatkit.runtime.ChatRuntimePermissionResolver
import com.ugot.chatkit.runtime.ChatRuntimeRequest
import com.ugot.chatkit.runtime.ChatRuntimeSessionConfig
import com.ugot.chatkit.runtime.ExplicitChatRuntimeRegistry
import com.ugot.chatkit.ui.ChatBlockUi
import com.ugot.chatkit.ui.ChatComposerUiState
import com.ugot.chatkit.ui.ChatConnectorUi
import com.ugot.chatkit.ui.ChatEmptyStateUi
import com.ugot.chatkit.ui.ChatMessageUi
import com.ugot.chatkit.ui.ChatModelState
import com.ugot.chatkit.ui.ChatModelUi
import com.ugot.chatkit.ui.ChatPermissionDecision
import com.ugot.chatkit.ui.ChatPermissionKind
import com.ugot.chatkit.ui.ChatPermissionUiState
import com.ugot.chatkit.ui.ChatRole
import com.ugot.chatkit.ui.ChatSurfaceState
import com.ugot.chatkit.ui.ChatTurnActivityUiState
import com.ugot.chatkit.ui.ChatUiIntent
import com.ugot.chatkit.ui.ChatWidgetDisplayMode
import com.ugot.chatkit.ui.ChatWidgetUiState
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

data class ChatControllerConfig(
  val sessionId: String,
  val taskId: String,
  val title: String,
  val initialRuntimeId: String,
  val emptyState: ChatEmptyStateUi? = null,
  val systemInstruction: String? = null,
  val connectors: List<ChatConnectorUi> = emptyList(),
  val labels: ChatControllerLabels = ChatControllerLabels(),
) {
  init {
    require(sessionId.isNotBlank()) { "Session id must not be blank" }
    require(taskId.isNotBlank()) { "Task id must not be blank" }
    require(title.isNotBlank()) { "Title must not be blank" }
    require(initialRuntimeId.isNotBlank()) { "Initial runtime id must not be blank" }
  }
}

data class ChatControllerLabels(
  val ready: String = "Ready",
  val modelRequired: String = "Model required",
  val unsupported: String = "Unsupported",
  val unavailable: String = "Unavailable",
  val setup: String = "Set up",
  val preparingResponse: String = "Preparing response",
  val writingResponse: String = "Writing response",
  val userSender: String = "You",
  val runtimeFailed: String = "Chat runtime failed",
)

fun interface ChatHostEffectHandler {
  fun handle(intent: ChatUiIntent)
}

class DefaultChatController(
  private val scope: CoroutineScope,
  private val config: ChatControllerConfig,
  executors: List<ChatRuntimeExecutor>,
  private val hostEffectHandler: ChatHostEffectHandler = ChatHostEffectHandler {},
  private val onRuntimeSelected: (String) -> Unit = {},
) : AutoCloseable {
  private val registry = ExplicitChatRuntimeRegistry(executors)
  private val executorsById = executors.associateBy { it.descriptor.id }
  private val messageSequence = AtomicLong()
  private val turnSequence = AtomicLong()
  private var selectedRuntimeId = config.initialRuntimeId
  private var activeExecution: ChatRuntimeExecutionKey? = null
  private var activeJob: Job? = null
  private val pendingDeltaLock = Any()
  private val pendingDeltas = mutableListOf<PendingDelta>()
  private var pendingDeltaExecution: ChatRuntimeExecutionKey? = null
  private var pendingDeltaFlushJob: Job? = null
  private val runtimeEvents = Channel<ChatRuntimeEvent>(Channel.UNLIMITED)
  private val runtimeEventJob = scope.launch {
    for (event in runtimeEvents) reduceRuntimeEvent(event)
  }
  private val runtimeEventListener = ChatRuntimeEventListener { event -> runtimeEvents.trySend(event) }

  private val _state = MutableStateFlow(initialState())
  val state: StateFlow<ChatSurfaceState> = _state.asStateFlow()

  fun onIntent(intent: ChatUiIntent) {
    when (intent) {
      is ChatUiIntent.DraftChanged -> updateDraft(intent.value)
      is ChatUiIntent.SuggestionClicked -> updateDraft(intent.value)
      ChatUiIntent.SendClicked -> send()
      ChatUiIntent.StopClicked -> stop()
      ChatUiIntent.ResetConversationClicked -> resetConversation()
      is ChatUiIntent.ModelSelected -> selectRuntime(intent.id)
      is ChatUiIntent.ConnectorToggled -> toggleConnector(intent.id)
      is ChatUiIntent.OpenWidget -> openWidget(intent.messageId, intent.fullscreen)
      is ChatUiIntent.ResolvePermission -> resolvePermission(intent)
      ChatUiIntent.CloseWidget -> {
        _state.update { it.copy(activeWidget = null) }
        hostEffectHandler.handle(intent)
      }
      ChatUiIntent.CloseAttachmentViewer ->
        _state.update { it.copy(attachmentViewer = null) }
      ChatUiIntent.HistoryDismissed ->
        _state.update { current -> current.copy(history = current.history?.copy(visible = false)) }
      else -> hostEffectHandler.handle(intent)
    }
  }

  fun restore(messages: List<ChatMessageUi>) {
    check(activeExecution == null) { "Cannot restore while a turn is running" }
    _state.update { current -> current.copy(messages = messages.toList(), error = null) }
  }

  fun snapshot(): List<ChatMessageUi> = _state.value.messages.toList()

  fun updateHostStatus(restoring: Boolean, error: String? = null) {
    _state.update { current ->
      current.copy(
        restoring = restoring,
        composer =
          current.composer.copy(
            enabled = !restoring && selectedRuntimeIsReady(),
          ),
        error = error,
      )
    }
  }

  private fun initialState(): ChatSurfaceState {
    val descriptors = registry.descriptors()
    val selected = descriptors.firstOrNull { it.id == selectedRuntimeId }
    return ChatSurfaceState(
      conversationId = config.sessionId,
      title = config.title,
      providerLabel = selected?.displayName.orEmpty(),
      composer =
        ChatComposerUiState(enabled = selected?.availability == ChatRuntimeAvailability.READY),
      models = descriptors.map { descriptor -> descriptor.toUiModel(selectedRuntimeId, config.labels) },
      connectors = config.connectors,
      emptyState = config.emptyState,
      error = selected?.unavailableReason,
    )
  }

  private fun updateDraft(value: String) {
    _state.update { current -> current.copy(composer = current.composer.copy(draft = value)) }
  }

  private fun selectRuntime(runtimeId: String) {
    if (runtimeId == selectedRuntimeId) return
    val selection = registry.select(runtimeId)
    val executor = selection.executor
    if (executor == null) {
      _state.update { it.copy(error = selection.message) }
      return
    }
    stop()
    _state.update {
      it.copy(
        restoring = true,
        composer = it.composer.copy(enabled = false),
        error = null,
      )
    }
    scope.launch {
      val result =
        executor.resetSession(
          ChatRuntimeSessionConfig(
            sessionId = config.sessionId,
            taskId = config.taskId,
            systemInstruction = config.systemInstruction,
            history = _state.value.messages.mapNotNull(ChatMessageUi::toRuntimeMessage),
            capabilities = executor.descriptor.capabilities,
          )
        )
      if (result.succeeded) {
        selectedRuntimeId = runtimeId
        onRuntimeSelected(runtimeId)
      }
      publishRuntimeState(error = result.takeUnless { it.succeeded }?.message)
    }
  }

  private fun send() {
    val snapshot = _state.value
    val input = snapshot.composer.draft.trim()
    if (input.isEmpty() || snapshot.composer.inProgress) return
    val selection = registry.select(selectedRuntimeId)
    val executor = selection.executor
    if (executor == null) {
      _state.update { it.copy(error = selection.message) }
      return
    }

    val executionKey =
      ChatRuntimeExecutionKey(
        sessionId = config.sessionId,
        turnId = "turn_${turnSequence.getAndIncrement()}",
      )
    activeExecution = executionKey
    _state.update { current ->
      current.copy(
        messages = current.messages + message(ChatRole.USER, input),
        composer = current.composer.copy(draft = "", inProgress = true),
        turnActivity =
          ChatTurnActivityUiState(
            title = config.labels.preparingResponse,
            detail = executor.descriptor.displayName,
            showsProgress = true,
          ),
        error = null,
      )
    }
    activeJob =
      scope.launch {
        runCatching {
            executor.execute(
              ChatRuntimeRequest(
                sessionId = executionKey.sessionId,
                turnId = executionKey.turnId,
                modelId = executor.descriptor.modelId,
                input = input,
                allowThinking = executor.descriptor.capabilities.thinking,
                context =
                  mapOf(
                    ACTIVE_CONNECTORS_CONTEXT_KEY to
                      snapshot.connectors.filter(ChatConnectorUi::active).joinToString(",") { it.id }
                  ),
              ),
              runtimeEventListener,
            )
          }
          .onFailure { error ->
            if (activeExecution == executionKey) {
              finishTurn(error.message ?: config.labels.runtimeFailed)
            }
          }
      }
  }

  private fun reduceRuntimeEvent(event: ChatRuntimeEvent) {
    if (activeExecution != event.executionKey) return
    when (event.type) {
      ChatRuntimeEventType.PREPARING -> Unit
      ChatRuntimeEventType.TEXT_DELTA -> enqueueDelta(event.executionKey, event.text, thinking = false)
      ChatRuntimeEventType.THINKING_DELTA ->
        enqueueDelta(event.executionKey, event.text, thinking = true)
      ChatRuntimeEventType.TOOL_ACTIVITY -> {
        event.toolActivity?.let { activity ->
          _state.update { current ->
            current.copy(
              turnActivity =
                ChatTurnActivityUiState(
                  title = activity.title,
                  detail = activity.detail,
                  showsProgress = activity.showsProgress,
                )
            )
          }
        }
      }
      ChatRuntimeEventType.WIDGET_AVAILABLE -> {
        flushPendingDeltas(event.executionKey)
        event.widget?.let(::appendWidget)
      }
      ChatRuntimeEventType.APPROVAL_REQUIRED -> {
        flushPendingDeltas(event.executionKey)
        event.permission?.let { permission ->
          _state.update { current ->
            current.copy(
              pendingPermission =
                ChatPermissionUiState(
                  requestId = permission.requestId,
                  kind = ChatPermissionKind.MCP_TOOL,
                  title = permission.title,
                  rationale = permission.rationale,
                  riskLabel = permission.riskLabel,
                )
            )
          }
        }
      }
      ChatRuntimeEventType.COMPLETED -> {
        flushPendingDeltas(event.executionKey)
        finishTurn()
      }
      ChatRuntimeEventType.FAILED -> {
        flushPendingDeltas(event.executionKey)
        finishTurn(event.text)
      }
      ChatRuntimeEventType.INTERRUPTED -> {
        flushPendingDeltas(event.executionKey)
        finishTurn()
      }
    }
  }

  private fun enqueueDelta(
    executionKey: ChatRuntimeExecutionKey,
    delta: String,
    thinking: Boolean,
  ) {
    if (delta.isEmpty()) return
    val scheduledJob =
      synchronized(pendingDeltaLock) {
        if (pendingDeltaExecution != executionKey) {
          pendingDeltaFlushJob?.cancel()
          pendingDeltaFlushJob = null
          pendingDeltas.clear()
          pendingDeltaExecution = executionKey
        }
        val last = pendingDeltas.lastOrNull()
        if (last?.thinking == thinking) {
          last.text.append(delta)
        } else {
          pendingDeltas += PendingDelta(thinking = thinking, text = StringBuilder(delta))
        }
        if (pendingDeltaFlushJob == null) {
          scope
            .launch(start = CoroutineStart.LAZY) {
              delay(DELTA_FLUSH_INTERVAL_MS)
              flushPendingDeltas(executionKey)
            }
            .also { pendingDeltaFlushJob = it }
        } else {
          null
        }
      }
    scheduledJob?.start()
  }

  private fun flushPendingDeltas(executionKey: ChatRuntimeExecutionKey) {
    val batch: List<PendingDeltaSnapshot>
    val scheduledJob: Job?
    synchronized(pendingDeltaLock) {
      if (pendingDeltaExecution != executionKey) return
      batch = pendingDeltas.map { PendingDeltaSnapshot(it.thinking, it.text.toString()) }
      pendingDeltas.clear()
      pendingDeltaExecution = null
      scheduledJob = pendingDeltaFlushJob
      pendingDeltaFlushJob = null
    }
    scheduledJob?.cancel()
    appendDeltaBatch(executionKey, batch)
  }

  private fun discardPendingDeltas(executionKey: ChatRuntimeExecutionKey) {
    val scheduledJob: Job?
    synchronized(pendingDeltaLock) {
      if (pendingDeltaExecution != executionKey) return
      pendingDeltas.clear()
      pendingDeltaExecution = null
      scheduledJob = pendingDeltaFlushJob
      pendingDeltaFlushJob = null
    }
    scheduledJob?.cancel()
  }

  private fun appendDeltaBatch(
    executionKey: ChatRuntimeExecutionKey,
    batch: List<PendingDeltaSnapshot>,
  ) {
    if (batch.isEmpty()) return
    _state.update { current ->
      if (activeExecution != executionKey) return@update current
      val last = current.messages.lastOrNull()
      val appendingToExisting = last?.role == ChatRole.ASSISTANT && last.inProgress
      val assistant =
        if (appendingToExisting) {
          requireNotNull(last)
        } else {
          ChatMessageUi(
            id = "message_${messageSequence.getAndIncrement()}",
            role = ChatRole.ASSISTANT,
            blocks = emptyList(),
            senderLabel = config.title,
            inProgress = true,
          )
        }
      val blocks = assistant.blocks.toMutableList()
      batch.forEach { pending ->
        val index =
          blocks.indexOfLast {
            if (pending.thinking) it is ChatBlockUi.Thinking else it is ChatBlockUi.Text
          }
        if (index >= 0) {
          blocks[index] =
            if (pending.thinking) {
              val block = blocks[index] as ChatBlockUi.Thinking
              block.copy(value = block.value + pending.text, inProgress = true)
            } else {
              val block = blocks[index] as ChatBlockUi.Text
              block.copy(value = block.value + pending.text)
            }
        } else {
          blocks +=
            if (pending.thinking) ChatBlockUi.Thinking(pending.text, inProgress = true)
            else ChatBlockUi.Text(pending.text)
        }
      }
      current.copy(
        messages =
          if (appendingToExisting) {
            current.messages.dropLast(1) + assistant.copy(blocks = blocks)
          } else {
            current.messages + assistant.copy(blocks = blocks)
          },
        turnActivity =
          ChatTurnActivityUiState(
            title = config.labels.writingResponse,
            detail = current.providerLabel,
            showsProgress = true,
          ),
      )
    }
  }

  private fun finishTurn(error: String? = null) {
    activeExecution = null
    activeJob = null
    _state.update { current ->
      current.copy(
        messages =
          current.messages.mapIndexed { index, message ->
            if (index == current.messages.lastIndex && message.role == ChatRole.ASSISTANT) {
              message.copy(
                inProgress = false,
                blocks =
                  message.blocks.map { block ->
                    if (block is ChatBlockUi.Thinking) block.copy(inProgress = false) else block
                  },
              )
            } else {
              message
            }
          },
        composer = current.composer.copy(inProgress = false),
        turnActivity = null,
        pendingPermission = null,
        error = error?.takeIf(String::isNotBlank),
      )
    }
  }

  private fun stop() {
    val key = activeExecution ?: return
    activeExecution = null
    discardPendingDeltas(key)
    activeJob?.cancel()
    activeJob = null
    executorsById[selectedRuntimeId]?.interrupt(key)
    finishTurn()
  }

  private fun resetConversation() {
    stop()
    val executor = registry.select(selectedRuntimeId).executor ?: return
    _state.update {
      it.copy(
        restoring = true,
        composer = it.composer.copy(enabled = false),
        error = null,
      )
    }
    scope.launch {
      val result =
        executor.resetSession(
          ChatRuntimeSessionConfig(
            sessionId = config.sessionId,
            taskId = config.taskId,
            systemInstruction = config.systemInstruction,
            capabilities = executor.descriptor.capabilities,
          )
        )
      _state.update { current ->
        if (result.succeeded) {
          current.copy(
            messages = emptyList(),
            composer =
              current.composer.copy(
                draft = "",
                enabled = selectedRuntimeIsReady(),
                inProgress = false,
              ),
            turnActivity = null,
            activeWidget = null,
            pendingPermission = null,
            restoring = false,
            error = null,
          )
        } else {
          current.copy(
            composer = current.composer.copy(enabled = selectedRuntimeIsReady()),
            restoring = false,
            error = result.message,
          )
        }
      }
    }
  }

  private fun publishRuntimeState(error: String? = null) {
    val descriptors = registry.descriptors()
    val selected = descriptors.firstOrNull { it.id == selectedRuntimeId }
    _state.update { current ->
      current.copy(
        providerLabel = selected?.displayName.orEmpty(),
        models = descriptors.map { it.toUiModel(selectedRuntimeId, config.labels) },
        composer =
          current.composer.copy(
            enabled = selected?.availability == ChatRuntimeAvailability.READY,
            inProgress = false,
          ),
        restoring = false,
        error = error ?: selected?.unavailableReason,
      )
    }
  }

  private fun message(role: ChatRole, text: String): ChatMessageUi =
    ChatMessageUi(
      id = "message_${messageSequence.getAndIncrement()}",
      role = role,
      blocks = listOf(ChatBlockUi.Text(text)),
      senderLabel = if (role == ChatRole.USER) config.labels.userSender else config.title,
    )

  private fun selectedRuntimeIsReady(): Boolean =
    executorsById[selectedRuntimeId]?.descriptor?.availability == ChatRuntimeAvailability.READY

  private fun toggleConnector(connectorId: String) {
    _state.update { current ->
      current.copy(
        connectors =
          current.connectors.map { connector ->
            if (connector.id == connectorId && connector.enabled) {
              connector.copy(active = !connector.active)
            } else {
              connector
            }
          }
      )
    }
  }

  private fun openWidget(messageId: String, fullscreen: Boolean) {
    val widget =
      _state.value.messages
        .asSequence()
        .flatMap { it.blocks.asSequence() }
        .filterIsInstance<ChatBlockUi.Widget>()
        .map(ChatBlockUi.Widget::widget)
        .firstOrNull { it.messageId == messageId }
        ?: return
    _state.update { current ->
      current.copy(
        activeWidget =
          widget.copy(
            displayMode =
              if (fullscreen) ChatWidgetDisplayMode.FULLSCREEN else ChatWidgetDisplayMode.INLINE
          )
      )
    }
  }

  private fun resolvePermission(intent: ChatUiIntent.ResolvePermission) {
    val key = activeExecution ?: return
    val resolver = executorsById[selectedRuntimeId] as? ChatRuntimePermissionResolver ?: return
    val resolved =
      resolver.resolvePermission(
        executionKey = key,
        requestId = intent.requestId,
        allow = intent.decision == ChatPermissionDecision.ALLOW_ONCE,
      )
    if (resolved) {
      _state.update { current -> current.copy(pendingPermission = null) }
    }
  }

  private fun appendWidget(widget: com.ugot.chatkit.runtime.ChatRuntimeWidget) {
    val messageId = "message_${messageSequence.getAndIncrement()}"
    val widgetState =
      ChatWidgetUiState(
        messageId = messageId,
        title = widget.title,
        summary = widget.summary,
        connectorId = widget.connectorId,
        contentRef = widget.contentRef,
        stateJson = widget.stateJson,
        displayMode = ChatWidgetDisplayMode.INLINE,
      )
    _state.update { current ->
      val last = current.messages.lastOrNull()
      if (last?.role == ChatRole.ASSISTANT && last.inProgress) {
        current.copy(
          messages =
            current.messages.dropLast(1) +
              last.copy(blocks = last.blocks + ChatBlockUi.Widget(widgetState))
        )
      } else {
        current.copy(
          messages =
            current.messages +
              ChatMessageUi(
                id = messageId,
                role = ChatRole.ASSISTANT,
                blocks = listOf(ChatBlockUi.Widget(widgetState)),
                senderLabel = config.title,
                inProgress = true,
              )
        )
      }
    }
  }

  override fun close() {
    stop()
    runtimeEvents.close()
    runtimeEventJob.cancel()
    executorsById.values.forEach(ChatRuntimeExecutor::close)
  }
}

private const val ACTIVE_CONNECTORS_CONTEXT_KEY = "mcp.activeConnectorIds"
private const val DELTA_FLUSH_INTERVAL_MS = 32L

private data class PendingDelta(val thinking: Boolean, val text: StringBuilder)

private data class PendingDeltaSnapshot(val thinking: Boolean, val text: String)

private fun com.ugot.chatkit.runtime.ChatRuntimeDescriptor.toUiModel(
  selectedRuntimeId: String,
  labels: ChatControllerLabels,
): ChatModelUi =
  ChatModelUi(
    id = id,
    label = displayName,
    selected = id == selectedRuntimeId,
    enabled = availability == ChatRuntimeAvailability.READY,
    state =
      when (availability) {
        ChatRuntimeAvailability.READY -> ChatModelState.READY
        ChatRuntimeAvailability.REQUIRES_DOWNLOAD -> ChatModelState.REQUIRES_SETUP
        ChatRuntimeAvailability.UNSUPPORTED,
        ChatRuntimeAvailability.UNAVAILABLE -> ChatModelState.UNAVAILABLE
      },
    statusLabel =
      when (availability) {
        ChatRuntimeAvailability.READY -> labels.ready
        ChatRuntimeAvailability.REQUIRES_DOWNLOAD -> labels.modelRequired
        ChatRuntimeAvailability.UNSUPPORTED -> labels.unsupported
        ChatRuntimeAvailability.UNAVAILABLE -> labels.unavailable
      },
    setupActionLabel =
      if (availability == ChatRuntimeAvailability.REQUIRES_DOWNLOAD) labels.setup else null,
  )

private fun ChatMessageUi.toRuntimeMessage(): ChatRuntimeMessage? {
  val text = blocks.filterIsInstance<ChatBlockUi.Text>().joinToString(separator = "") { it.value }
  if (text.isBlank()) return null
  return ChatRuntimeMessage(
    role =
      when (role) {
        ChatRole.USER -> ChatRuntimeMessageRole.USER
        ChatRole.ASSISTANT -> ChatRuntimeMessageRole.ASSISTANT
        ChatRole.SYSTEM -> ChatRuntimeMessageRole.SYSTEM
      },
    text = text,
  )
}
