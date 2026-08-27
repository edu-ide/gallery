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

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ChatRuntimeContractTest {
  @Test
  fun registrySelectsOnlyTheExplicitReadyRuntime() {
    val local = RecordingExecutor(descriptor("local", ChatRuntimeAvailability.READY))
    val device =
      RecordingExecutor(
        descriptor(
          id = "device",
          availability = ChatRuntimeAvailability.UNSUPPORTED,
          reason = "Device AI is not supported on this device",
        )
      )
    val registry = ExplicitChatRuntimeRegistry(listOf(local, device))

    assertEquals(local, registry.select("local").executor)
    val rejected = registry.select("device")
    assertNull(rejected.executor)
    assertEquals(ChatRuntimeRejectionReason.UNSUPPORTED, rejected.rejectionReason)
    assertEquals("Device AI is not supported on this device", rejected.message)
    assertEquals(
      ChatRuntimeRejectionReason.UNKNOWN_RUNTIME,
      registry.select("server").rejectionReason,
    )
  }

  @Test
  fun duplicateRuntimeIdsFailLoudly() {
    assertFailsWith<IllegalArgumentException> {
      ExplicitChatRuntimeRegistry(
        listOf(
          RecordingExecutor(descriptor("local", ChatRuntimeAvailability.READY)),
          RecordingExecutor(descriptor("local", ChatRuntimeAvailability.READY)),
        )
      )
    }
  }

  @Test
  fun nonReadyRuntimeRequiresAVisibleReason() {
    assertFailsWith<IllegalArgumentException> {
      descriptor("device", ChatRuntimeAvailability.UNAVAILABLE)
    }
  }

  @Test
  fun unavailableExecutorRejectsReadyDescriptors() {
    assertFailsWith<IllegalArgumentException> {
      UnavailableChatRuntimeExecutor(descriptor("local", ChatRuntimeAvailability.READY))
    }
    val unavailable =
      UnavailableChatRuntimeExecutor(
        descriptor(
          "device",
          ChatRuntimeAvailability.UNAVAILABLE,
          "Device AI is unavailable",
        )
      )
    assertTrue(unavailable.activeExecutionKey == null)
  }

  private fun descriptor(
    id: String,
    availability: ChatRuntimeAvailability,
    reason: String? = null,
  ): ChatRuntimeDescriptor =
    ChatRuntimeDescriptor(
      id = id,
      providerId = "test-provider",
      displayName = id,
      modelId = "$id-model",
      providerKind = ChatRuntimeProviderKind.LOCAL_MODEL,
      availability = availability,
      unavailableReason = reason,
    )

  private class RecordingExecutor(
    override val descriptor: ChatRuntimeDescriptor,
  ) : ChatRuntimeExecutor {
    override val activeExecutionKey: ChatRuntimeExecutionKey? = null

    override suspend fun execute(
      request: ChatRuntimeRequest,
      listener: ChatRuntimeEventListener,
    ) = Unit

    override fun interrupt(key: ChatRuntimeExecutionKey): Boolean = false

    override suspend fun resetSession(config: ChatRuntimeSessionConfig): ChatRuntimeResetResult =
      ChatRuntimeResetResult(succeeded = true)

    override fun close() = Unit
  }
}
