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

import com.google.ai.edge.gallery.ui.unifiedchat.mcp.McpWidgetSnapshot
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/** Persistable subset of chat message types supported by unified chat transcripts. */
enum class UnifiedChatPersistedMessageType {
  TEXT,
  INFO,
  WARNING,
  ERROR,
  THINKING,
  MCP_WIDGET_CARD,
}

/** Platform-neutral JSON envelope for persisted transcript messages. */
@Serializable
data class UnifiedChatPersistedMessageEnvelope(
  val type: UnifiedChatPersistedMessageType,
  val side: String? = null,
  val content: String? = null,
  val isMarkdown: Boolean? = null,
  val latencyMs: Float? = null,
  val accelerator: String? = null,
  val hideSenderLabel: Boolean? = null,
  val inProgress: Boolean? = null,
  val connectorId: String? = null,
  val title: String? = null,
  val summary: String? = null,
  val snapshot: McpWidgetSnapshot? = null,
  val disableBubbleShape: Boolean? = null,
)

private val persistedMessageJson = Json {
  ignoreUnknownKeys = true
  encodeDefaults = true
}

fun encodeUnifiedChatPersistedMessageEnvelope(
  envelope: UnifiedChatPersistedMessageEnvelope
): String = persistedMessageJson.encodeToString(UnifiedChatPersistedMessageEnvelope.serializer(), envelope)

fun decodeUnifiedChatPersistedMessageEnvelope(
  jsonValue: String
): UnifiedChatPersistedMessageEnvelope? =
  runCatching {
      persistedMessageJson.decodeFromString(
        UnifiedChatPersistedMessageEnvelope.serializer(),
        jsonValue,
      )
    }
    .getOrNull()
