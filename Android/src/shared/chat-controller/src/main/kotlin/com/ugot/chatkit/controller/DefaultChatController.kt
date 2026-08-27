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
import com.ugot.chatkit.runtime.ChatRuntimeEventType
import com.ugot.chatkit.runtime.ChatRuntimeExecutionKey
import com.ugot.chatkit.runtime.ChatRuntimeExecutor
import com.ugot.chatkit.runtime.ChatRuntimeMessage
import com.ugot.chatkit.runtime.ChatRuntimeMessageRole
import com.ugot.chatkit.runtime.ChatRuntimeRequest
import com.ugot.chatkit.runtime.ChatRuntimeSessionConfig
import com.ugot.chatkit.runtime.ExplicitChatRuntimeRegistry
import com.ugot.chatkit.ui.ChatBlockUi
import com.ugot.chatkit.ui.ChatComposerUiState
import com.ugot.chatkit.ui.ChatEmptyStateUi
import com.ugot.chatkit.ui.ChatMessageUi
import com.ugot.chatkit.ui.ChatModelState
import com.ugot.chatkit.ui.ChatModelUi
import com.ugot.chatkit.ui.ChatRole
import com.ugot.chatkit.ui.ChatSurfaceState
import com.ugot.chatkit.ui.ChatTurnActivityUiState
import com.ugot.chatkit.ui.ChatUiIntent
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
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
              ),
              ::reduceRuntimeEvent,
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
      ChatRuntimeEventType.TEXT_DELTA -> appendDelta(event.text, thinking = false)
      ChatRuntimeEventType.THINKING_DELTA -> appendDelta(event.text, thinking = true)
      ChatRuntimeEventType.COMPLETED -> finishTurn()
      ChatRuntimeEventType.FAILED -> finishTurn(event.text)
      ChatRuntimeEventType.INTERRUPTED -> finishTurn()
    }
  }

  private fun appendDelta(delta: String, thinking: Boolean) {
    if (delta.isEmpty()) return
    _state.update { current ->
      val last = current.messages.lastOrNull()
      if (last?.role == ChatRole.ASSISTANT && last.inProgress) {
        val blocks = last.blocks.toMutableList()
        val index =
          blocks.indexOfLast {
            if (thinking) it is ChatBlockUi.Thinking else it is ChatBlockUi.Text
          }
        if (index >= 0) {
          blocks[index] =
            if (thinking) {
              val block = blocks[index] as ChatBlockUi.Thinking
              block.copy(value = block.value + delta, inProgress = true)
            } else {
              val block = blocks[index] as ChatBlockUi.Text
              block.copy(value = block.value + delta)
            }
        } else {
          blocks +=
            if (thinking) ChatBlockUi.Thinking(delta, inProgress = true)
            else ChatBlockUi.Text(delta)
        }
        current.copy(
          messages = current.messages.dropLast(1) + last.copy(blocks = blocks),
          turnActivity =
            ChatTurnActivityUiState(
              title = config.labels.writingResponse,
              detail = current.providerLabel,
              showsProgress = true,
            ),
        )
      } else {
        current.copy(
          messages =
            current.messages +
              ChatMessageUi(
                id = "message_${messageSequence.getAndIncrement()}",
                role = ChatRole.ASSISTANT,
                blocks =
                  listOf(
                    if (thinking) ChatBlockUi.Thinking(delta, inProgress = true)
                    else ChatBlockUi.Text(delta)
                  ),
                senderLabel = config.title,
                inProgress = true,
              ),
        )
      }
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
        error = error?.takeIf(String::isNotBlank),
      )
    }
  }

  private fun stop() {
    val key = activeExecution ?: return
    activeExecution = null
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

  override fun close() {
    stop()
    executorsById.values.forEach(ChatRuntimeExecutor::close)
  }
}

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
