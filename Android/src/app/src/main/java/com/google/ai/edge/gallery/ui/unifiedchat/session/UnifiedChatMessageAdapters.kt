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
import com.google.ai.edge.gallery.ui.unifiedchat.UnifiedChatMessage
import com.google.ai.edge.gallery.ui.unifiedchat.UnifiedChatMessageRole
import com.google.ai.edge.gallery.ui.unifiedchat.messages.ChatMessageMcpWidgetCard

fun ChatMessage.toUnifiedChatMessage(id: String): UnifiedChatMessage? =
  when (this) {
    is ChatMessageText -> UnifiedChatMessage(id = id, role = side.toUnifiedChatMessageRole(), text = content)
    is ChatMessageThinking ->
      UnifiedChatMessage(
        id = id,
        role = UnifiedChatMessageRole.ASSISTANT,
        text = content,
      )
    is ChatMessageInfo -> UnifiedChatMessage(id = id, role = UnifiedChatMessageRole.SYSTEM, text = content)
    is ChatMessageWarning -> UnifiedChatMessage(id = id, role = UnifiedChatMessageRole.SYSTEM, text = content)
    is ChatMessageError -> UnifiedChatMessage(id = id, role = UnifiedChatMessageRole.SYSTEM, text = content)
    is ChatMessageMcpWidgetCard ->
      UnifiedChatMessage(
        id = id,
        role = side.toUnifiedChatMessageRole(),
        text = title.ifBlank { summary },
      )
    else -> null
  }

fun List<ChatMessage>.toUnifiedChatMessages(idPrefix: String = "a"): List<UnifiedChatMessage> =
  mapIndexedNotNull { index, message -> message.toUnifiedChatMessage(id = "$idPrefix$index") }

fun UnifiedChatMessage.toAndroidChatMessage(): ChatMessage =
  when (role) {
    UnifiedChatMessageRole.USER -> ChatMessageText(content = text, side = ChatSide.USER)
    UnifiedChatMessageRole.ASSISTANT -> ChatMessageText(content = text, side = ChatSide.AGENT)
    UnifiedChatMessageRole.SYSTEM -> ChatMessageInfo(content = text)
  }

fun List<UnifiedChatMessage>.toAndroidChatMessages(): List<ChatMessage> = map { it.toAndroidChatMessage() }

fun deriveConversationTitleFromUnifiedMessages(messages: List<UnifiedChatMessage>): String {
  val firstUserText =
    messages
      .firstOrNull { it.role == UnifiedChatMessageRole.USER && it.text.isNotBlank() }
      ?.text
      ?.lineSequence()
      ?.firstOrNull()
      ?.trim()
  if (!firstUserText.isNullOrEmpty()) {
    return firstUserText.take(60)
  }

  val firstAssistantText =
    messages
      .firstOrNull { it.role == UnifiedChatMessageRole.ASSISTANT && it.text.isNotBlank() }
      ?.text
      ?.lineSequence()
      ?.firstOrNull()
      ?.trim()
  if (!firstAssistantText.isNullOrEmpty()) {
    return firstAssistantText.take(60)
  }

  return "New chat"
}

private fun ChatSide.toUnifiedChatMessageRole(): UnifiedChatMessageRole =
  when (this) {
    ChatSide.USER -> UnifiedChatMessageRole.USER
    ChatSide.AGENT -> UnifiedChatMessageRole.ASSISTANT
    ChatSide.SYSTEM -> UnifiedChatMessageRole.SYSTEM
  }
