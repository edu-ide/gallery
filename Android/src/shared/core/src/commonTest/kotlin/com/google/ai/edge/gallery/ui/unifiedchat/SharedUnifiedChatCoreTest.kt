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

import com.google.ai.edge.gallery.ui.unifiedchat.mcp.McpWidgetDisplayMode
import com.google.ai.edge.gallery.ui.unifiedchat.mcp.McpWidgetHostState
import com.google.ai.edge.gallery.ui.unifiedchat.mcp.McpWidgetSnapshot
import com.google.ai.edge.gallery.ui.unifiedchat.session.UnifiedChatPersistedSession
import com.google.ai.edge.gallery.ui.unifiedchat.session.decodeUnifiedChatPersistedSession
import com.google.ai.edge.gallery.ui.unifiedchat.session.encodeUnifiedChatPersistedSession
import com.google.ai.edge.gallery.ui.unifiedchat.session.unifiedChatSessionFileName
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class SharedUnifiedChatCoreTest {
  @Test
  fun entryHint_roundTripsThroughRouteSafeEncoding() {
    val hint =
      UnifiedChatEntryHint(
        activateImage = true,
        activateAudio = true,
        activateSkills = true,
        activateMcpConnectorIds = listOf("ugot_fortune", "calendar"),
      )

    val encoded = encodeUnifiedChatEntryHint(hint)
    val decoded = decodeUnifiedChatEntryHint(encoded)

    assertEquals(hint, decoded)
    assertFalse(encoded.contains("+"))
  }

  @Test
  fun connectorBarState_togglesOnlyVisibleConnectors() {
    val state =
      ConnectorBarState(
        visibleConnectorIds = listOf("ugot_fortune", "calendar"),
        activeConnectorIds = setOf("ugot_fortune", "hidden_connector"),
      )

    assertEquals(
      setOf("ugot_fortune", "calendar", "hidden_connector"),
      state.toggle("calendar").activeConnectorIds,
    )
    assertEquals(
      setOf("ugot_fortune", "hidden_connector"),
      state.toggle("hidden_connector").activeConnectorIds,
    )
  }

  @Test
  fun chromePolicy_keepsHistoryOutOfComposerAndShowsMicWhenAudioIsSupported() {
    val policy =
      resolveUnifiedChatChromePolicy(hasVisibleConnectors = true, supportsAudioInput = true)

    assertTrue(policy.showInputHistoryInTopBar)
    assertFalse(policy.showInputHistoryInComposerMenu)
    assertTrue(policy.showConnectorLauncherInComposer)
    assertTrue(policy.showStandaloneAudioRecordButtonInComposer)
  }

  @Test
  fun mcpWidgetSnapshotAndHostState_arePlatformNeutral() {
    val snapshot =
      McpWidgetSnapshot(
        connectorId = "ugot_fortune",
        title = "UGOT Fortune",
        summary = "오늘은 흐름을 정리하는 날",
        widgetStateJson = """{"currentToolName":"show_today_fortune"}""",
      )

    val decoded = McpWidgetSnapshot.fromJson(snapshot.toJson())
    val state = McpWidgetHostState().activate(decoded, fullscreen = true)

    assertEquals(snapshot, decoded)
    assertEquals(snapshot, state.activeSnapshot)
    assertEquals(McpWidgetDisplayMode.FULLSCREEN, state.displayMode)
  }
  @Test
  fun unifiedChatSessionState_submitsDraftAndTracksConnectors() {
    val state =
      createUnifiedChatSessionState(
        modelName = "Gemma-4-E2B-it",
        modelDisplayName = "Gemma E2B",
        taskId = "llm_chat",
        modelCapabilities = UnifiedChatModelCapabilities(supportsImage = true, supportsAudio = true),
        entryHint = UnifiedChatEntryHint(activateMcpConnectorIds = listOf("github", "hidden")),
        visibleConnectorIds = listOf("github", "gmail"),
        initialDraft = "Hello from shared state",
      )

    assertEquals(setOf("github"), state.connectorBarState.activeConnectorIds)

    val updated = state.toggleConnector("gmail").submitDraft(responsePrefix = "Reply")

    assertEquals("", updated.draft)
    assertEquals(4, updated.messages.size)
    assertEquals(UnifiedChatMessageRole.USER, updated.messages[2].role)
    assertEquals("Hello from shared state", updated.messages[2].text)
    assertEquals(UnifiedChatMessageRole.ASSISTANT, updated.messages[3].role)
    assertTrue(updated.messages[3].text.contains("github, gmail"))
    assertTrue(updated.route().contains("Gemma-4-E2B-it"))
    assertEquals("Connectors (2)", updated.connectorLauncherLabel())
  }

  @Test
  fun unifiedChatSessionState_widgetHostRoundTripsThroughReducer() {
    val state =
      createUnifiedChatSessionState(
        modelName = "FunctionGemma-270m-it",
        modelDisplayName = "FunctionGemma",
        taskId = "agent_chat",
        modelCapabilities = UnifiedChatModelCapabilities(),
        entryHint = UnifiedChatEntryHint(activateSkills = true),
        visibleConnectorIds = listOf("github"),
      )
    val snapshot =
      McpWidgetSnapshot(
        connectorId = "github",
        title = "GitHub widget",
        summary = "Repository state",
        widgetStateJson = "{}",
      )

    val active = state.activateWidget(snapshot, fullscreen = false)

    assertEquals(snapshot, active.widgetHostState.activeSnapshot)
    assertEquals(McpWidgetDisplayMode.INLINE, active.widgetHostState.displayMode)
    assertEquals(null, active.closeWidget().widgetHostState.activeSnapshot)
  }

  @Test
  fun persistedSessionSchema_roundTripsAndValidatesLegacyData() {
    val session =
      UnifiedChatPersistedSession(
        id = "task::model::hint",
        title = "Unified chat",
        activeConnectorIds = listOf("github", "gmail"),
        messagesJson = listOf("{\"type\":\"TEXT\"}"),
        widgetSnapshots =
          listOf(
            McpWidgetSnapshot(
              connectorId = "github",
              title = "GitHub",
              summary = "PR summary",
              widgetStateJson = "{}",
            )
          ),
      )

    assertEquals(session, decodeUnifiedChatPersistedSession(encodeUnifiedChatPersistedSession(session)))
    assertEquals("task%3A%3Amodel%3A%3Ahint.json", unifiedChatSessionFileName(session.id))
  }

  @Test
  fun persistedSessionSchema_rejectsNullMessageEntriesButKeepsLegacyMissingSnapshots() {
    val legacy =
      """{"id":"session-1","title":"Legacy","activeConnectorIds":[],"messagesJson":["{}"]}"""
    val malformed =
      """{"id":"session-1","title":"Bad","activeConnectorIds":[],"messagesJson":[null]}"""

    assertEquals(emptyList<McpWidgetSnapshot>(), decodeUnifiedChatPersistedSession(legacy)?.widgetSnapshots)
    assertEquals(null, decodeUnifiedChatPersistedSession(malformed))
  }

}
