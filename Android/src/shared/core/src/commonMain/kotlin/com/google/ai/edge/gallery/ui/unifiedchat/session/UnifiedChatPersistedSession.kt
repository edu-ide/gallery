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

import com.google.ai.edge.gallery.ui.unifiedchat.UnifiedChatEntryHint
import com.google.ai.edge.gallery.ui.unifiedchat.mcp.McpWidgetSnapshot
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/** Platform-neutral persisted transcript/session envelope. */
data class UnifiedChatPersistedSession(
  val id: String,
  val title: String,
  val activeConnectorIds: List<String>,
  val messagesJson: List<String>,
  val widgetSnapshots: List<McpWidgetSnapshot>,
)

@Serializable
private data class PersistedSessionSchema(
  val id: String? = null,
  val title: String? = null,
  val activeConnectorIds: List<String?>? = null,
  val messagesJson: List<String?>? = null,
  val widgetSnapshots: List<PersistedWidgetSnapshotSchema?>? = null,
)

@Serializable
private data class PersistedWidgetSnapshotSchema(
  val connectorId: String? = null,
  val title: String? = null,
  val summary: String? = null,
  val widgetStateJson: String? = null,
)

private val persistedJson = Json {
  ignoreUnknownKeys = true
  encodeDefaults = true
}

fun encodeUnifiedChatPersistedSession(session: UnifiedChatPersistedSession): String =
  persistedJson.encodeToString(PersistedSessionSchema.serializer(), session.toSchema())

fun decodeUnifiedChatPersistedSession(jsonValue: String): UnifiedChatPersistedSession? =
  runCatching {
      persistedJson.decodeFromString(PersistedSessionSchema.serializer(), jsonValue).toValidatedSession()
    }
    .getOrNull()

fun buildUnifiedChatSessionId(
  taskId: String,
  modelName: String,
  entryHint: UnifiedChatEntryHint,
): String = "$taskId::$modelName::${entryHint.toPersistenceKey()}"

fun unifiedChatSessionFileName(id: String): String = "${percentEncode(id)}.json"

private fun UnifiedChatPersistedSession.toSchema(): PersistedSessionSchema =
  PersistedSessionSchema(
    id = id,
    title = title,
    activeConnectorIds = activeConnectorIds,
    messagesJson = messagesJson,
    widgetSnapshots = widgetSnapshots.map { it.toSchema() },
  )

private fun McpWidgetSnapshot.toSchema(): PersistedWidgetSnapshotSchema =
  PersistedWidgetSnapshotSchema(
    connectorId = connectorId,
    title = title,
    summary = summary,
    widgetStateJson = widgetStateJson,
  )

private fun PersistedSessionSchema?.toValidatedSession(): UnifiedChatPersistedSession? {
  if (this == null) {
    return null
  }

  val sessionId = id ?: return null
  val sessionTitle = title ?: return null
  val connectorIds = activeConnectorIds?.filterNotNull() ?: return null
  val messages = messagesJson?.filterNotNull() ?: return null
  val snapshots = widgetSnapshots.orEmpty().mapNotNull(PersistedWidgetSnapshotSchema?::toValidatedSnapshot)

  if (connectorIds.size != activeConnectorIds.size || messages.size != messagesJson.size) {
    return null
  }

  return UnifiedChatPersistedSession(
    id = sessionId,
    title = sessionTitle,
    activeConnectorIds = connectorIds,
    messagesJson = messages,
    widgetSnapshots = snapshots,
  )
}

private fun PersistedWidgetSnapshotSchema?.toValidatedSnapshot(): McpWidgetSnapshot? {
  if (this == null) {
    return null
  }

  val snapshotConnectorId = connectorId ?: return null
  val snapshotTitle = title ?: return null
  val snapshotSummary = summary ?: return null
  val snapshotWidgetStateJson = widgetStateJson ?: return null

  return McpWidgetSnapshot(
    connectorId = snapshotConnectorId,
    title = snapshotTitle,
    summary = snapshotSummary,
    widgetStateJson = snapshotWidgetStateJson,
  )
}

private fun percentEncode(value: String): String {
  val bytes = value.encodeToByteArray()
  return buildString {
    bytes.forEach { byte ->
      val unsigned = byte.toInt() and 0xff
      val char = unsigned.toChar()
      if (char.isUnreservedUrlChar()) {
        append(char)
      } else {
        append('%')
        append(unsigned.toString(16).uppercase().padStart(2, '0'))
      }
    }
  }
}

private fun Char.isUnreservedUrlChar(): Boolean =
  this in 'A'..'Z' ||
    this in 'a'..'z' ||
    this in '0'..'9' ||
    this == '-' ||
    this == '.' ||
    this == '_' ||
    this == '~'

private fun UnifiedChatEntryHint.toPersistenceKey(): String =
  buildString {
    append("image=")
    append(activateImage)
    append(";audio=")
    append(activateAudio)
    append(";skills=")
    append(activateSkills)
    append(";mcp=")
    append(activateMcpConnectorIds.sorted().joinToString(","))
  }
