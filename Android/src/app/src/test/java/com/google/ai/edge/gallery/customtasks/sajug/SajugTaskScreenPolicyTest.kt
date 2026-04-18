package com.google.ai.edge.gallery.customtasks.sajug

import com.google.ai.edge.gallery.ui.common.chat.ChatMessageText
import com.google.ai.edge.gallery.ui.common.chat.ChatSide
import com.google.ai.edge.gallery.ui.unifiedchat.mcp.McpWidgetSnapshot
import com.google.ai.edge.gallery.ui.unifiedchat.messages.ChatMessageMcpWidgetCard
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
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

  @Test
  fun createFortuneToolCallMutation_appendsCardWhenTranscriptHasNoWidgetYet() {
    val mutation =
      createFortuneToolCallMutation(
        messages = listOf(ChatMessageText(content = "오늘 운세 알려줘", side = ChatSide.USER)),
        toolName = "show_today_fortune",
        widgetStateJson = """{"currentToolName":"show_today_fortune"}""",
      )

    assertNull(mutation.replaceIndex)
    assertEquals("UGOT Fortune", mutation.card.title)
    assertEquals("Updated after running show_today_fortune.", mutation.card.summary)
  }

  @Test
  fun createFortuneToolCallMutation_replacesExistingFortuneCard() {
    val existingSnapshot =
      McpWidgetSnapshot(
        connectorId = "ugot_fortune",
        title = "UGOT Fortune",
        summary = "Updated after running show_birth_input_form.",
        widgetStateJson = "{}",
      )
    val mutation =
      createFortuneToolCallMutation(
        messages =
          listOf(
            ChatMessageText(content = "오늘 운세 알려줘", side = ChatSide.USER),
            ChatMessageMcpWidgetCard(
              connectorId = existingSnapshot.connectorId,
              title = existingSnapshot.title,
              summary = existingSnapshot.summary,
              snapshot = existingSnapshot,
              side = ChatSide.AGENT,
            ),
          ),
        toolName = "show_today_fortune",
        widgetStateJson = """{"currentToolName":"show_today_fortune"}""",
      )

    assertEquals(1, mutation.replaceIndex)
    assertEquals("Updated after running show_today_fortune.", mutation.card.summary)
  }
}
