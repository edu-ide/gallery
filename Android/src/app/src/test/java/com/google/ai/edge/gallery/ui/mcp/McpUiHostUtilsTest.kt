package com.google.ai.edge.gallery.ui.mcp

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class McpUiHostUtilsTest {
  @Test
  fun selectPreferredWidgetResource_prefersStandardMcpAppMimeType() {
    val resources =
      listOf(
        McpUiWidgetResource(
          uri = "ui://widget/legacy.html?v=1",
          mimeType = McpUiHostUtils.LEGACY_WIDGET_MIME_TYPE,
        ),
        McpUiWidgetResource(
          uri = "ui://widget/standard.html?v=3",
          mimeType = McpUiHostUtils.STANDARD_WIDGET_MIME_TYPE,
        ),
      )

    val selected = McpUiHostUtils.selectPreferredWidgetResource(resources)

    assertNotNull(selected)
    assertEquals("ui://widget/standard.html?v=3", selected?.uri)
  }

  @Test
  fun selectPreferredWidgetResource_prefersVersionedUriWithinSameMimeType() {
    val resources =
      listOf(
        McpUiWidgetResource(
          uri = "ui://widget/widget.html",
          mimeType = McpUiHostUtils.STANDARD_WIDGET_MIME_TYPE,
        ),
        McpUiWidgetResource(
          uri = "ui://widget/widget.html?v=8",
          mimeType = McpUiHostUtils.STANDARD_WIDGET_MIME_TYPE,
        ),
      )

    val selected = McpUiHostUtils.selectPreferredWidgetResource(resources)

    assertEquals("ui://widget/widget.html?v=8", selected?.uri)
  }

  @Test
  fun injectHostBridge_marksHostAsMcpAppsAndExposesWidgetApis() {
    val html = "<html><head></head><body><div id=\"root\"></div></body></html>"

    val injected =
      McpUiHostUtils.injectHostBridge(
        html = html,
        toolName = "show_today_fortune",
        toolInputJson = """{"name":"Trip"}""",
        toolOutputJson = """{"result":{"fortune":"good"}}""",
        widgetStateJson = """{"tab":"today"}""",
      )

    assertTrue(injected.contains("__hostType: 'mcp-apps'"))
    assertTrue(injected.contains("toolName: \"show_today_fortune\""))
    assertTrue(injected.contains("callTool(name, args)"))
    assertTrue(injected.contains("setWidgetState(nextState)"))
    assertTrue(injected.contains("requestDisplayMode"))
    assertTrue(injected.contains("window.__mcpBridge = (message) =>"))
    assertTrue(injected.contains("window.mcpApp = mcpApp"))
    assertTrue(injected.contains("notifyMcpApp(\"ui/notifications/tool-input\""))
    assertTrue(injected.contains("window.openai = host"))
  }
}
