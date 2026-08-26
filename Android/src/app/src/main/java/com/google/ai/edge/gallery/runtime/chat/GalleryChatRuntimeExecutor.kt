/*
 * Copyright 2026 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     https://www.apache.org/licenses/LICENSE-2.0
 */

package com.google.ai.edge.gallery.runtime.chat

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import com.google.ai.edge.gallery.data.ConfigKeys
import com.google.ai.edge.gallery.data.Model
import com.google.ai.edge.gallery.data.RuntimeType
import com.google.ai.edge.gallery.data.awaitInitialization
import com.google.ai.edge.gallery.runtime.aicore.AICoreChatMessage
import com.google.ai.edge.gallery.runtime.aicore.AICoreModelInstance
import com.google.ai.edge.gallery.runtime.runtimeHelper
import com.google.ai.edge.litertlm.Contents
import com.google.ai.edge.litertlm.Message
import com.google.ai.edge.litertlm.ToolProvider
import com.ugot.chatkit.runtime.ChatRuntimeAttachment
import com.ugot.chatkit.runtime.ChatRuntimeAttachmentKind
import com.ugot.chatkit.runtime.ChatRuntimeAvailability
import com.ugot.chatkit.runtime.ChatRuntimeCapabilities
import com.ugot.chatkit.runtime.ChatRuntimeDescriptor
import com.ugot.chatkit.runtime.ChatRuntimeEvent
import com.ugot.chatkit.runtime.ChatRuntimeEventListener
import com.ugot.chatkit.runtime.ChatRuntimeEventType
import com.ugot.chatkit.runtime.ChatRuntimeExecutionKey
import com.ugot.chatkit.runtime.ChatRuntimeExecutor
import com.ugot.chatkit.runtime.ChatRuntimeMessageRole
import com.ugot.chatkit.runtime.ChatRuntimeProviderKind
import com.ugot.chatkit.runtime.ChatRuntimeRequest
import com.ugot.chatkit.runtime.ChatRuntimeResetResult
import com.ugot.chatkit.runtime.ChatRuntimeSessionConfig
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlin.coroutines.resume
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** Android adapter that exposes Gallery's real LiteRT and device-AI runtimes through ChatKit. */
class GalleryChatRuntimeExecutor(
  private val model: Model,
  private val coroutineScope: CoroutineScope,
) : ChatRuntimeExecutor {
  private val lifecycleMutex = Mutex()
  private val activeExecution = AtomicReference<ChatRuntimeExecutionKey?>(null)
  private val interruptedExecution = AtomicReference<ChatRuntimeExecutionKey?>(null)
  private val closed = AtomicBoolean(false)

  override val descriptor: ChatRuntimeDescriptor = model.toChatRuntimeDescriptor()

  override val activeExecutionKey: ChatRuntimeExecutionKey?
    get() = activeExecution.get()

  override suspend fun execute(
    request: ChatRuntimeRequest,
    listener: ChatRuntimeEventListener,
  ) = lifecycleMutex.withLock {
    check(!closed.get()) { "Runtime executor is closed" }
    require(request.modelId == model.name) {
      "Runtime ${descriptor.id} cannot execute model ${request.modelId}"
    }
    val executionKey = ChatRuntimeExecutionKey(request.sessionId, request.turnId)
    if (descriptor.availability != ChatRuntimeAvailability.READY) {
      listener.onEvent(
        ChatRuntimeEvent(
          executionKey = executionKey,
          type = ChatRuntimeEventType.FAILED,
          text = descriptor.unavailableReason ?: "Runtime ${descriptor.displayName} is unavailable",
        )
      )
      return@withLock
    }

    activeExecution.set(executionKey)
    interruptedExecution.compareAndSet(executionKey, null)
    listener.onEvent(
      ChatRuntimeEvent(executionKey = executionKey, type = ChatRuntimeEventType.PREPARING)
    )
    try {
      model.awaitInitialization()
      if (model.instance == null) {
        listener.onEvent(
          ChatRuntimeEvent(
            executionKey = executionKey,
            type = ChatRuntimeEventType.FAILED,
            text = "Model ${model.displayName.ifBlank { model.name }} is not initialized",
          )
        )
        return@withLock
      }

      val images =
        request.attachments
          .filter { it.kind == ChatRuntimeAttachmentKind.IMAGE }
          .map { attachment -> attachment.decodeBitmap() }
      val audio =
        request.attachments
          .filter { it.kind == ChatRuntimeAttachmentKind.AUDIO }
          .map(ChatRuntimeAttachment::bytes)
      val finished = AtomicBoolean(false)

      suspendCancellableCoroutine { continuation ->
        fun finish(type: ChatRuntimeEventType, text: String = "") {
          if (finished.compareAndSet(false, true)) {
            listener.onEvent(
              ChatRuntimeEvent(executionKey = executionKey, type = type, text = text)
            )
            if (continuation.isActive) continuation.resume(Unit)
          }
        }

        continuation.invokeOnCancellation {
          interruptedExecution.set(executionKey)
          model.runtimeHelper.stopResponse(model)
        }

        model.runtimeHelper.runInference(
          model = model,
          input = request.input,
          images = images,
          audioClips = audio,
          coroutineScope = coroutineScope,
          extraContext =
            request.context +
              if (
                request.allowThinking &&
                  model.getBooleanConfigValue(ConfigKeys.ENABLE_THINKING, false)
              ) {
                mapOf("enable_thinking" to "true")
              } else {
                emptyMap()
              },
          resultListener = { text, done, thinking ->
            if (!thinking.isNullOrEmpty()) {
              listener.onEvent(
                ChatRuntimeEvent(
                  executionKey = executionKey,
                  type = ChatRuntimeEventType.THINKING_DELTA,
                  text = thinking,
                )
              )
            }
            if (text.isNotEmpty() && !text.startsWith("<ctrl")) {
              listener.onEvent(
                ChatRuntimeEvent(
                  executionKey = executionKey,
                  type = ChatRuntimeEventType.TEXT_DELTA,
                  text = text,
                )
              )
            }
            if (done) {
              finish(
                if (interruptedExecution.get() == executionKey) {
                  ChatRuntimeEventType.INTERRUPTED
                } else {
                  ChatRuntimeEventType.COMPLETED
                }
              )
            }
          },
          cleanUpListener = { finish(ChatRuntimeEventType.INTERRUPTED) },
          onError = { message -> finish(ChatRuntimeEventType.FAILED, message) },
        )
      }
    } catch (error: Throwable) {
      if (error is CancellationException) throw error
      listener.onEvent(
        ChatRuntimeEvent(
          executionKey = executionKey,
          type = ChatRuntimeEventType.FAILED,
          text = error.message ?: "Chat runtime failed",
        )
      )
    } finally {
      activeExecution.compareAndSet(executionKey, null)
      interruptedExecution.compareAndSet(executionKey, null)
    }
  }

  override fun interrupt(key: ChatRuntimeExecutionKey): Boolean {
    if (activeExecution.get() != key) return false
    interruptedExecution.set(key)
    model.runtimeHelper.stopResponse(model)
    return true
  }

  override suspend fun resetSession(config: ChatRuntimeSessionConfig): ChatRuntimeResetResult =
    resetSession(config = config, tools = emptyList())

  suspend fun resetSession(
    config: ChatRuntimeSessionConfig,
    tools: List<ToolProvider>,
    enableConversationConstrainedDecoding: Boolean = false,
    systemInstructionOverride: Contents? = null,
  ): ChatRuntimeResetResult = lifecycleMutex.withLock {
    try {
      check(!closed.get()) { "Runtime executor is closed" }
      model.awaitInitialization()
      check(model.instance != null) { "Model ${model.displayName} is not initialized" }
      activeExecution.get()?.let(::interrupt)

      val systemInstruction =
        systemInstructionOverride ?: config.systemInstruction?.let { Contents.of(it) }
      when (model.runtimeType) {
        RuntimeType.LITERT_LM ->
          model.runtimeHelper.resetConversation(
            model = model,
            supportImage = config.capabilities.image,
            supportAudio = config.capabilities.audio,
            systemInstruction = systemInstruction,
            tools = tools,
            enableConversationConstrainedDecoding = enableConversationConstrainedDecoding,
            initialMessages =
              config.history.mapNotNull { message ->
                when (message.role) {
                  ChatRuntimeMessageRole.USER -> Message.user(message.text)
                  ChatRuntimeMessageRole.ASSISTANT -> Message.model(message.text)
                  ChatRuntimeMessageRole.SYSTEM -> null
                }
              },
          )
        RuntimeType.AICORE -> {
          model.runtimeHelper.resetConversation(
            model = model,
            supportImage = config.capabilities.image,
            supportAudio = config.capabilities.audio,
            systemInstruction = systemInstruction,
            tools = tools,
            enableConversationConstrainedDecoding = enableConversationConstrainedDecoding,
          )
          val instance = model.instance as? AICoreModelInstance
            ?: error("AICore model instance is not initialized")
          instance.chatHistory +=
            config.history.mapNotNull { message ->
              when (message.role) {
                ChatRuntimeMessageRole.USER ->
                  AICoreChatMessage(isUser = true, text = message.text)
                ChatRuntimeMessageRole.ASSISTANT ->
                  AICoreChatMessage(isUser = false, text = message.text)
                ChatRuntimeMessageRole.SYSTEM -> null
              }
            }
        }
        RuntimeType.UNKNOWN -> error("Unknown runtime type for model ${model.name}")
      }
      ChatRuntimeResetResult(succeeded = true)
    } catch (error: Throwable) {
      if (error is CancellationException) throw error
      ChatRuntimeResetResult(
        succeeded = false,
        message = error.message ?: "Failed to reset chat runtime",
      )
    }
  }

  override fun close() {
    if (!closed.compareAndSet(false, true)) return
    activeExecution.get()?.let(::interrupt)
    activeExecution.set(null)
  }

  private fun ChatRuntimeAttachment.decodeBitmap(): Bitmap =
    BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
      ?: error("Could not decode image attachment with mime type $mimeType")
}

fun Model.toChatRuntimeDescriptor(): ChatRuntimeDescriptor {
  val providerKind =
    when (runtimeType) {
      RuntimeType.LITERT_LM -> ChatRuntimeProviderKind.LOCAL_MODEL
      RuntimeType.AICORE -> ChatRuntimeProviderKind.DEVICE_AI
      RuntimeType.UNKNOWN -> ChatRuntimeProviderKind.LOCAL_MODEL
    }
  val available = runtimeType != RuntimeType.UNKNOWN
  return ChatRuntimeDescriptor(
    id = "${providerKind.name.lowercase()}:$name",
    providerId = providerKind.name.lowercase(),
    displayName = displayName.ifBlank { name },
    modelId = name,
    providerKind = providerKind,
    availability =
      if (available) ChatRuntimeAvailability.READY else ChatRuntimeAvailability.UNSUPPORTED,
    capabilities =
      ChatRuntimeCapabilities(
        image = llmSupportImage,
        audio = llmSupportAudio,
        thinking = llmSupportThinking,
        tools = true,
      ),
    unavailableReason = if (available) null else "Model $name has no declared runtime",
  )
}
