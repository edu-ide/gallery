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

package com.google.ai.edge.gallery.ui.unifiedchat.messages

import com.google.ai.edge.gallery.ui.common.chat.ChatMessage
import com.google.ai.edge.gallery.ui.common.chat.ChatMessageType
import com.google.ai.edge.gallery.ui.common.chat.ChatSide
import com.google.ai.edge.gallery.ui.unifiedchat.mcp.McpWidgetSnapshot

class ChatMessageMcpWidgetCard(
  val connectorId: String,
  val title: String,
  val summary: String,
  val snapshot: McpWidgetSnapshot,
  override val side: ChatSide = ChatSide.AGENT,
  override val disableBubbleShape: Boolean = true,
) :
  ChatMessage(
    type = ChatMessageType.MCP_WIDGET_CARD,
    side = side,
    disableBubbleShape = disableBubbleShape,
  ) {
  override fun clone(): ChatMessageMcpWidgetCard {
    return ChatMessageMcpWidgetCard(
      connectorId = connectorId,
      title = title,
      summary = summary,
      snapshot = snapshot,
      side = side,
      disableBubbleShape = disableBubbleShape,
    )
  }
}
