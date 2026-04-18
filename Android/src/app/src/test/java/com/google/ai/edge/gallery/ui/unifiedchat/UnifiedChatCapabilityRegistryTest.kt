package com.google.ai.edge.gallery.ui.unifiedchat

import com.google.ai.edge.gallery.data.Model
import org.junit.Assert.assertEquals
import org.junit.Test

class UnifiedChatCapabilityRegistryTest {
  private val providers =
    mapOf(
      UnifiedChatCapability.IMAGE to
        UnifiedChatCapabilityProvider { candidate, hint ->
          hint.activateImage && candidate.llmSupportImage
        },
      UnifiedChatCapability.AUDIO to
        UnifiedChatCapabilityProvider { candidate, hint ->
          hint.activateAudio && candidate.llmSupportAudio
        },
      UnifiedChatCapability.SKILLS to
        UnifiedChatCapabilityProvider { _, hint -> hint.activateSkills },
      UnifiedChatCapability.MCP_CONNECTOR to
        UnifiedChatCapabilityProvider { _, hint -> hint.activateMcpConnectorIds.isNotEmpty() },
    )

  @Test
  fun resolveActiveCapabilities_enablesImageAudioSkillsAndMcpFromHint() {
    val model =
      Model(
        name = "Gemma 4",
        displayName = "Gemma 4",
        llmSupportImage = true,
        llmSupportAudio = true,
      )

    val result =
      UnifiedChatCapabilityRegistry(providers).resolve(
        model = model,
        entryHint =
          UnifiedChatEntryHint(
            activateImage = true,
            activateAudio = true,
            activateSkills = true,
            activateMcpConnectorIds = listOf("ugot_fortune"),
          ),
      )

    assertEquals(
      setOf(
        UnifiedChatCapability.TEXT,
        UnifiedChatCapability.IMAGE,
        UnifiedChatCapability.AUDIO,
        UnifiedChatCapability.SKILLS,
        UnifiedChatCapability.MCP_CONNECTOR,
      ),
      result.enabledCapabilities,
    )
    assertEquals(listOf("ugot_fortune"), result.activeConnectorIds)
  }

  @Test
  fun resolveActiveCapabilities_keepsTextAndDropsConnectorsWhenMcpCapabilityDisabled() {
    val model = Model(name = "Gemma 4", displayName = "Gemma 4")

    val result =
      UnifiedChatCapabilityRegistry(
        providers = providers + (UnifiedChatCapability.MCP_CONNECTOR to UnifiedChatCapabilityProvider { _, _ -> false })
      ).resolve(
        model = model,
        entryHint =
          UnifiedChatEntryHint(
            activateMcpConnectorIds = listOf("ugot_fortune"),
          ),
      )

    assertEquals(setOf(UnifiedChatCapability.TEXT), result.enabledCapabilities)
    assertEquals(emptyList<String>(), result.activeConnectorIds)
  }

  @Test
  fun supportsUnifiedChatCapability_usesExplicitCapabilityPolicy() {
    val textOnlyModel = Model(name = "Gemma 4", displayName = "Gemma 4")
    val multimodalModel =
      Model(
        name = "Gemma 4 multimodal",
        displayName = "Gemma 4 multimodal",
        llmSupportImage = true,
        llmSupportAudio = true,
      )

    assertEquals(true, textOnlyModel.supportsUnifiedChatCapability(UnifiedChatCapability.TEXT))
    assertEquals(true, textOnlyModel.supportsUnifiedChatCapability(UnifiedChatCapability.SKILLS))
    assertEquals(true, textOnlyModel.supportsUnifiedChatCapability(UnifiedChatCapability.MCP_CONNECTOR))
    assertEquals(false, textOnlyModel.supportsUnifiedChatCapability(UnifiedChatCapability.IMAGE))
    assertEquals(false, textOnlyModel.supportsUnifiedChatCapability(UnifiedChatCapability.AUDIO))
    assertEquals(true, multimodalModel.supportsUnifiedChatCapability(UnifiedChatCapability.IMAGE))
    assertEquals(true, multimodalModel.supportsUnifiedChatCapability(UnifiedChatCapability.AUDIO))
  }
}
