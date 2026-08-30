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
import com.ugot.chatkit.runtime.ChatRuntimeWidget
import com.ugot.chatkit.ui.ChatBlockUi
import com.ugot.chatkit.ui.ChatConnectorUi
import com.ugot.chatkit.ui.ChatMessageUi
import com.ugot.chatkit.ui.ChatRole
import com.ugot.chatkit.ui.ChatUiIntent
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class DefaultChatControllerTest {
  @Test
  fun lateEventsFromStoppedTurnDoNotChangeNewTurn() = runTest {
    val executor = FakeExecutor()
    val controller = controller(executor)

    controller.onIntent(ChatUiIntent.DraftChanged("first"))
    controller.onIntent(ChatUiIntent.SendClicked)
    runCurrent()
    val oldListener = executor.listeners.single()
    val oldKey = executor.requests.single().executionKey()
    oldListener.onEvent(ChatRuntimeEvent(oldKey, ChatRuntimeEventType.TEXT_DELTA, "buffered"))

    controller.onIntent(ChatUiIntent.StopClicked)
    controller.onIntent(ChatUiIntent.DraftChanged("second"))
    controller.onIntent(ChatUiIntent.SendClicked)
    runCurrent()

    oldListener.onEvent(ChatRuntimeEvent(oldKey, ChatRuntimeEventType.TEXT_DELTA, "stale"))
    runCurrent()

    val renderedText =
      controller.state.value.messages
        .flatMap(ChatMessageUi::blocks)
        .filterIsInstance<ChatBlockUi.Text>()
        .joinToString(separator = "") { it.value }
    assertFalse(renderedText.contains("buffered"))
    assertFalse(renderedText.contains("stale"))
    assertTrue(controller.state.value.composer.inProgress)
  }

  @Test
  fun streamingDeltasArePublishedAsOneFrameCoalescedBatch() = runTest {
    val executor = FakeExecutor()
    val controller = controller(executor)
    controller.onIntent(ChatUiIntent.DraftChanged("prompt"))
    controller.onIntent(ChatUiIntent.SendClicked)
    runCurrent()
    val listener = executor.listeners.single()
    val key = executor.requests.single().executionKey()

    repeat(100) { listener.onEvent(ChatRuntimeEvent(key, ChatRuntimeEventType.TEXT_DELTA, "x")) }
    runCurrent()
    assertEquals(1, controller.state.value.messages.size)

    advanceTimeBy(31)
    runCurrent()
    assertEquals(1, controller.state.value.messages.size)

    advanceTimeBy(1)
    runCurrent()
    val assistant = controller.state.value.messages.last()
    assertEquals(100, assistant.blocks.filterIsInstance<ChatBlockUi.Text>().single().value.length)
    assertTrue(assistant.inProgress)
  }

  @Test
  fun completionFlushesPendingDeltaBeforeFinishingTheTurn() = runTest {
    val executor = FakeExecutor()
    val controller = controller(executor)
    controller.onIntent(ChatUiIntent.DraftChanged("prompt"))
    controller.onIntent(ChatUiIntent.SendClicked)
    runCurrent()
    val listener = executor.listeners.single()
    val key = executor.requests.single().executionKey()

    listener.onEvent(ChatRuntimeEvent(key, ChatRuntimeEventType.TEXT_DELTA, "final"))
    listener.onEvent(ChatRuntimeEvent(key, ChatRuntimeEventType.COMPLETED))
    runCurrent()

    val assistant = controller.state.value.messages.last()
    assertEquals("final", assistant.blocks.filterIsInstance<ChatBlockUi.Text>().single().value)
    assertFalse(assistant.inProgress)
    assertFalse(controller.state.value.composer.inProgress)
  }

  @Test
  fun resetFailurePreservesTranscript() = runTest {
    val executor = FakeExecutor(resetResult = ChatRuntimeResetResult(false, "reset failed"))
    val controller = controller(executor)
    controller.restore(
      listOf(
        ChatMessageUi(
          id = "kept",
          role = ChatRole.USER,
          blocks = listOf(ChatBlockUi.Text("keep me")),
        )
      )
    )

    controller.onIntent(ChatUiIntent.ResetConversationClicked)
    runCurrent()

    assertEquals("kept", controller.state.value.messages.single().id)
    assertEquals("reset failed", controller.state.value.error)
    assertFalse(controller.state.value.restoring)
  }

  @Test
  fun unavailableRuntimeDoesNotReplaceSelectedRuntime() = runTest {
    val ready = FakeExecutor(id = "ready")
    val unavailable =
      FakeExecutor(
        id = "offline",
        availability = ChatRuntimeAvailability.UNAVAILABLE,
        unavailableReason = "offline",
      )
    val controller = controller(ready, unavailable)

    controller.onIntent(ChatUiIntent.ModelSelected("offline"))
    runCurrent()

    assertTrue(controller.state.value.models.single { it.id == "ready" }.selected)
    assertFalse(controller.state.value.models.single { it.id == "offline" }.selected)
    assertEquals("offline", controller.state.value.error)
  }

  @Test
  fun hostRestoringStatusDisablesComposerUntilReadyAgain() = runTest {
    val controller = controller(FakeExecutor())

    controller.updateHostStatus(restoring = true)
    assertTrue(controller.state.value.restoring)
    assertFalse(controller.state.value.composer.enabled)

    controller.updateHostStatus(restoring = false)
    assertFalse(controller.state.value.restoring)
    assertTrue(controller.state.value.composer.enabled)
  }

  @Test
  fun controllerLabelsOwnRuntimeStatusLocalization() = runTest {
    val ready = FakeExecutor(id = "ready")
    val unavailable =
      FakeExecutor(
        id = "offline",
        availability = ChatRuntimeAvailability.UNAVAILABLE,
        unavailableReason = "offline",
      )
    val controller =
      controllerWithLabels(
        ChatControllerLabels(ready = "사용 가능", unavailable = "사용 불가"),
        ready,
        unavailable,
      )

    assertEquals("사용 가능", controller.state.value.models.single { it.id == "ready" }.statusLabel)
    assertEquals("사용 불가", controller.state.value.models.single { it.id == "offline" }.statusLabel)
  }

  @Test
  fun activeConnectorIsSentToRuntimeAndWidgetEventBecomesSharedUiState() = runTest {
    val executor = FakeExecutor()
    val controller =
      DefaultChatController(
        scope = this,
        config =
          ChatControllerConfig(
            sessionId = "session",
            taskId = "task",
            title = "UGOT Chat",
            initialRuntimeId = executor.descriptor.id,
            connectors = listOf(ChatConnectorUi("fortune.ugot.uk/mcp", "Fortune", active = true)),
          ),
        executors = listOf(executor),
      ).also(openControllers::add)

    controller.onIntent(ChatUiIntent.DraftChanged("today"))
    controller.onIntent(ChatUiIntent.SendClicked)
    runCurrent()
    val request = executor.requests.single()
    val key = request.executionKey()
    assertEquals("fortune.ugot.uk/mcp", request.context["mcp.activeConnectorIds"])

    executor.listeners.single().onEvent(
      ChatRuntimeEvent(
        executionKey = key,
        type = ChatRuntimeEventType.WIDGET_AVAILABLE,
        widget =
          ChatRuntimeWidget(
            connectorId = "fortune.ugot.uk/mcp",
            contentRef = "ui://fortune/today",
            title = "Today",
            summary = "Result",
            stateJson = "{\"ready\":true}",
          ),
      )
    )
    runCurrent()

    val widget =
      controller.state.value.messages
        .flatMap(ChatMessageUi::blocks)
        .filterIsInstance<ChatBlockUi.Widget>()
        .single()
        .widget
    assertEquals("ui://fortune/today", widget.contentRef)
    assertEquals("fortune.ugot.uk/mcp", widget.connectorId)
  }

  private fun controller(vararg executors: ChatRuntimeExecutor): DefaultChatController =
    controllerWithLabels(ChatControllerLabels(), *executors)

  private fun controllerWithLabels(
    labels: ChatControllerLabels,
    vararg executors: ChatRuntimeExecutor,
  ): DefaultChatController =
    DefaultChatController(
      scope = thisScope,
      config =
        ChatControllerConfig(
          sessionId = "session",
          taskId = "task",
          title = "UGOT Chat",
          initialRuntimeId = executors.first().descriptor.id,
          labels = labels,
        ),
      executors = executors.toList(),
    ).also(openControllers::add)

  private lateinit var thisScope: kotlinx.coroutines.CoroutineScope
  private val openControllers = mutableListOf<DefaultChatController>()

  private fun runTest(block: suspend kotlinx.coroutines.test.TestScope.() -> Unit) =
    kotlinx.coroutines.test.runTest {
      thisScope = this
      try {
        block()
      } finally {
        openControllers.toList().forEach(DefaultChatController::close)
        openControllers.clear()
        runCurrent()
      }
    }
}

