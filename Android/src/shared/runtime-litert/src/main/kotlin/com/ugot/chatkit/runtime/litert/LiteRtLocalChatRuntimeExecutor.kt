/*
 * Copyright 2026 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     https://www.apache.org/licenses/LICENSE-2.0
 */

package com.ugot.chatkit.runtime.litert

import com.google.ai.edge.litertlm.Backend
import com.google.ai.edge.litertlm.Content
import com.google.ai.edge.litertlm.Contents
import com.google.ai.edge.litertlm.Conversation
import com.google.ai.edge.litertlm.ConversationConfig
import com.google.ai.edge.litertlm.Engine
import com.google.ai.edge.litertlm.EngineConfig
import com.google.ai.edge.litertlm.Message
import com.google.ai.edge.litertlm.MessageCallback
import com.google.ai.edge.litertlm.SamplerConfig
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
import java.io.File
import java.util.concurrent.CancellationException
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlin.coroutines.resume
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

enum class LiteRtLocalBackend {
  CPU,
  GPU,
}

data class LiteRtLocalModelConfig(
  val id: String,
  val displayName: String,
  val modelPath: String,
  val backend: LiteRtLocalBackend,
  val maxTokens: Int = 1024,
  val topK: Int = 40,
  val topP: Double = 0.95,
  val temperature: Double = 0.8,
) {
  init {
    require(id.isNotBlank()) { "Local model id is required" }
    require(displayName.isNotBlank()) { "Local model display name is required" }
    require(modelPath.isNotBlank()) { "Local model path is required" }
    require(maxTokens > 0) { "maxTokens must be positive" }
    require(topK > 0) { "topK must be positive" }
    require(topP in 0.0..1.0) { "topP must be between 0 and 1" }
    require(temperature >= 0.0) { "temperature must be non-negative" }
  }
}

