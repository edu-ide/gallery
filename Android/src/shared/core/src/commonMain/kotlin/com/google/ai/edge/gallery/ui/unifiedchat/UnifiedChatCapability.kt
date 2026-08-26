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

enum class UnifiedChatCapability {
  TEXT,
  IMAGE,
  AUDIO,
  SKILLS,
  MCP_CONNECTOR,
}

data class UnifiedChatModelCapabilities(
  val supportsImage: Boolean = false,
  val supportsAudio: Boolean = false,
)

data class UnifiedChatCapabilityResolution(
  val enabledCapabilities: Set<UnifiedChatCapability>,
  val activeConnectorIds: List<String>,
)

fun UnifiedChatModelCapabilities.supportsUnifiedChatCapability(
  requiredCapability: UnifiedChatCapability
): Boolean {
  return when (requiredCapability) {
    UnifiedChatCapability.TEXT,
    UnifiedChatCapability.SKILLS,
    UnifiedChatCapability.MCP_CONNECTOR -> true
    UnifiedChatCapability.IMAGE -> supportsImage
    UnifiedChatCapability.AUDIO -> supportsAudio
  }
}

fun <T> recommendCompatibleModelFromPools(
  currentTaskModels: List<T>,
  unifiedChatModels: List<T>,
  requiredCapability: UnifiedChatCapability,
  modelKey: (T) -> String,
  modelCapabilities: (T) -> UnifiedChatModelCapabilities,
): T? {
  val currentKeys = currentTaskModels.map(modelKey).toSet()
  val dedupedModelPool =
    buildList {
      addAll(currentTaskModels)
      unifiedChatModels.forEach { candidate ->
        if (!currentKeys.contains(modelKey(candidate))) {
          add(candidate)
        }
      }
    }
  return dedupedModelPool.firstOrNull { model ->
    modelCapabilities(model).supportsUnifiedChatCapability(requiredCapability)
  }
}
