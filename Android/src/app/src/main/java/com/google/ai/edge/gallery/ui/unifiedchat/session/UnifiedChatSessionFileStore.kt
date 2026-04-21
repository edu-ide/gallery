/*
 * Copyright 2026 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package com.google.ai.edge.gallery.ui.unifiedchat.session

import com.google.ai.edge.gallery.ui.common.chat.ChatMessage
import com.google.ai.edge.gallery.ui.common.chat.ChatMessageError
import com.google.ai.edge.gallery.ui.common.chat.ChatMessageInfo
import com.google.ai.edge.gallery.ui.common.chat.ChatMessageText
import com.google.ai.edge.gallery.ui.common.chat.ChatMessageThinking
import com.google.ai.edge.gallery.ui.common.chat.ChatMessageWarning
import com.google.ai.edge.gallery.ui.common.chat.ChatSide
import com.google.ai.edge.gallery.ui.unifiedchat.mcp.McpWidgetSnapshot
import com.google.ai.edge.gallery.ui.unifiedchat.messages.ChatMessageMcpWidgetCard
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption

fun encodePersistableChatMessage(message: ChatMessage): String? {
  val envelope =
    when (message) {
      is ChatMessageText ->
        UnifiedChatPersistedMessageEnvelope(
          type = UnifiedChatPersistedMessageType.TEXT,
          side = message.side.name,
          content = message.content,
          isMarkdown = message.isMarkdown,
          latencyMs = message.latencyMs,
          accelerator = message.accelerator,
          hideSenderLabel = message.hideSenderLabel,
        )
      is ChatMessageInfo ->
        UnifiedChatPersistedMessageEnvelope(
          type = UnifiedChatPersistedMessageType.INFO,
          content = message.content,
        )
      is ChatMessageWarning ->
        UnifiedChatPersistedMessageEnvelope(
          type = UnifiedChatPersistedMessageType.WARNING,
          content = message.content,
        )
      is ChatMessageError ->
        UnifiedChatPersistedMessageEnvelope(
          type = UnifiedChatPersistedMessageType.ERROR,
          content = message.content,
        )
      is ChatMessageThinking ->
        UnifiedChatPersistedMessageEnvelope(
          type = UnifiedChatPersistedMessageType.THINKING,
          side = message.side.name,
          content = message.content,
          accelerator = message.accelerator,
          hideSenderLabel = message.hideSenderLabel,
          inProgress = message.inProgress,
        )
      is ChatMessageMcpWidgetCard ->
        UnifiedChatPersistedMessageEnvelope(
          type = UnifiedChatPersistedMessageType.MCP_WIDGET_CARD,
          side = message.side.name,
          connectorId = message.connectorId,
          title = message.title,
          summary = message.summary,
          snapshot = message.snapshot,
          disableBubbleShape = message.disableBubbleShape,
        )
      else -> null
    }

  return envelope?.let(::encodeUnifiedChatPersistedMessageEnvelope)
}

fun decodePersistedChatMessage(json: String): ChatMessage? {
  return runCatching {
      val envelope = decodeUnifiedChatPersistedMessageEnvelope(json) ?: return null
      when (envelope.type) {
        UnifiedChatPersistedMessageType.TEXT ->
          ChatMessageText(
            content = envelope.content.orEmpty(),
            side = envelope.side.toChatSide(),
            latencyMs = envelope.latencyMs ?: 0f,
            isMarkdown = envelope.isMarkdown ?: true,
            accelerator = envelope.accelerator.orEmpty(),
            hideSenderLabel = envelope.hideSenderLabel ?: false,
          )
        UnifiedChatPersistedMessageType.INFO -> ChatMessageInfo(content = envelope.content.orEmpty())
        UnifiedChatPersistedMessageType.WARNING -> ChatMessageWarning(content = envelope.content.orEmpty())
        UnifiedChatPersistedMessageType.ERROR -> ChatMessageError(content = envelope.content.orEmpty())
        UnifiedChatPersistedMessageType.THINKING ->
          ChatMessageThinking(
            content = envelope.content.orEmpty(),
            inProgress = false,
            side = envelope.side.toChatSide(),
            accelerator = envelope.accelerator.orEmpty(),
            hideSenderLabel = envelope.hideSenderLabel ?: false,
          )
        UnifiedChatPersistedMessageType.MCP_WIDGET_CARD -> {
          val snapshot =
            envelope.snapshot
              ?: McpWidgetSnapshot(
                connectorId = envelope.connectorId.orEmpty(),
                title = envelope.title.orEmpty(),
                summary = envelope.summary.orEmpty(),
                widgetStateJson = "{}",
              )
          ChatMessageMcpWidgetCard(
            connectorId = snapshot.connectorId,
            title = envelope.title ?: snapshot.title,
            summary = envelope.summary ?: snapshot.summary,
            snapshot = snapshot,
            side = envelope.side.toChatSide(),
            disableBubbleShape = envelope.disableBubbleShape ?: true,
          )
        }
      }
    }
    .getOrNull()
}

class UnifiedChatSessionFileStore(private val baseDir: File) {
  fun save(session: UnifiedChatPersistedSession) {
    val file = sessionFile(session.id)
    file.parentFile?.mkdirs()
    val tempFile = File.createTempFile(file.name, ".tmp", file.parentFile)
    tempFile.writeText(encodeUnifiedChatPersistedSession(session))
    runCatching {
        Files.move(
          tempFile.toPath(),
          file.toPath(),
          StandardCopyOption.REPLACE_EXISTING,
          StandardCopyOption.ATOMIC_MOVE,
        )
      }
      .recoverCatching {
        Files.move(
          tempFile.toPath(),
          file.toPath(),
          StandardCopyOption.REPLACE_EXISTING,
        )
      }
      .onFailure {
        tempFile.delete()
        throw it
      }
      .onSuccess {
        tempFile.delete()
      }
  }

  fun load(id: String): UnifiedChatPersistedSession? {
    val file = sessionFile(id)
    if (!file.exists()) {
      return null
    }

    return runCatching {
        decodeUnifiedChatPersistedSession(file.readText())
      }
      .getOrNull()
  }

  fun delete(id: String) {
    sessionFile(id).delete()
  }

  internal fun sessionFile(id: String): File =
    File(baseDir, unifiedChatSessionFileName(id))
}

private fun String?.toChatSide(): ChatSide =
  runCatching { ChatSide.valueOf(this.orEmpty()) }.getOrDefault(ChatSide.SYSTEM)
