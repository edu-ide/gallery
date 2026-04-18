package com.google.ai.edge.gallery.ui.unifiedchat

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class UnifiedChatChromePolicyTest {
  @Test
  fun resolveUnifiedChatChromePolicy_movesHistoryToTopBarAndRemovesComposerHistoryEntry() {
    val policy = resolveUnifiedChatChromePolicy(hasVisibleConnectors = true)

    assertTrue(policy.showInputHistoryInTopBar)
    assertFalse(policy.showInputHistoryInComposerMenu)
    assertFalse(policy.showInlineConnectorRowAboveComposer)
  }

  @Test
  fun resolveUnifiedChatChromePolicy_showsComposerConnectorLauncherOnlyWhenConnectorsExist() {
    val withConnectors = resolveUnifiedChatChromePolicy(hasVisibleConnectors = true)
    val withoutConnectors = resolveUnifiedChatChromePolicy(hasVisibleConnectors = false)

    assertTrue(withConnectors.showConnectorLauncherInComposer)
    assertFalse(withoutConnectors.showConnectorLauncherInComposer)
  }

  @Test
  fun buildConnectorLauncherLabel_appendsActiveConnectorCount() {
    assertEquals("Connectors", buildConnectorLauncherLabel(activeConnectorCount = 0))
    assertEquals("Connectors (1)", buildConnectorLauncherLabel(activeConnectorCount = 1))
    assertEquals("Connectors (3)", buildConnectorLauncherLabel(activeConnectorCount = 3))
  }
}