private class FakeExecutor(
  id: String = "ready",
  availability: ChatRuntimeAvailability = ChatRuntimeAvailability.READY,
  unavailableReason: String? = null,
  private val resetResult: ChatRuntimeResetResult = ChatRuntimeResetResult(true),
) : ChatRuntimeExecutor {
  override val descriptor =
    ChatRuntimeDescriptor(
      id = id,
      providerId = "fake",
      displayName = id,
      modelId = id,
      providerKind = ChatRuntimeProviderKind.LOCAL_MODEL,
      availability = availability,
      unavailableReason = unavailableReason,
    )
  override var activeExecutionKey: ChatRuntimeExecutionKey? = null
  val requests = mutableListOf<ChatRuntimeRequest>()
  val listeners = mutableListOf<ChatRuntimeEventListener>()

  override suspend fun execute(request: ChatRuntimeRequest, listener: ChatRuntimeEventListener) {
    activeExecutionKey = request.executionKey()
    requests += request
    listeners += listener
  }

  override fun interrupt(key: ChatRuntimeExecutionKey): Boolean {
    if (activeExecutionKey != key) return false
    activeExecutionKey = null
    return true
  }

  override suspend fun resetSession(config: ChatRuntimeSessionConfig): ChatRuntimeResetResult =
    resetResult

  override fun close() = Unit
}

private fun ChatRuntimeRequest.executionKey() = ChatRuntimeExecutionKey(sessionId, turnId)
