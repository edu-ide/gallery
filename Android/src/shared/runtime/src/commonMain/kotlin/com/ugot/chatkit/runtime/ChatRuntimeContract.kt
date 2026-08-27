/*
 * Copyright 2026 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     https://www.apache.org/licenses/LICENSE-2.0
 */

package com.ugot.chatkit.runtime

/** The execution owner selected by the user. Selection is explicit and never falls through. */
enum class ChatRuntimeProviderKind {
  LOCAL_MODEL,
  DEVICE_AI,
  UGOT_SERVER,
}

enum class ChatRuntimeAvailability {
  READY,
  REQUIRES_DOWNLOAD,
  UNSUPPORTED,
  UNAVAILABLE,
}

data class ChatRuntimeCapabilities(
  val text: Boolean = true,
  val image: Boolean = false,
  val audio: Boolean = false,
  val thinking: Boolean = false,
  val tools: Boolean = false,
)

data class ChatRuntimeDescriptor(
  val id: String,
  val providerId: String,
  val displayName: String,
  val modelId: String,
  val providerKind: ChatRuntimeProviderKind,
  val availability: ChatRuntimeAvailability,
  val capabilities: ChatRuntimeCapabilities = ChatRuntimeCapabilities(),
  val unavailableReason: String? = null,
) {
  init {
    require(id.isNotBlank()) { "Runtime id must not be blank" }
    require(providerId.isNotBlank()) { "Provider id must not be blank" }
    require(displayName.isNotBlank()) { "Runtime display name must not be blank" }
    require(modelId.isNotBlank()) { "Runtime model id must not be blank" }
    require(availability == ChatRuntimeAvailability.READY || !unavailableReason.isNullOrBlank()) {
      "A non-ready runtime must explain why it cannot run"
    }
  }
}

enum class ChatRuntimeAttachmentKind {
  IMAGE,
  AUDIO,
}

data class ChatRuntimeAttachment(
  val kind: ChatRuntimeAttachmentKind,
  val mimeType: String,
  val bytes: ByteArray,
) {
  init {
    require(mimeType.isNotBlank()) { "Attachment mime type must not be blank" }
    require(bytes.isNotEmpty()) { "Attachment bytes must not be empty" }
  }
}

enum class ChatRuntimeMessageRole {
  USER,
  ASSISTANT,
  SYSTEM,
}

data class ChatRuntimeMessage(
  val role: ChatRuntimeMessageRole,
  val text: String,
)

data class ChatRuntimeSessionConfig(
  val sessionId: String,
  val taskId: String,
  val systemInstruction: String? = null,
  val history: List<ChatRuntimeMessage> = emptyList(),
  val capabilities: ChatRuntimeCapabilities = ChatRuntimeCapabilities(),
) {
  init {
    require(sessionId.isNotBlank()) { "Session id must not be blank" }
    require(taskId.isNotBlank()) { "Task id must not be blank" }
  }
}

data class ChatRuntimeRequest(
  val sessionId: String,
  val turnId: String,
  val modelId: String,
  val input: String,
  val attachments: List<ChatRuntimeAttachment> = emptyList(),
  val allowThinking: Boolean = false,
  val context: Map<String, String> = emptyMap(),
) {
  init {
    require(sessionId.isNotBlank()) { "Session id must not be blank" }
    require(turnId.isNotBlank()) { "Turn id must not be blank" }
    require(modelId.isNotBlank()) { "Model id must not be blank" }
    require(input.isNotBlank() || attachments.isNotEmpty()) {
      "A runtime request needs text or an attachment"
    }
  }
}

enum class ChatRuntimeEventType {
  PREPARING,
  TEXT_DELTA,
  THINKING_DELTA,
  COMPLETED,
  FAILED,
  INTERRUPTED,
}

data class ChatRuntimeEvent(
  val executionKey: ChatRuntimeExecutionKey,
  val type: ChatRuntimeEventType,
  val text: String = "",
)

fun interface ChatRuntimeEventListener {
  fun onEvent(event: ChatRuntimeEvent)
}

/**
 * Provider-neutral model execution contract shared by the standalone app and embedding hosts.
 *
 * Implementations must be thread-safe: execute, interrupt, resetSession and close may be invoked
 * from different threads. A host must select an executor by its exact [ChatRuntimeDescriptor.id].
 */
