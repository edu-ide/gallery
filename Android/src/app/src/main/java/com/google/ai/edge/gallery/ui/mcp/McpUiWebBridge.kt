package com.google.ai.edge.gallery.ui.mcp

import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.webkit.JavascriptInterface
import java.util.Locale

internal class McpUiWebBridge(
  private val context: Context,
  private val session: McpUiSession,
) {
  private val mainHandler = Handler(Looper.getMainLooper())

  @JavascriptInterface
  fun callTool(name: String, argsJson: String?): String = session.callToolJson(name, argsJson)

  @JavascriptInterface
  fun getToolOutput(): String = session.getToolOutputJson()

  @JavascriptInterface
  fun getWidgetState(): String = session.getWidgetStateJson()

  @JavascriptInterface
  fun setWidgetState(nextStateJson: String) {
    session.setWidgetStateJson(nextStateJson)
  }

  @JavascriptInterface
  fun getTheme(): String {
    val currentMode = context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK
    return if (currentMode == Configuration.UI_MODE_NIGHT_YES) "dark" else "light"
  }

  @JavascriptInterface
  fun getLocale(): String = Locale.getDefault().toLanguageTag()

  @JavascriptInterface
  fun openExternal(url: String) {
    mainHandler.post {
      runCatching {
        context.startActivity(
          Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        )
      }
    }
  }
}
