package com.google.ai.edge.gallery.ui.unifiedchat.mcp

import org.junit.Assert.assertEquals
import org.junit.Test

class McpWidgetSnapshotTest {
  @Test
  fun snapshot_roundTripsCardSummaryAndWidgetState() {
    val snapshot =
      McpWidgetSnapshot(
        connectorId = "ugot_fortune",
        title = "UGOT Fortune",
        summary = "이번 주는 일정 조율이 핵심",
        widgetStateJson = """{"currentToolName":"show_today_fortune"}""",
      )

    val encoded = snapshot.toJson()
    val decoded = McpWidgetSnapshot.fromJson(encoded)

    assertEquals(snapshot, decoded)
  }

  @Test
  fun activate_replacesPreviousLiveWidgetButKeepsSnapshotIdentity() {
    val firstSnapshot = McpWidgetSnapshot("ugot_fortune", "UGOT Fortune", "A", "{}")
    val secondSnapshot = McpWidgetSnapshot("calendar", "Calendar", "B", "{}")
    val state = McpWidgetHostState()

    val afterFirst = state.activate(firstSnapshot, fullscreen = false)
    val afterSecond = afterFirst.activate(secondSnapshot, fullscreen = true)

    assertEquals(secondSnapshot, afterSecond.activeSnapshot)
    assertEquals(McpWidgetDisplayMode.FULLSCREEN, afterSecond.displayMode)
  }
}