/** File-backed LiteRT-LM adapter shared by Android hosts. It never downloads or bundles weights. */
class LiteRtLocalChatRuntimeExecutor(
  private val config: LiteRtLocalModelConfig,
) : ChatRuntimeExecutor {
  private val lifecycleMutex = Mutex()
  private val activeExecution = AtomicReference<ChatRuntimeExecutionKey?>(null)
  private val interruptedExecution = AtomicReference<ChatRuntimeExecutionKey?>(null)
  private val closed = AtomicBoolean(false)
  private var engine: Engine? = null
  private var conversation: Conversation? = null

  override val descriptor: ChatRuntimeDescriptor = config.toDescriptor()

  override val activeExecutionKey: ChatRuntimeExecutionKey?
    get() = activeExecution.get()

  override suspend fun execute(
    request: ChatRuntimeRequest,
    listener: ChatRuntimeEventListener,
  ) = lifecycleMutex.withLock {
    check(!closed.get()) { "Runtime executor is closed" }
    require(request.modelId == config.id) {
      "Runtime ${config.id} cannot execute model ${request.modelId}"
    }
    val executionKey = ChatRuntimeExecutionKey(request.sessionId, request.turnId)
    if (descriptor.availability != ChatRuntimeAvailability.READY) {
      listener.onEvent(
        ChatRuntimeEvent(
          executionKey = executionKey,
          type = ChatRuntimeEventType.FAILED,
          text = descriptor.unavailableReason.orEmpty(),
        )
      )
      return@withLock
    }
    if (request.attachments.isNotEmpty()) {
      listener.onEvent(
        ChatRuntimeEvent(
          executionKey = executionKey,
          type = ChatRuntimeEventType.FAILED,
          text = "This local runtime accepts text only",
        )
      )
      return@withLock
    }

    activeExecution.set(executionKey)
    listener.onEvent(ChatRuntimeEvent(executionKey, ChatRuntimeEventType.PREPARING))
    try {
      val activeConversation = ensureConversation()
      val finished = AtomicBoolean(false)
      suspendCancellableCoroutine { continuation ->
        fun finish(type: ChatRuntimeEventType, text: String = "") {
          if (!finished.compareAndSet(false, true)) return
          listener.onEvent(ChatRuntimeEvent(executionKey, type, text))
          if (continuation.isActive) continuation.resume(Unit)
        }

        continuation.invokeOnCancellation {
          interruptedExecution.set(executionKey)
          activeConversation.cancelProcess()
        }
        activeConversation.sendMessageAsync(
          Contents.of(Content.Text(request.input)),
          object : MessageCallback {
            override fun onMessage(message: Message) {
              val thought = message.channels["thought"].orEmpty()
              if (request.allowThinking && thought.isNotEmpty()) {
                listener.onEvent(
                  ChatRuntimeEvent(executionKey, ChatRuntimeEventType.THINKING_DELTA, thought)
                )
              }
              val text = message.toString()
              if (text.isNotEmpty() && !text.startsWith("<ctrl")) {
                listener.onEvent(
                  ChatRuntimeEvent(executionKey, ChatRuntimeEventType.TEXT_DELTA, text)
                )
              }
            }

            override fun onDone() {
              finish(
                if (interruptedExecution.get() == executionKey) {
                  ChatRuntimeEventType.INTERRUPTED
                } else {
                  ChatRuntimeEventType.COMPLETED
                }
              )
            }

            override fun onError(throwable: Throwable) {
              if (throwable is CancellationException) {
                finish(ChatRuntimeEventType.INTERRUPTED)
              } else {
                finish(
                  ChatRuntimeEventType.FAILED,
                  throwable.message ?: "Local model inference failed",
                )
              }
            }
          },
          request.context,
        )
      }
    } catch (error: Throwable) {
      if (error is kotlinx.coroutines.CancellationException) throw error
      listener.onEvent(
        ChatRuntimeEvent(
          executionKey,
          ChatRuntimeEventType.FAILED,
          error.message ?: "Local model inference failed",
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
    conversation?.cancelProcess()
    return true
  }

  override suspend fun resetSession(config: ChatRuntimeSessionConfig): ChatRuntimeResetResult =
    lifecycleMutex.withLock {
      try {
        check(!closed.get()) { "Runtime executor is closed" }
        conversation?.close()
        conversation = createConversation(checkNotNull(engine ?: createEngine()), config)
        ChatRuntimeResetResult(succeeded = true)
      } catch (error: Throwable) {
        ChatRuntimeResetResult(
          succeeded = false,
          message = error.message ?: "Failed to reset local model session",
        )
      }
    }

  override fun close() {
    if (!closed.compareAndSet(false, true)) return
    conversation?.close()
    conversation = null
    engine?.close()
    engine = null
  }

  private fun ensureConversation(): Conversation {
    conversation?.let { return it }
    val initializedEngine = engine ?: createEngine().also { engine = it }
    return createConversation(initializedEngine, ChatRuntimeSessionConfig(sessionId = config.id, taskId = "chat"))
      .also { conversation = it }
  }

  private fun createEngine(): Engine =
    Engine(
        EngineConfig(
          modelPath = config.modelPath,
          backend =
            when (config.backend) {
              LiteRtLocalBackend.CPU -> Backend.CPU()
              LiteRtLocalBackend.GPU -> Backend.GPU()
            },
          maxNumTokens = config.maxTokens,
        )
      )
      .also(Engine::initialize)

  private fun createConversation(
    engine: Engine,
    sessionConfig: ChatRuntimeSessionConfig,
  ): Conversation =
    engine.createConversation(
      ConversationConfig(
        samplerConfig =
          SamplerConfig(
            topK = config.topK,
            topP = config.topP,
            temperature = config.temperature,
          ),
        initialMessages =
          sessionConfig.history.map { message ->
            when (message.role) {
              ChatRuntimeMessageRole.USER -> Message.user(message.text)
              ChatRuntimeMessageRole.ASSISTANT -> Message.model(message.text)
              ChatRuntimeMessageRole.SYSTEM -> Message.system(message.text)
            }
          },
      )
    )
}

fun LiteRtLocalModelConfig.toDescriptor(): ChatRuntimeDescriptor {
  val modelFile = File(modelPath)
  val availability =
    if (modelFile.isFile && modelFile.canRead()) {
      ChatRuntimeAvailability.READY
    } else {
      ChatRuntimeAvailability.REQUIRES_DOWNLOAD
    }
  return ChatRuntimeDescriptor(
    id = "litert-local:$id",
    providerId = "litert-local",
    displayName = displayName,
    modelId = id,
    providerKind = ChatRuntimeProviderKind.LOCAL_MODEL,
    availability = availability,
    unavailableReason =
      if (availability == ChatRuntimeAvailability.READY) null else "Select a readable local model file",
    capabilities = ChatRuntimeCapabilities(),
  )
}
