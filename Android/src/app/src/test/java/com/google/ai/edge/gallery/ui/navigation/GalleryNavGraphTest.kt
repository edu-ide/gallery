package com.google.ai.edge.gallery.ui.navigation

import com.google.ai.edge.gallery.BuildConfig
import com.google.ai.edge.gallery.data.BuiltInTaskId
import com.google.ai.edge.gallery.data.UgotTokenStatus
import com.google.ai.edge.gallery.ui.unifiedchat.UnifiedChatEntryHint
import com.google.ai.edge.gallery.ui.unifiedchat.buildUnifiedChatRoute
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class GalleryNavGraphTest {
  @Test
  fun resolveDeepLinkDestination_acceptsCurrentApplicationIdScheme() {
    val destination =
      resolveDeepLinkDestination(
        "${BuildConfig.APPLICATION_ID}://model/ugot_fortune_mcp_ui/UGOT%20Fortune%20MCP%20Runtime"
      )

    assertEquals(
      DeepLinkDestination.Model(
        taskId = "ugot_fortune_mcp_ui",
        modelName = "UGOT Fortune MCP Runtime",
      ),
      destination,
    )
  }

  @Test
  fun resolveDeepLinkDestination_acceptsLegacySchemeForBackwardCompatibility() {
    val destination = resolveDeepLinkDestination("com.google.ai.edge.gallery://global_model_manager")

    assertEquals(DeepLinkDestination.GlobalModelManager, destination)
  }

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

  @Test
  fun buildUnifiedChatRoute_encodesEntryHintQueryParameter() {
    val route =
      buildUnifiedChatRoute(
        taskId = BuiltInTaskId.LLM_CHAT,
        modelName = "Gemma 4",
        entryHint =
          UnifiedChatEntryHint(
            activateImage = false,
            activateAudio = false,
            activateSkills = false,
            activateMcpConnectorIds = listOf("ugot_fortune"),
          ),
      )

    assertEquals(
      "model/llm_chat/Gemma 4?entry_hint=%7B%22activateImage%22%3Afalse%2C%22activateAudio%22%3Afalse%2C%22activateSkills%22%3Afalse%2C%22activateMcpConnectorIds%22%3A%5B%22ugot_fortune%22%5D%7D",
      route,
    )
  }

  @Test
  fun resolveDeepLinkDestination_preservesLiteralPlusInModelName() {
    val destination =
      resolveDeepLinkDestination(
        "${BuildConfig.APPLICATION_ID}://model/ugot_fortune_mcp_ui/UGOT%20Fortune+MCP%20Runtime"
      )

    assertEquals(
      DeepLinkDestination.Model(
        taskId = "ugot_fortune_mcp_ui",
        modelName = "UGOT Fortune+MCP Runtime",
      ),
      destination,
    )
  }
}
