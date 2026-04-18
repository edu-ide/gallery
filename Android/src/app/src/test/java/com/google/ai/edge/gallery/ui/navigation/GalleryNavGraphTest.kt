package com.google.ai.edge.gallery.ui.navigation

import com.google.ai.edge.gallery.data.UgotTokenStatus
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class GalleryNavGraphTest {
  @Test
  fun resolveStartupRoute_prefersDeepLinkOverChatFallback() {
    val route =
      resolveStartupRoute(
        authStatus = UgotTokenStatus.NOT_EXPIRED,
        loadingModelAllowlist = false,
        deepLinkRoute = "route_model/ugot_fortune_mcp_ui/UGOT Fortune MCP Runtime",
        chatTaskId = "llm_chat",
        initialModelName = "Gemma 4",
        enableDeveloperGallery = false,
        navigationHandled = false,
      )

    assertEquals("route_model/ugot_fortune_mcp_ui/UGOT Fortune MCP Runtime", route)
  }

  @Test
  fun resolveStartupRoute_returnsNullAfterInitialNavigationHandled() {
    val route =
      resolveStartupRoute(
        authStatus = UgotTokenStatus.NOT_EXPIRED,
        loadingModelAllowlist = false,
        deepLinkRoute = null,
        chatTaskId = "llm_chat",
        initialModelName = "Gemma 4",
        enableDeveloperGallery = false,
        navigationHandled = true,
      )

    assertNull(route)
  }
}