interface ChatRuntimeExecutor {
  val descriptor: ChatRuntimeDescriptor
  val activeExecutionKey: ChatRuntimeExecutionKey?

  suspend fun execute(request: ChatRuntimeRequest, listener: ChatRuntimeEventListener)

  fun interrupt(key: ChatRuntimeExecutionKey): Boolean

  suspend fun resetSession(config: ChatRuntimeSessionConfig): ChatRuntimeResetResult

  fun close()
}

/**
 * Provider-neutral placeholder for a runtime which is visible in the shared model picker but
 * cannot execute yet. Hosts use this for setup-required and unsupported providers instead of
 * declaring parallel no-op executors.
 */
class UnavailableChatRuntimeExecutor(
  override val descriptor: ChatRuntimeDescriptor,
) : ChatRuntimeExecutor {
  init {
    require(descriptor.availability != ChatRuntimeAvailability.READY) {
      "A ready runtime requires a real executor"
    }
  }

  override val activeExecutionKey: ChatRuntimeExecutionKey? = null

  override suspend fun execute(
    request: ChatRuntimeRequest,
    listener: ChatRuntimeEventListener,
  ) {
    listener.onEvent(
      ChatRuntimeEvent(
        executionKey = ChatRuntimeExecutionKey(request.sessionId, request.turnId),
        type = ChatRuntimeEventType.FAILED,
        text = requireNotNull(descriptor.unavailableReason),
      )
    )
  }

  override fun interrupt(key: ChatRuntimeExecutionKey): Boolean = false

  override suspend fun resetSession(config: ChatRuntimeSessionConfig): ChatRuntimeResetResult =
    ChatRuntimeResetResult(
      succeeded = false,
      message = requireNotNull(descriptor.unavailableReason),
    )

  override fun close() = Unit
}

data class ChatRuntimeExecutionKey(
  val sessionId: String,
  val turnId: String,
) {
  init {
    require(sessionId.isNotBlank()) { "Execution session id must not be blank" }
    require(turnId.isNotBlank()) { "Execution turn id must not be blank" }
  }
}

data class ChatRuntimeResetResult(
  val succeeded: Boolean,
  val message: String = "",
)

enum class ChatRuntimeRejectionReason {
  UNKNOWN_RUNTIME,
  REQUIRES_DOWNLOAD,
  UNSUPPORTED,
  UNAVAILABLE,
}

data class ChatRuntimeSelection(
  val executor: ChatRuntimeExecutor? = null,
  val requestedRuntimeId: String,
  val rejectionReason: ChatRuntimeRejectionReason? = null,
  val message: String = "",
) {
  val isSelected: Boolean
    get() = executor != null
}

/** Registry with deliberate no-fallback semantics. */
class ExplicitChatRuntimeRegistry(executors: List<ChatRuntimeExecutor>) {
  private val executorsById = executors.associateBy { it.descriptor.id }

  init {
    require(executorsById.size == executors.size) { "Runtime ids must be unique" }
  }

  fun descriptors(): List<ChatRuntimeDescriptor> =
    executorsById.values.map(ChatRuntimeExecutor::descriptor)

  fun select(runtimeId: String): ChatRuntimeSelection {
    val executor = executorsById[runtimeId]
      ?: return ChatRuntimeSelection(
        requestedRuntimeId = runtimeId,
        rejectionReason = ChatRuntimeRejectionReason.UNKNOWN_RUNTIME,
        message = "Unknown chat runtime: $runtimeId",
      )
    val descriptor = executor.descriptor
    if (descriptor.availability == ChatRuntimeAvailability.READY) {
      return ChatRuntimeSelection(executor = executor, requestedRuntimeId = runtimeId)
    }
    val reason =
      when (descriptor.availability) {
        ChatRuntimeAvailability.READY -> error("Handled above")
        ChatRuntimeAvailability.REQUIRES_DOWNLOAD -> ChatRuntimeRejectionReason.REQUIRES_DOWNLOAD
        ChatRuntimeAvailability.UNSUPPORTED -> ChatRuntimeRejectionReason.UNSUPPORTED
        ChatRuntimeAvailability.UNAVAILABLE -> ChatRuntimeRejectionReason.UNAVAILABLE
      }
    return ChatRuntimeSelection(
      requestedRuntimeId = runtimeId,
      rejectionReason = reason,
      message = requireNotNull(descriptor.unavailableReason),
    )
  }
}
