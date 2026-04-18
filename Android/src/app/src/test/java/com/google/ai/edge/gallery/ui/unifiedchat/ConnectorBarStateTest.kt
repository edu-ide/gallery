package com.google.ai.edge.gallery.ui.unifiedchat

import org.junit.Assert.assertEquals
import org.junit.Test

class ConnectorBarStateTest {
  @Test
  fun toggleConnector_updatesVisibleActiveIds() {
    val state =
      ConnectorBarState(
        visibleConnectorIds = listOf("ugot_fortune", "calendar"),
        activeConnectorIds = setOf("ugot_fortune"),
      )

    val updated = state.toggle("calendar")

    assertEquals(setOf("ugot_fortune", "calendar"), updated.activeConnectorIds)
  }

  @Test
  fun toggleConnector_removesConnectorWhenAlreadyActive() {
    val state =
      ConnectorBarState(
        visibleConnectorIds = listOf("ugot_fortune", "calendar"),
        activeConnectorIds = setOf("ugot_fortune", "calendar"),
      )

    val updated = state.toggle("calendar")

    assertEquals(setOf("ugot_fortune"), updated.activeConnectorIds)
  }

  @Test
  fun toggleConnector_ignoresUnknownConnectorIdsWithoutDroppingHiddenActiveConnectors() {
    val state =
      ConnectorBarState(
        visibleConnectorIds = listOf("ugot_fortune", "calendar"),
        activeConnectorIds = setOf("ugot_fortune", "hidden_connector"),
      )

    val updated = state.toggle("hidden_connector")

    assertEquals(setOf("ugot_fortune", "hidden_connector"), updated.activeConnectorIds)
  }
}
