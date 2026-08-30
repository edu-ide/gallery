/*
 * Copyright 2026 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     https://www.apache.org/licenses/LICENSE-2.0
 */

package com.ugot.chatkit.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ChatUiContractTest {
  @Test
  fun composerAllowsTextOrAttachmentButNotBlankInput() {
    assertFalse(ChatComposerUiState(draft = "   ").canSend())
    assertTrue(ChatComposerUiState(draft = "hello").canSend())
    assertTrue(
      ChatComposerUiState(
          attachments =
            listOf(
              ChatAttachmentUi(
                id = "image-1",
                type = ChatAttachmentType.IMAGE,
                displayName = "image.png",
                contentRef = "content://image/1",
              )
            )
        )
        .canSend()
    )
  }

  @Test
  fun composerCannotSendWhileRuntimeIsBusy() {
    assertFalse(ChatComposerUiState(draft = "hello", inProgress = true).canSend())
    assertFalse(ChatComposerUiState(draft = "hello", enabled = false).canSend())
  }

  @Test
  fun textBlocksEnableMarkdownUnlessTheProducerExplicitlyOptsOut() {
    assertTrue(ChatBlockUi.Text("**bold**").markdown)
    assertFalse(ChatBlockUi.Text("literal * text", markdown = false).markdown)
  }

  @Test
  fun streamingTextDefersMarkdownUntilTheMessageCompletes() {
    assertFalse(shouldRenderMarkdown(markdown = true, messageInProgress = true))
    assertTrue(shouldRenderMarkdown(markdown = true, messageInProgress = false))
    assertFalse(shouldRenderMarkdown(markdown = false, messageInProgress = false))
  }

  @Test
  fun tokenDeltaDoesNotRestartTranscriptAutoScroll() {
    val streaming =
      ChatMessageUi(
        id = "assistant-1",
        role = ChatRole.ASSISTANT,
        blocks = listOf(ChatBlockUi.Text("one")),
        inProgress = true,
      )
    val nextDelta = streaming.copy(blocks = listOf(ChatBlockUi.Text("one two")))

    assertEquals(transcriptAutoScrollKey(listOf(streaming)), transcriptAutoScrollKey(listOf(nextDelta)))
    assertFalse(
      transcriptAutoScrollKey(listOf(streaming)) ==
        transcriptAutoScrollKey(listOf(nextDelta.copy(inProgress = false)))
    )
  }

  @Test
  fun messageBlockRunsPreserveToolAndChatOrder() {
    val toolA =
      ChatBlockUi.Widget(
        ChatWidgetUiState(messageId = "message-1", title = "Tool A", summary = "first tool")
      )
    val toolB =
      ChatBlockUi.Widget(
        ChatWidgetUiState(messageId = "message-1", title = "Tool B", summary = "second tool")
      )
    val before = ChatBlockUi.Text("before")
    val after = ChatBlockUi.Text("after")
    val input = listOf(before, toolA, after, toolB)

    val runs = orderedVisibleChatBlockRuns(input, ChatUiCapabilities())

    assertEquals(listOf(false, true, false, true), runs.map(ChatBlockRenderRun::isWidget))
    assertEquals(input, runs.flatMap(ChatBlockRenderRun::blocks))
  }

  @Test
  fun messageBlockRunsKeepWidgetsSeparateAndFilterOnlyInvisibleBlocks() {
    val toolA =
      ChatBlockUi.Widget(ChatWidgetUiState(messageId = "message-1", title = "A", summary = "A"))
    val toolB =
      ChatBlockUi.Widget(ChatWidgetUiState(messageId = "message-1", title = "B", summary = "B"))
    val visibleNotice = ChatBlockUi.Notice(ChatNoticeLevel.INFO, "visible")
    val runs =
      orderedVisibleChatBlockRuns(
        blocks =
          listOf(
            ChatBlockUi.Text(" "),
            ChatBlockUi.Thinking("hidden", inProgress = false),
            toolA,
            toolB,
            visibleNotice,
            ChatBlockUi.Text("answer"),
          ),
        capabilities = ChatUiCapabilities(showThinking = false),
      )

    assertEquals(listOf(true, true, false), runs.map(ChatBlockRenderRun::isWidget))
    assertEquals(listOf(toolA, toolB, visibleNotice, ChatBlockUi.Text("answer")), runs.flatMap { it.blocks })
  }
}
