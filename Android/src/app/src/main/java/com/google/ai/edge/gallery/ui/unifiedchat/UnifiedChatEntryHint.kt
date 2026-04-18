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

import com.google.gson.Gson
import java.net.URLDecoder
import java.net.URLEncoder
import java.nio.charset.StandardCharsets

data class UnifiedChatEntryHint(
  val activateImage: Boolean = false,
  val activateAudio: Boolean = false,
  val activateSkills: Boolean = false,
  val activateMcpConnectorIds: List<String> = emptyList(),
)

private val gson = Gson()

fun encodeUnifiedChatEntryHint(entryHint: UnifiedChatEntryHint): String =
  URLEncoder.encode(gson.toJson(entryHint), StandardCharsets.UTF_8.name()).replace("+", "%20")

fun decodeUnifiedChatEntryHint(entryHintJson: String?): UnifiedChatEntryHint {
  if (entryHintJson.isNullOrBlank()) {
    return UnifiedChatEntryHint()
  }

  val decodedJson = URLDecoder.decode(entryHintJson, StandardCharsets.UTF_8.name())
  return runCatching { gson.fromJson(decodedJson, UnifiedChatEntryHint::class.java) }
    .getOrDefault(UnifiedChatEntryHint())
}

fun buildUnifiedChatRoute(taskId: String, modelName: String, entryHint: UnifiedChatEntryHint): String =
  "model/$taskId/$modelName?entry_hint=${encodeUnifiedChatEntryHint(entryHint)}"
