/*
 * Copyright 2025 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package com.google.ai.edge.gallery.ui.llmchat

import android.content.Context
import android.graphics.Bitmap
import android.util.Log
import androidx.lifecycle.viewModelScope
import com.google.ai.edge.gallery.data.ConfigKeys
import com.google.ai.edge.gallery.data.Model
import com.google.ai.edge.gallery.data.Task
import com.google.ai.edge.gallery.runtime.chat.GalleryChatRuntimeExecutor
import com.google.ai.edge.gallery.ui.common.chat.ChatMessageAudioClip
import com.google.ai.edge.gallery.ui.common.chat.ChatMessageError
import com.google.ai.edge.gallery.ui.common.chat.ChatMessageLoading
import com.google.ai.edge.gallery.ui.common.chat.ChatMessageText
import com.google.ai.edge.gallery.ui.common.chat.ChatMessageThinking
import com.google.ai.edge.gallery.ui.common.chat.ChatMessageType
import com.google.ai.edge.gallery.ui.common.chat.ChatMessageWarning
import com.google.ai.edge.gallery.ui.common.chat.ChatSide
import com.google.ai.edge.gallery.ui.common.chat.ChatViewModel
import com.google.ai.edge.gallery.ui.modelmanager.ModelManagerViewModel
import com.google.ai.edge.litertlm.Contents
import com.google.ai.edge.litertlm.ExperimentalApi
import com.google.ai.edge.litertlm.ToolProvider
import com.ugot.chatkit.runtime.ChatRuntimeAttachment
import com.ugot.chatkit.runtime.ChatRuntimeAttachmentKind
import com.ugot.chatkit.runtime.ChatRuntimeCapabilities
import com.ugot.chatkit.runtime.ChatRuntimeEventType
import com.ugot.chatkit.runtime.ChatRuntimeExecutionKey
import com.ugot.chatkit.runtime.ChatRuntimeRequest
import com.ugot.chatkit.runtime.ChatRuntimeSessionConfig
import com.ugot.chatkit.controller.ChatControllerConfig
import com.ugot.chatkit.controller.DefaultChatController
import com.ugot.chatkit.mcp.runtime.McpAgentChatRuntimeExecutor
import com.ugot.chatkit.mcp.runtime.McpUiSession
import com.ugot.chatkit.ui.ChatConnectorUi
import com.ugot.chatkit.ui.ChatEmptyStateUi
import dagger.hilt.android.lifecycle.HiltViewModel
import java.io.ByteArrayOutputStream
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import javax.inject.Inject
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

private const val TAG = "AGLlmChatViewModel"

@OptIn(ExperimentalApi::class)
open class LlmChatViewModelBase() : ChatViewModel() {
  private val runtimeExecutors = ConcurrentHashMap<String, GalleryChatRuntimeExecutor>()
  private val activeExecutions = ConcurrentHashMap<String, ChatRuntimeExecutionKey>()
  private val sharedControllers = ConcurrentHashMap<String, DefaultChatController>()

  fun sharedChatController(
    task: Task,
    model: Model,
    sessionId: String,
    mcpSession: McpUiSession? = null,
    activeConnectorIds: List<String> = emptyList(),
  ): DefaultChatController {
    val key =
      "$sessionId:${model.name}:${activeConnectorIds.joinToString(",")}:${System.identityHashCode(mcpSession)}"
    return sharedControllers.getOrPut(key) {
      val baseExecutor = GalleryChatRuntimeExecutor(model = model, coroutineScope = viewModelScope)
      val executor =
        if (mcpSession != null && activeConnectorIds.isNotEmpty()) {
          McpAgentChatRuntimeExecutor(
            delegate = baseExecutor,
            session = mcpSession,
            connectorId = activeConnectorIds.first(),
            connectorTitle = "UGOT Fortune",
          )
        } else {
          baseExecutor
        }
      DefaultChatController(
        scope = viewModelScope,
        config =
          ChatControllerConfig(
            sessionId = sessionId,
            taskId = task.id,
            title = "UGOT Chat",
            initialRuntimeId = executor.descriptor.id,
            emptyState =
              ChatEmptyStateUi(
                title = "Chat with ${model.displayName.ifBlank { model.name }}",
                description = "Run the selected model on your device with the shared UGOT Chat experience.",
              ),
            connectors =
              activeConnectorIds.map { connectorId ->
                ChatConnectorUi(
                  id = connectorId,
                  label = "Fortune",
                  active = true,
                )
              },
          ),
        executors = listOf(executor),
      )
    }
  }

  fun generateResponse(
    model: Model,
    sessionId: String,
    turnId: String,
    input: String,
    images: List<Bitmap> = listOf(),
    audioMessages: List<ChatMessageAudioClip> = listOf(),
    onFirstToken: (Model) -> Unit = {},
    onDone: () -> Unit = {},
    onError: (String) -> Unit,
    allowThinking: Boolean = false,
  ) {
    val accelerator = model.getStringConfigValue(key = ConfigKeys.ACCELERATOR, defaultValue = "")
    viewModelScope.launch(Dispatchers.Default) {
      setInProgress(true)
      setPreparing(true)
      addMessage(model = model, message = ChatMessageLoading(accelerator = accelerator))
      val executionKey = ChatRuntimeExecutionKey(sessionId = sessionId, turnId = turnId)
      activeExecutions[model.name] = executionKey
      val firstTokenDelivered = AtomicBoolean(false)
      val start = System.currentTimeMillis()

      val attachments =
        images.map { bitmap ->
          ChatRuntimeAttachment(
            kind = ChatRuntimeAttachmentKind.IMAGE,
            mimeType = "image/png",
            bytes = bitmap.toPngByteArray(),
          )
        } +
          audioMessages.map { audio ->
            ChatRuntimeAttachment(
              kind = ChatRuntimeAttachmentKind.AUDIO,
              mimeType = "audio/wav",
              bytes = audio.genByteArrayForWav(),
            )
          }
      val executor =
        runtimeExecutors.getOrPut(model.name) {
          GalleryChatRuntimeExecutor(model = model, coroutineScope = viewModelScope)
        }
      try {
        executor.execute(
          request =
            ChatRuntimeRequest(
              sessionId = sessionId,
              turnId = turnId,
              modelId = model.name,
              input = input,
              attachments = attachments,
              allowThinking = allowThinking,
            ),
          listener = { event ->
            if (activeExecutions[model.name] != event.executionKey) return@execute
            when (event.type) {
              ChatRuntimeEventType.PREPARING -> Unit
              ChatRuntimeEventType.THINKING_DELTA -> {
                removeLoadingMessage(model)
                appendThinkingDelta(model, accelerator, event.text)
                deliverFirstToken(firstTokenDelivered, model, onFirstToken)
              }
              ChatRuntimeEventType.TEXT_DELTA -> {
                removeLoadingMessage(model)
                finishThinkingMessage(model)
                appendTextDelta(model, accelerator, event.text)
                deliverFirstToken(firstTokenDelivered, model, onFirstToken)
              }
              ChatRuntimeEventType.TOOL_ACTIVITY,
              ChatRuntimeEventType.WIDGET_AVAILABLE,
              ChatRuntimeEventType.APPROVAL_REQUIRED -> Unit
              ChatRuntimeEventType.COMPLETED -> {
                removeLoadingMessage(model)
                finishThinkingMessage(model)
                if (getLastMessage(model) is ChatMessageText) {
                  updateLastTextMessageContentIncrementally(
                    model = model,
                    partialContent = "",
                    latencyMs = (System.currentTimeMillis() - start).toFloat(),
                  )
                }
                setInProgress(false)
                setPreparing(false)
                onDone()
              }
              ChatRuntimeEventType.FAILED -> {
                Log.e(TAG, "Chat runtime failed: ${event.text}")
                removeLoadingMessage(model)
                setInProgress(false)
                setPreparing(false)
                onError(event.text)
              }
              ChatRuntimeEventType.INTERRUPTED -> {
                removeLoadingMessage(model)
                finishThinkingMessage(model)
                setInProgress(false)
                setPreparing(false)
              }
            }
          },
        )
      } catch (cancelled: CancellationException) {
        throw cancelled
      } catch (error: Exception) {
        if (activeExecutions[model.name] == executionKey) {
          Log.e(TAG, "Chat runtime execution failed", error)
          removeLoadingMessage(model)
          setInProgress(false)
          setPreparing(false)
          onError(error.message ?: "Chat runtime execution failed")
        }
      } finally {
        activeExecutions.remove(model.name, executionKey)
      }
    }
  }

  fun stopResponse(model: Model) {
    Log.d(TAG, "Stopping response for model ${model.name}...")
    if (getLastMessage(model = model) is ChatMessageLoading) {
      removeLastMessage(model = model)
    }
    setInProgress(false)
    val execution = activeExecutions[model.name]
    if (execution != null) {
      runtimeExecutors[model.name]?.interrupt(execution)
    }
    Log.d(TAG, "Done stopping response")
  }

  override fun onCleared() {
    sharedControllers.values.forEach(DefaultChatController::close)
    sharedControllers.clear()
    runtimeExecutors.values.forEach(GalleryChatRuntimeExecutor::close)
    runtimeExecutors.clear()
    super.onCleared()
  }

  fun resetSession(
    task: Task,
    model: Model,
    sessionId: String,
    systemInstruction: Contents? = null,
    tools: List<ToolProvider> = listOf(),
    supportImage: Boolean = false,
    supportAudio: Boolean = false,
    onDone: () -> Unit = {},
    enableConversationConstrainedDecoding: Boolean = false,
  ) {
    viewModelScope.launch(Dispatchers.Default) {
      setIsResettingSession(true)
      stopResponse(model = model)
      val executor =
        runtimeExecutors.getOrPut(model.name) {
          GalleryChatRuntimeExecutor(model = model, coroutineScope = viewModelScope)
        }
      val result =
        executor.resetSession(
          config =
            ChatRuntimeSessionConfig(
              sessionId = sessionId,
              taskId = task.id,
              capabilities =
                ChatRuntimeCapabilities(image = supportImage, audio = supportAudio, tools = true),
            ),
          tools = tools,
          enableConversationConstrainedDecoding = enableConversationConstrainedDecoding,
          systemInstructionOverride = systemInstruction,
        )
      if (result.succeeded) {
        clearAllMessages(model = model)
        onDone()
      } else {
        addMessage(model = model, message = ChatMessageError(content = result.message))
      }
      setIsResettingSession(false)
    }
  }

  fun runAgain(
    model: Model,
    sessionId: String,
    message: ChatMessageText,
    onError: (String) -> Unit,
    allowThinking: Boolean = false,
  ) {
    viewModelScope.launch(Dispatchers.Default) {
      addMessage(model = model, message = message.clone())
      generateResponse(
        model = model,
        sessionId = sessionId,
        turnId = "turn_${UUID.randomUUID()}",
        input = message.content,
        onError = onError,
        allowThinking = allowThinking,
      )
    }
  }

  private fun removeLoadingMessage(model: Model) {
    if (getLastMessage(model) is ChatMessageLoading) removeLastMessage(model)
  }

  private fun deliverFirstToken(
    delivered: AtomicBoolean,
    model: Model,
    onFirstToken: (Model) -> Unit,
  ) {
    if (delivered.compareAndSet(false, true)) {
      setPreparing(false)
      onFirstToken(model)
    }
  }

  private fun appendThinkingDelta(model: Model, accelerator: String, text: String) {
    val last = getLastMessage(model)
    if (last !is ChatMessageThinking) {
      addMessage(
        model = model,
        message =
          ChatMessageThinking(
            content = "",
            inProgress = true,
            side = ChatSide.AGENT,
            accelerator = accelerator,
            hideSenderLabel = last?.type == ChatMessageType.COLLAPSABLE_PROGRESS_PANEL,
          ),
      )
    }
    updateLastThinkingMessageContentIncrementally(model = model, partialContent = text)
  }

  private fun finishThinkingMessage(model: Model) {
    val thinking = getLastMessage(model) as? ChatMessageThinking ?: return
    if (!thinking.inProgress) return
    replaceLastMessage(
      model = model,
      message =
        ChatMessageThinking(
          content = thinking.content,
          inProgress = false,
          side = thinking.side,
          hideSenderLabel = thinking.hideSenderLabel,
          accelerator = thinking.accelerator,
        ),
      type = ChatMessageType.THINKING,
    )
  }

  private fun appendTextDelta(model: Model, accelerator: String, text: String) {
    val last = getLastMessage(model)
    if (last !is ChatMessageText || last.side != ChatSide.AGENT) {
      addMessage(
        model = model,
        message =
          ChatMessageText(
            content = "",
            side = ChatSide.AGENT,
            accelerator = accelerator,
            hideSenderLabel =
              last?.type == ChatMessageType.COLLAPSABLE_PROGRESS_PANEL ||
                last?.type == ChatMessageType.THINKING,
          ),
      )
    }
    updateLastTextMessageContentIncrementally(model = model, partialContent = text, latencyMs = -1f)
  }

  private fun Bitmap.toPngByteArray(): ByteArray =
    ByteArrayOutputStream().use { output ->
      check(compress(Bitmap.CompressFormat.PNG, 100, output)) { "Failed to encode image" }
      output.toByteArray()
    }

  fun handleError(
    context: Context,
    task: Task,
    model: Model,
    modelManagerViewModel: ModelManagerViewModel,
    errorMessage: String,
  ) {
    // Remove the "loading" message.
    if (getLastMessage(model = model) is ChatMessageLoading) {
      removeLastMessage(model = model)
    }

    // Show error message.
    addMessage(model = model, message = ChatMessageError(content = errorMessage))

    // Clean up and re-initialize.
    viewModelScope.launch(Dispatchers.Default) {
      modelManagerViewModel.cleanupModel(
        context = context,
        task = task,
        model = model,
        onDone = {
          modelManagerViewModel.initializeModel(context = context, task = task, model = model)

          // Add a warning message for re-initializing the session.
          addMessage(
            model = model,
            message = ChatMessageWarning(content = "Session re-initialized"),
          )
        },
      )
    }
  }
}

@HiltViewModel class LlmChatViewModel @Inject constructor() : LlmChatViewModelBase()

@HiltViewModel class LlmAskImageViewModel @Inject constructor() : LlmChatViewModelBase()

@HiltViewModel class LlmAskAudioViewModel @Inject constructor() : LlmChatViewModelBase()
