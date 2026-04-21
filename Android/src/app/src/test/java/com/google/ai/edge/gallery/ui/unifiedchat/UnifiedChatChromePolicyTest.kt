package com.google.ai.edge.gallery.ui.unifiedchat

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class UnifiedChatChromePolicyTest {
  @Test
  fun resolveUnifiedChatChromePolicy_keepsHistoryInTopBarAndRestoresInlineConnectorRow() {
    val policy =
      resolveUnifiedChatChromePolicy(hasVisibleConnectors = true, supportsAudioInput = true)

    assertTrue(policy.showInputHistoryInTopBar)
    assertFalse(policy.showInputHistoryInComposerMenu)
    assertTrue(policy.showInlineConnectorRowAboveComposer)
    assertFalse(policy.showConnectorLauncherInComposer)
  }

  @Test
  fun resolveUnifiedChatChromePolicy_showsInlineConnectorRowOnlyWhenConnectorsExist() {
    val withConnectors =
      resolveUnifiedChatChromePolicy(hasVisibleConnectors = true, supportsAudioInput = false)
    val withoutConnectors =
      resolveUnifiedChatChromePolicy(hasVisibleConnectors = false, supportsAudioInput = false)

    assertTrue(withConnectors.showInlineConnectorRowAboveComposer)
    assertFalse(withConnectors.showConnectorLauncherInComposer)
    assertFalse(withoutConnectors.showInlineConnectorRowAboveComposer)
    assertFalse(withoutConnectors.showConnectorLauncherInComposer)
  }

  @Test
  fun resolveUnifiedChatChromePolicy_showsStandaloneMicButtonWhenAudioInputIsSupported() {
    val withAudio =
      resolveUnifiedChatChromePolicy(hasVisibleConnectors = false, supportsAudioInput = true)
    val withoutAudio =
      resolveUnifiedChatChromePolicy(hasVisibleConnectors = false, supportsAudioInput = false)

    assertTrue(withAudio.showStandaloneAudioRecordButtonInComposer)
    assertFalse(withoutAudio.showStandaloneAudioRecordButtonInComposer)
  }

  @Test
  fun buildConnectorLauncherLabel_appendsActiveConnectorCount() {
    assertEquals("Connectors", buildConnectorLauncherLabel(activeConnectorCount = 0))
    assertEquals("Connectors (1)", buildConnectorLauncherLabel(activeConnectorCount = 1))
    assertEquals("Connectors (3)", buildConnectorLauncherLabel(activeConnectorCount = 3))
  }
}
