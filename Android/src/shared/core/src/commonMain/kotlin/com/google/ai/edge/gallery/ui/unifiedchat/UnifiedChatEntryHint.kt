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

package com.google.ai.edge.gallery.ui.unifiedchat

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

@Serializable
data class UnifiedChatEntryHint(
  val activateImage: Boolean = false,
  val activateAudio: Boolean = false,
  val activateSkills: Boolean = false,
  val activateAgentSkillIds: List<String> = emptyList(),
  val activateMcpConnectorIds: List<String> = emptyList(),
)

private val json = Json {
  ignoreUnknownKeys = true
  encodeDefaults = true
}

fun encodeUnifiedChatEntryHint(entryHint: UnifiedChatEntryHint): String =
  percentEncode(json.encodeToString(UnifiedChatEntryHint.serializer(), entryHint))

fun decodeUnifiedChatEntryHint(entryHintJson: String?): UnifiedChatEntryHint {
  if (entryHintJson.isNullOrBlank()) {
    return UnifiedChatEntryHint()
  }

  return runCatching {
      json.decodeFromString(
        UnifiedChatEntryHint.serializer(),
        percentDecode(entryHintJson),
      )
    }
    .getOrDefault(UnifiedChatEntryHint())
}

fun buildUnifiedChatRoute(taskId: String, modelName: String, entryHint: UnifiedChatEntryHint): String =
  "model/$taskId/$modelName?entry_hint=${encodeUnifiedChatEntryHint(entryHint)}"

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

private fun percentDecode(value: String): String {
  val bytes = mutableListOf<Byte>()
  var index = 0
  while (index < value.length) {
    val char = value[index]
    if (char == '%' && index + 2 < value.length) {
      val decoded = value.substring(index + 1, index + 3).toIntOrNull(radix = 16)
      if (decoded != null) {
        bytes += decoded.toByte()
        index += 3
        continue
      }
    }
    char.toString().encodeToByteArray().forEach { bytes += it }
    index++
  }
  return bytes.toByteArray().decodeToString()
}

private fun Char.isUnreservedUrlChar(): Boolean =
  this in 'A'..'Z' ||
    this in 'a'..'z' ||
    this in '0'..'9' ||
    this == '-' ||
    this == '.' ||
    this == '_' ||
    this == '~'
