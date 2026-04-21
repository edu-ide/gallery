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

import com.google.ai.edge.gallery.ui.unifiedchat.mcp.McpWidgetHostState
import com.google.ai.edge.gallery.ui.unifiedchat.mcp.McpWidgetSnapshot

/** Platform-neutral role for a unified chat message. */
enum class UnifiedChatMessageRole {
  USER,
  ASSISTANT,
  SYSTEM,
}

/** Platform-neutral chat message model used by Android and iOS shells. */
data class UnifiedChatMessage(
  val id: String,
  val role: UnifiedChatMessageRole,
  val text: String,
)

/**
 * Platform-neutral session state for the unified chat shell.
 *
 * This class intentionally keeps the model execution result as plain text for now. Runtime adapters
 * can later replace [submitDraft] with real inference while keeping the state transitions stable.
 */
data class UnifiedChatSessionState(
  val modelName: String,
  val modelDisplayName: String,
  val taskId: String,
  val modelCapabilities: UnifiedChatModelCapabilities,
  val entryHint: UnifiedChatEntryHint,
  val connectorBarState: ConnectorBarState,
  val messages: List<UnifiedChatMessage>,
  val draft: String,
  val widgetHostState: McpWidgetHostState,
  val nextMessageIndex: Int,
) {
  fun updateDraft(draft: String): UnifiedChatSessionState = copy(draft = draft)

  fun toggleConnector(connectorId: String): UnifiedChatSessionState =
    copy(connectorBarState = connectorBarState.toggle(connectorId))

  fun appendAssistantMessage(text: String): UnifiedChatSessionState =
    appendMessage(role = UnifiedChatMessageRole.ASSISTANT, text = text)

  fun appendSystemMessage(text: String): UnifiedChatSessionState =
    appendMessage(role = UnifiedChatMessageRole.SYSTEM, text = text)

  fun submitDraft(responsePrefix: String = "Stub response"): UnifiedChatSessionState {
    val trimmedDraft = draft.trim()
    if (trimmedDraft.isEmpty()) {
      return this
    }

    val userMessage = nextMessage(role = UnifiedChatMessageRole.USER, text = trimmedDraft)
    val activeConnectors = connectorBarState.activeConnectorIds.sorted()
    val connectorSummary =
      if (activeConnectors.isEmpty()) {
        "none"
      } else {
        activeConnectors.joinToString(", ")
      }
    val assistantMessage =
      userMessage.next(
        role = UnifiedChatMessageRole.ASSISTANT,
        text = "$responsePrefix from $modelDisplayName. Active connectors: $connectorSummary.",
      )

    return copy(
      messages = messages + userMessage.message + assistantMessage.message,
      draft = "",
      nextMessageIndex = assistantMessage.nextIndex,
    )
  }

  fun activateWidget(snapshot: McpWidgetSnapshot, fullscreen: Boolean): UnifiedChatSessionState =
    copy(widgetHostState = widgetHostState.activate(snapshot = snapshot, fullscreen = fullscreen))

  fun closeWidget(): UnifiedChatSessionState = copy(widgetHostState = widgetHostState.close())

  fun currentEntryHint(): UnifiedChatEntryHint =
    entryHint.copy(activateMcpConnectorIds = connectorBarState.activeConnectorIds.sorted())

  fun route(): String = buildUnifiedChatRoute(taskId = taskId, modelName = modelName, entryHint = currentEntryHint())

  fun connectorLauncherLabel(): String =
    buildConnectorLauncherLabel(activeConnectorCount = connectorBarState.activeConnectorIds.size)

  fun chromePolicy(): UnifiedChatChromePolicy =
    resolveUnifiedChatChromePolicy(
      hasVisibleConnectors = connectorBarState.visibleConnectorIds.isNotEmpty(),
      supportsAudioInput = modelCapabilities.supportsUnifiedChatCapability(UnifiedChatCapability.AUDIO),
    )

  private fun appendMessage(role: UnifiedChatMessageRole, text: String): UnifiedChatSessionState {
    val appended = nextMessage(role = role, text = text)
    return copy(messages = messages + appended.message, nextMessageIndex = appended.nextIndex)
  }

  private fun nextMessage(role: UnifiedChatMessageRole, text: String): IndexedMessage =
    IndexedMessage(
      message = UnifiedChatMessage(id = "m$nextMessageIndex", role = role, text = text),
      nextIndex = nextMessageIndex + 1,
    )

  private fun UnifiedChatSessionState.IndexedMessage.next(
    role: UnifiedChatMessageRole,
    text: String,
  ): IndexedMessage =
    IndexedMessage(
      message = UnifiedChatMessage(id = "m$nextIndex", role = role, text = text),
      nextIndex = nextIndex + 1,
    )

  private data class IndexedMessage(
    val message: UnifiedChatMessage,
    val nextIndex: Int,
  )
}

fun createUnifiedChatSessionState(
  modelName: String,
  modelDisplayName: String,
  taskId: String,
  modelCapabilities: UnifiedChatModelCapabilities,
  entryHint: UnifiedChatEntryHint,
  visibleConnectorIds: List<String>,
  initialDraft: String = "",
): UnifiedChatSessionState {
  val activeConnectorIds = entryHint.activateMcpConnectorIds.filter { visibleConnectorIds.contains(it) }
  return UnifiedChatSessionState(
    modelName = modelName,
    modelDisplayName = modelDisplayName,
    taskId = taskId,
    modelCapabilities = modelCapabilities,
    entryHint = entryHint,
    connectorBarState =
      ConnectorBarState(
        visibleConnectorIds = visibleConnectorIds,
        activeConnectorIds = activeConnectorIds.toSet(),
      ),
    messages =
      listOf(
        UnifiedChatMessage(
          id = "m0",
          role = UnifiedChatMessageRole.ASSISTANT,
          text = "Loaded $modelDisplayName. This is the shared KMP chat session shell.",
        ),
        UnifiedChatMessage(
          id = "m1",
          role = UnifiedChatMessageRole.SYSTEM,
          text = "Shared core owns draft, messages, connectors, route hints, and widget host state.",
        ),
      ),
    draft = initialDraft,
    widgetHostState = McpWidgetHostState(),
    nextMessageIndex = 2,
  )
}
