package com.google.ai.edge.gallery.ui.unifiedchat.session

import com.google.ai.edge.gallery.ui.common.chat.ChatMessage
import com.google.ai.edge.gallery.ui.common.chat.ChatMessageLoading
import com.google.ai.edge.gallery.ui.common.chat.ChatMessageText
import com.google.ai.edge.gallery.ui.common.chat.ChatMessageThinking
import com.google.ai.edge.gallery.ui.common.chat.ChatSide
import com.google.ai.edge.gallery.ui.llmchat.shouldRestorePersistedUnifiedSession
import com.google.ai.edge.gallery.ui.unifiedchat.mcp.McpWidgetSnapshot
import com.google.ai.edge.gallery.ui.unifiedchat.messages.ChatMessageMcpWidgetCard
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class UnifiedChatSessionFileStoreTest {
  @Test
  fun saveAndLoad_roundTripsMessagesConnectorsAndSnapshots() {
    val baseDir = Files.createTempDirectory("unified-chat-store").toFile()
    try {
      val store = UnifiedChatSessionFileStore(baseDir = baseDir)
      val session =
        UnifiedChatPersistedSession(
          id = "session-1",
          title = "Fortune follow up",
          activeConnectorIds = listOf("ugot_fortune"),
          messagesJson =
            listOf(
              requireNotNull(
                encodePersistableChatMessage(
                  ChatMessageText(
                    content = "hello",
                    side = ChatSide.USER,
                  )
                )
              )
            ),
          widgetSnapshots = listOf(McpWidgetSnapshot("ugot_fortune", "UGOT Fortune", "A", "{}")),
        )

      store.save(session)

      assertEquals(session, store.load("session-1"))
    } finally {
      baseDir.deleteRecursively()
    }
  }

  @Test
  fun save_overwritesExistingSessionAtomicallyEnoughToRemainReadable() {
    val baseDir = Files.createTempDirectory("unified-chat-store").toFile()
    try {
      val store = UnifiedChatSessionFileStore(baseDir = baseDir)
      val original =
        UnifiedChatPersistedSession(
          id = "session-1",
          title = "Original",
          activeConnectorIds = emptyList(),
          messagesJson = listOf("""{"type":"TEXT","side":"USER","content":"first"}"""),
          widgetSnapshots = emptyList(),
        )
      val updated =
        UnifiedChatPersistedSession(
          id = "session-1",
          title = "Updated",
          activeConnectorIds = listOf("ugot_fortune"),
          messagesJson = listOf("""{"type":"TEXT","side":"USER","content":"second"}"""),
          widgetSnapshots = listOf(McpWidgetSnapshot("ugot_fortune", "UGOT Fortune", "A", "{}")),
        )

      store.save(original)
      store.save(updated)

      assertEquals(updated, store.load("session-1"))
    } finally {
      baseDir.deleteRecursively()
    }
  }

  @Test
  fun encodeDecodePersistableChatMessage_roundTripsSupportedMessages() {
    val textMessage =
      ChatMessageText(
        content = "Need a fortune recap",
        side = ChatSide.USER,
        isMarkdown = false,
        accelerator = "gpu",
        hideSenderLabel = true,
      )
    val widgetSnapshot =
      McpWidgetSnapshot(
        connectorId = "ugot_fortune",
        title = "UGOT Fortune",
        summary = "Use caution with scheduling.",
        widgetStateJson = """{"tool":"show_today_fortune"}""",
      )
    val widgetMessage =
      ChatMessageMcpWidgetCard(
        connectorId = widgetSnapshot.connectorId,
        title = widgetSnapshot.title,
        summary = widgetSnapshot.summary,
        snapshot = widgetSnapshot,
      )

    val encodedText = requireNotNull(encodePersistableChatMessage(textMessage))
    val encodedWidget = requireNotNull(encodePersistableChatMessage(widgetMessage))

    val decodedText = requireNotNull(decodePersistedChatMessage(encodedText))
    val decodedWidget = requireNotNull(decodePersistedChatMessage(encodedWidget))

    assertTrue(decodedText is ChatMessageText)
    assertEquals(textMessage.content, (decodedText as ChatMessageText).content)
    assertEquals(textMessage.side, decodedText.side)
    assertEquals(textMessage.isMarkdown, decodedText.isMarkdown)
    assertEquals(textMessage.accelerator, decodedText.accelerator)
    assertEquals(textMessage.hideSenderLabel, decodedText.hideSenderLabel)

    assertTrue(decodedWidget is ChatMessageMcpWidgetCard)
    assertEquals(widgetMessage.connectorId, (decodedWidget as ChatMessageMcpWidgetCard).connectorId)
    assertEquals(widgetMessage.title, decodedWidget.title)
    assertEquals(widgetMessage.summary, decodedWidget.summary)
    assertEquals(widgetMessage.snapshot, decodedWidget.snapshot)
  }

  @Test
  fun decodePersistedChatMessage_normalizesThinkingMessagesOutOfProgress() {
    val thinkingMessage =
      ChatMessageThinking(
        content = "analyzing...",
        inProgress = true,
        side = ChatSide.AGENT,
      )

    val encodedThinking = requireNotNull(encodePersistableChatMessage(thinkingMessage))
    val decodedThinking = requireNotNull(decodePersistedChatMessage(encodedThinking))

    assertTrue(decodedThinking is ChatMessageThinking)
    assertFalse((decodedThinking as ChatMessageThinking).inProgress)
  }

  @Test
  fun encodePersistableChatMessage_skipsUnsupportedVolatileMessages() {
    val encoded = encodePersistableChatMessage(ChatMessageLoading(accelerator = "gpu"))

    assertNull(encoded)
  }

  @Test
  fun load_returnsNullForMissingSession() {
    val baseDir = Files.createTempDirectory("unified-chat-store").toFile()
    try {
      val store = UnifiedChatSessionFileStore(baseDir = baseDir)

      assertNull(store.load("missing-session"))
      assertFalse(store.sessionFile("missing-session").exists())
    } finally {
      baseDir.deleteRecursively()
    }
  }

  @Test
  fun load_returnsNullForCorruptJson() {
    val baseDir = Files.createTempDirectory("unified-chat-store").toFile()
    try {
      val store = UnifiedChatSessionFileStore(baseDir = baseDir)
      store.sessionFile("session-1").apply {
        parentFile?.mkdirs()
        writeText("""{"id":"session-1", """)
      }

      assertNull(store.load("session-1"))
    } finally {
      baseDir.deleteRecursively()
    }
  }

  @Test
  fun load_acceptsLegacySessionWithoutWidgetSnapshots() {
    val baseDir = Files.createTempDirectory("unified-chat-store").toFile()
    try {
      val store = UnifiedChatSessionFileStore(baseDir = baseDir)
      store.sessionFile("session-1").apply {
        parentFile?.mkdirs()
        writeText(
          """{"id":"session-1","title":"Legacy","activeConnectorIds":[],"messagesJson":["{\"type\":\"TEXT\",\"side\":\"USER\",\"content\":\"hello\"}"]}"""
        )
      }

      assertEquals(
        UnifiedChatPersistedSession(
          id = "session-1",
          title = "Legacy",
          activeConnectorIds = emptyList(),
          messagesJson =
            listOf("""{"type":"TEXT","side":"USER","content":"hello"}"""),
          widgetSnapshots = emptyList(),
        ),
        store.load("session-1"),
      )
    } finally {
      baseDir.deleteRecursively()
    }
  }

  @Test
  fun load_dropsMalformedWidgetSnapshotsButKeepsSession() {
    val baseDir = Files.createTempDirectory("unified-chat-store").toFile()
    try {
      val store = UnifiedChatSessionFileStore(baseDir = baseDir)
      store.sessionFile("session-1").apply {
        parentFile?.mkdirs()
        writeText(
          """{"id":"session-1","title":"Mixed snapshots","activeConnectorIds":["ugot_fortune"],"messagesJson":["{\"type\":\"TEXT\",\"side\":\"USER\",\"content\":\"hello\"}"],"widgetSnapshots":[{"connectorId":"ugot_fortune","title":"UGOT Fortune","summary":"A","widgetStateJson":"{}"},{"connectorId":"broken"}]}"""
        )
      }

      assertEquals(
        UnifiedChatPersistedSession(
          id = "session-1",
          title = "Mixed snapshots",
          activeConnectorIds = listOf("ugot_fortune"),
          messagesJson =
            listOf("""{"type":"TEXT","side":"USER","content":"hello"}"""),
          widgetSnapshots = listOf(McpWidgetSnapshot("ugot_fortune", "UGOT Fortune", "A", "{}")),
        ),
        store.load("session-1"),
      )
    } finally {
      baseDir.deleteRecursively()
    }
  }

  @Test
  fun shouldRestorePersistedSession_onlyWhenTranscriptIsStillEmpty() {
    val existingTranscript: List<ChatMessage> =
      listOf(ChatMessageText(content = "already loaded", side = ChatSide.USER))

    assertTrue(
      shouldRestorePersistedUnifiedSession(
        hasHandledRestoreForSession = false,
        currentMessages = emptyList(),
      )
    )
    assertFalse(
      shouldRestorePersistedUnifiedSession(
        hasHandledRestoreForSession = true,
        currentMessages = emptyList(),
      )
    )
    assertFalse(
      shouldRestorePersistedUnifiedSession(
        hasHandledRestoreForSession = false,
        currentMessages = existingTranscript,
      )
    )
  }
}
