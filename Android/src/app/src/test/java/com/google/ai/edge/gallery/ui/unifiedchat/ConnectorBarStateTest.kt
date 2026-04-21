package com.google.ai.edge.gallery.ui.unifiedchat

import org.junit.Assert.assertEquals
import org.junit.Test

class ConnectorBarStateTest {
  @Test
  fun toggleConnector_updatesVisibleActiveIds() {
    val state =
      ConnectorBarState(
        visibleConnectorIds = listOf("fortune.ugot.uk/mcp", "calendar"),
        activeConnectorIds = setOf("fortune.ugot.uk/mcp"),
      )

    val updated = state.toggle("calendar")

    assertEquals(setOf("fortune.ugot.uk/mcp", "calendar"), updated.activeConnectorIds)
  }

  @Test
  fun toggleConnector_removesConnectorWhenAlreadyActive() {
    val state =
      ConnectorBarState(
        visibleConnectorIds = listOf("fortune.ugot.uk/mcp", "calendar"),
        activeConnectorIds = setOf("fortune.ugot.uk/mcp", "calendar"),
      )

    val updated = state.toggle("calendar")

    assertEquals(setOf("fortune.ugot.uk/mcp"), updated.activeConnectorIds)
  }

  @Test
  fun toggleConnector_ignoresUnknownConnectorIdsWithoutDroppingHiddenActiveConnectors() {
    val state =
      ConnectorBarState(
        visibleConnectorIds = listOf("fortune.ugot.uk/mcp", "calendar"),
        activeConnectorIds = setOf("fortune.ugot.uk/mcp", "hidden_connector"),
      )

    val updated = state.toggle("hidden_connector")

    assertEquals(setOf("fortune.ugot.uk/mcp", "hidden_connector"), updated.activeConnectorIds)
  }
}
