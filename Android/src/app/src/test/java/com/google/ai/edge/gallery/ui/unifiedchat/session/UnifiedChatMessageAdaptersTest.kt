package com.google.ai.edge.gallery.ui.unifiedchat.session

import com.google.ai.edge.gallery.ui.common.chat.ChatMessageError
import com.google.ai.edge.gallery.ui.common.chat.ChatMessageInfo
import com.google.ai.edge.gallery.ui.common.chat.ChatMessageText
import com.google.ai.edge.gallery.ui.common.chat.ChatMessageThinking
import com.google.ai.edge.gallery.ui.common.chat.ChatSide
import com.google.ai.edge.gallery.ui.unifiedchat.UnifiedChatMessage
import com.google.ai.edge.gallery.ui.unifiedchat.UnifiedChatMessageRole
import com.google.ai.edge.gallery.ui.unifiedchat.mcp.McpWidgetSnapshot
import com.google.ai.edge.gallery.ui.unifiedchat.messages.ChatMessageMcpWidgetCard
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class UnifiedChatMessageAdaptersTest {
  @Test
  fun toUnifiedChatMessages_mapsSupportedAndroidMessages() {
    val snapshot = McpWidgetSnapshot("github", "GitHub PR", "Summary", "{}")
    val messages =
      listOf(
        ChatMessageText(content = "hello", side = ChatSide.USER),
        ChatMessageText(content = "hi", side = ChatSide.AGENT),
        ChatMessageInfo(content = "system info"),
        ChatMessageThinking(content = "thinking", inProgress = true),
        ChatMessageError(content = "error"),
        ChatMessageMcpWidgetCard(
          connectorId = snapshot.connectorId,
          title = snapshot.title,
          summary = snapshot.summary,
          snapshot = snapshot,
        ),
      )

    val unified = messages.toUnifiedChatMessages(idPrefix = "t")

    assertEquals(
      listOf(
        UnifiedChatMessage("t0", UnifiedChatMessageRole.USER, "hello"),
        UnifiedChatMessage("t1", UnifiedChatMessageRole.ASSISTANT, "hi"),
        UnifiedChatMessage("t2", UnifiedChatMessageRole.SYSTEM, "system info"),
        UnifiedChatMessage("t3", UnifiedChatMessageRole.ASSISTANT, "thinking"),
        UnifiedChatMessage("t4", UnifiedChatMessageRole.SYSTEM, "error"),
        UnifiedChatMessage("t5", UnifiedChatMessageRole.ASSISTANT, "GitHub PR"),
      ),
      unified,
    )
  }

  @Test
  fun toAndroidChatMessages_mapsSharedMessagesBackToDisplayMessages() {
    val androidMessages =
      listOf(
          UnifiedChatMessage("m0", UnifiedChatMessageRole.USER, "hello"),
          UnifiedChatMessage("m1", UnifiedChatMessageRole.ASSISTANT, "hi"),
          UnifiedChatMessage("m2", UnifiedChatMessageRole.SYSTEM, "system"),
        )
        .toAndroidChatMessages()

    assertTrue(androidMessages[0] is ChatMessageText)
    assertEquals(ChatSide.USER, androidMessages[0].side)
    assertEquals("hello", (androidMessages[0] as ChatMessageText).content)
    assertEquals(ChatSide.AGENT, androidMessages[1].side)
    assertEquals("hi", (androidMessages[1] as ChatMessageText).content)
    assertTrue(androidMessages[2] is ChatMessageInfo)
  }

  @Test
  fun deriveConversationTitleFromUnifiedMessages_prefersFirstUserText() {
    val title =
      deriveConversationTitleFromUnifiedMessages(
        listOf(
          UnifiedChatMessage("m0", UnifiedChatMessageRole.ASSISTANT, "assistant intro"),
          UnifiedChatMessage("m1", UnifiedChatMessageRole.USER, "first user line\nsecond line"),
        )
      )

    assertEquals("first user line", title)
  }
}
