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
}
