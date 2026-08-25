package com.google.ai.edge.gallery.ui.common

import java.net.HttpURLConnection
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DownloadAndTryButtonErrorStateTest {
  @Test
  fun createDownloadErrorDialogState_returnsUgotSigninActionForProxy401() {
    val state =
      createDownloadErrorDialogState(
        responseCode = HttpURLConnection.HTTP_UNAUTHORIZED,
        usedUgotProxy = true,
      )

    assertEquals("UGOT sign-in required", state.title)
    assertEquals(
      "Your UGOT session was rejected by the model download proxy. Continue with Google to sign in again and retry the download.",
      state.message,
    )
    assertEquals("Continue with Google", state.confirmLabel)
    assertEquals(DownloadErrorDialogAction.REAUTHENTICATE_UGOT, state.action)
  }

  @Test
  fun createDownloadErrorDialogState_returnsGenericNetworkMessageForTransportFailure() {
    val state = createDownloadErrorDialogState(responseCode = -1, usedUgotProxy = false)

    assertEquals("Unknown network error", state.title)
    assertEquals("Please check your internet connection.", state.message)
    assertEquals("Close", state.confirmLabel)
    assertEquals(DownloadErrorDialogAction.DISMISS, state.action)
  }

  @Test
  fun createDownloadErrorDialogState_attributesProxyServiceFor503() {
    val state =
      createDownloadErrorDialogState(
        responseCode = HttpURLConnection.HTTP_UNAVAILABLE,
        usedUgotProxy = true,
      )

    assertProxyServiceUnavailableDialog(state)
  }

  @Test
  fun createDownloadErrorDialogState_attributesProxyServiceFor502() {
    val state =
      createDownloadErrorDialogState(
        responseCode = HttpURLConnection.HTTP_BAD_GATEWAY,
        usedUgotProxy = true,
      )

    assertProxyServiceUnavailableDialog(state)
  }

  private fun assertProxyServiceUnavailableDialog(state: DownloadErrorDialogState) {
    assertEquals("Download service unavailable", state.title)
    assertFalse(state.message.contains("Please check your internet connection"))
    assertTrue(state.message.contains("UGOT model download proxy"))
    assertEquals("Close", state.confirmLabel)
    assertEquals(DownloadErrorDialogAction.DISMISS, state.action)
  }
}
