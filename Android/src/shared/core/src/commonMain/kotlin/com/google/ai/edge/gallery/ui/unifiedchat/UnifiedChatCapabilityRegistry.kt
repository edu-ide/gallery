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

class UnifiedChatCapabilityRegistry(
  private val providers: Map<UnifiedChatCapability, UnifiedChatCapabilityProvider>,
) {
  fun resolve(
    modelCapabilities: UnifiedChatModelCapabilities,
    entryHint: UnifiedChatEntryHint,
  ): UnifiedChatCapabilityResolution {
    val enabled =
      providers.entries
        .filter { (capability, provider) ->
          modelCapabilities.supportsUnifiedChatCapability(capability) &&
            provider.isEnabled(modelCapabilities, entryHint)
        }
        .map { it.key }
        .toSet()
    val enabledCapabilities = enabled + UnifiedChatCapability.TEXT

    return UnifiedChatCapabilityResolution(
      enabledCapabilities = enabledCapabilities,
      activeConnectorIds =
        if (enabledCapabilities.contains(UnifiedChatCapability.MCP_CONNECTOR)) {
          entryHint.activateMcpConnectorIds
        } else {
          emptyList()
        },
    )
  }
}
