package com.google.ai.edge.gallery.customtasks.sajug

import com.google.ai.edge.gallery.ui.common.chat.ChatMessageText
import com.google.ai.edge.gallery.ui.common.chat.ChatSide
import com.google.ai.edge.gallery.ui.unifiedchat.mcp.McpWidgetSnapshot
import com.google.ai.edge.gallery.ui.unifiedchat.messages.ChatMessageMcpWidgetCard
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SajugTaskScreenPolicyTest {
  @Test
  fun shouldClearBootstrapOnlyFortuneTranscript_returnsTrueForLegacyAutoSeededCard() {
    val widgetSnapshot =
      McpWidgetSnapshot(
        connectorId = "ugot_fortune",
        title = "UGOT Fortune",
        summary = "Hosted Fortune MCP widget connected in the shared chat shell.",
        widgetStateJson = "{}",
      )

    val messages =
      listOf(
        ChatMessageMcpWidgetCard(
          connectorId = widgetSnapshot.connectorId,
          title = widgetSnapshot.title,
          summary = widgetSnapshot.summary,
          snapshot = widgetSnapshot,
          side = ChatSide.AGENT,
        )
      )

    assertTrue(shouldClearBootstrapOnlyFortuneTranscript(messages))
  }

  @Test
  fun shouldClearBootstrapOnlyFortuneTranscript_returnsFalseOnceConversationExists() {
    val widgetSnapshot =
      McpWidgetSnapshot(
        connectorId = "ugot_fortune",
        title = "UGOT Fortune",
        summary = "Hosted Fortune MCP widget connected in the shared chat shell.",
        widgetStateJson = "{}",
      )

    val messages =
      listOf(
        ChatMessageText(content = "오늘 운세 알려줘", side = ChatSide.USER),
        ChatMessageMcpWidgetCard(
          connectorId = widgetSnapshot.connectorId,
          title = widgetSnapshot.title,
          summary = widgetSnapshot.summary,
          snapshot = widgetSnapshot,
          side = ChatSide.AGENT,
        ),
      )

    assertFalse(shouldClearBootstrapOnlyFortuneTranscript(messages))
  }
}
