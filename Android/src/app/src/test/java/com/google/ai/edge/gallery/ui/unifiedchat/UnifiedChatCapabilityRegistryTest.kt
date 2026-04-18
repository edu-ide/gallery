package com.google.ai.edge.gallery.ui.unifiedchat

import com.google.ai.edge.gallery.data.Model
import org.junit.Assert.assertEquals
import org.junit.Test

class UnifiedChatCapabilityRegistryTest {
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
      UnifiedChatCapabilityRegistry(
        providers =
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
      ).resolve(
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
}
