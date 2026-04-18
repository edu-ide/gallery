package com.google.ai.edge.gallery.ui.common

import java.net.HttpURLConnection
import org.junit.Assert.assertEquals
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
}
