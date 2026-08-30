/*
 * Copyright 2026 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     https://www.apache.org/licenses/LICENSE-2.0
 */

package com.ugot.chatkit.mcp.ui

import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.ViewConfiguration
import android.view.inputmethod.InputMethodManager
import android.webkit.JavascriptInterface
import android.webkit.PermissionRequest
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import com.ugot.chatkit.ui.LocalChatTranscriptVerticalDragHandler
import kotlin.math.abs

enum class McpWidgetScrollPolicy {
  WEBVIEW_INTERNAL,
  PARENT_VERTICAL_HANDOFF,
}

/** Hardened WebView used by every Android host of an MCP App widget. */
@Composable
fun McpWidgetWebView(
  initialHtml: String,
  htmlBaseUrl: String,
  modifier: Modifier = Modifier,
  scrollPolicy: McpWidgetScrollPolicy = McpWidgetScrollPolicy.WEBVIEW_INTERNAL,
  dismissKeyboardOnLoad: Boolean = false,
  fitContentHeight: Boolean = false,
  onContentHeightChanged: (Float) -> Unit = {},
  onWebViewCreated: (WebView) -> Unit,
) {
  val context = LocalContext.current
  val transcriptVerticalDragHandler = LocalChatTranscriptVerticalDragHandler.current
  val webViewClient = remember(context, dismissKeyboardOnLoad, fitContentHeight) {
    object : WebViewClient() {
      override fun shouldOverrideUrlLoading(view: WebView?, request: WebResourceRequest?): Boolean {
        val uri = request?.url ?: return true
        if (!request.isForMainFrame || uri.scheme == "about") return false
        if (uri.scheme.equals("https", ignoreCase = true)) {
          context.startActivity(
            Intent(Intent.ACTION_VIEW, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
          )
        }
        return true
      }

      override fun onPageFinished(view: WebView?, url: String?) {
        super.onPageFinished(view, url)
        if (dismissKeyboardOnLoad) {
          view?.clearFocus()
          context
            .getSystemService(InputMethodManager::class.java)
            ?.hideSoftInputFromWindow(view?.windowToken, 0)
        }
        if (fitContentHeight) {
          view?.evaluateJavascript(FIT_CONTENT_HEIGHT_SCRIPT, null)
        }
      }
    }
  }

  AndroidView(
    modifier = modifier,
    factory = { webContext ->
      val webView = WebView(webContext).apply {
        layoutParams =
          ViewGroup.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.MATCH_PARENT,
          )
        settings.apply {
          javaScriptEnabled = true
          domStorageEnabled = true
          allowFileAccess = false
          allowContentAccess = false
          allowFileAccessFromFileURLs = false
          allowUniversalAccessFromFileURLs = false
          mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
          mediaPlaybackRequiresUserGesture = true
          safeBrowsingEnabled = true
        }
        if (fitContentHeight) {
          isHorizontalScrollBarEnabled = false
          isVerticalScrollBarEnabled = false
          overScrollMode = View.OVER_SCROLL_NEVER
          addJavascriptInterface(
            McpContentHeightBridge(onContentHeightChanged),
            "McpLayoutHost",
          )
        }
        webChromeClient =
          object : WebChromeClient() {
            override fun onPermissionRequest(request: PermissionRequest?) {
              request?.deny()
            }
          }
        this.webViewClient = webViewClient
        onWebViewCreated(this)
        loadDataWithBaseURL(htmlBaseUrl, initialHtml, "text/html", "UTF-8", null)
      }
      McpWebViewContainer(
          context = webContext,
          handOffVerticalDrag =
            scrollPolicy == McpWidgetScrollPolicy.PARENT_VERTICAL_HANDOFF &&
              transcriptVerticalDragHandler != null,
          onVerticalDragStarted = { transcriptVerticalDragHandler?.onDragStarted() },
          onVerticalDrag = { deltaY -> transcriptVerticalDragHandler?.onDrag(deltaY) },
          onVerticalDragStopped = { cancelled ->
            transcriptVerticalDragHandler?.onDragStopped(cancelled)
          },
        )
        .apply { addView(webView) }
    },
    onRelease = { container ->
      container.cancelActiveDrag()
      val webView = container.webView
      webView.removeJavascriptInterface("McpUiHost")
      webView.removeJavascriptInterface("McpLayoutHost")
      webView.stopLoading()
      webView.loadUrl("about:blank")
      webView.clearHistory()
      container.removeView(webView)
      webView.destroy()
    },
  )
}

internal class McpVerticalDragArbiter(private val touchSlop: Float) {
  private var downX = 0f
  private var downY = 0f
  private var staysInWebView = false

  fun onDown(x: Float, y: Float) {
    downX = x
    downY = y
    staysInWebView = false
  }

  fun shouldStartHandoff(x: Float, y: Float, pointerCount: Int): Boolean {
    if (pointerCount != 1) {
      staysInWebView = true
      return false
    }
    if (staysInWebView) return false

    val distanceX = abs(x - downX)
    val distanceY = abs(y - downY)
    if (distanceX <= touchSlop && distanceY <= touchSlop) return false
    if (distanceX >= distanceY) {
      staysInWebView = true
      return false
    }
    return true
  }
}

private class McpWebViewContainer(
  context: Context,
  private val handOffVerticalDrag: Boolean,
  private val onVerticalDragStarted: () -> Unit,
  private val onVerticalDrag: (Float) -> Unit,
  private val onVerticalDragStopped: (Boolean) -> Unit,
) : FrameLayout(context) {
  val webView: WebView
    get() = getChildAt(0) as WebView

  private val dragArbiter =
    McpVerticalDragArbiter(ViewConfiguration.get(context).scaledTouchSlop.toFloat())
  private var handingOff = false
  private var consumeUntilGestureEnd = false
  private var lastY = 0f

  override fun onInterceptTouchEvent(event: MotionEvent): Boolean {
    if (!handOffVerticalDrag) return super.onInterceptTouchEvent(event)

    when (event.actionMasked) {
      MotionEvent.ACTION_DOWN -> {
        if (handingOff) finishGesture(cancelled = true)
        handingOff = false
        consumeUntilGestureEnd = false
        lastY = event.rawY
        dragArbiter.onDown(event.rawX, event.rawY)
        parent?.requestDisallowInterceptTouchEvent(true)
      }
      MotionEvent.ACTION_MOVE -> {
        if (!handingOff &&
          dragArbiter.shouldStartHandoff(event.rawX, event.rawY, event.pointerCount)
        ) {
          handingOff = true
          onVerticalDragStarted()
        }
        if (handingOff) return true
      }
      MotionEvent.ACTION_UP -> finishGesture(cancelled = false)
      MotionEvent.ACTION_CANCEL -> finishGesture(cancelled = true)
    }
    return false
  }

  override fun onTouchEvent(event: MotionEvent): Boolean {
    if (!handingOff) {
      if (consumeUntilGestureEnd) {
        if (event.actionMasked == MotionEvent.ACTION_UP ||
          event.actionMasked == MotionEvent.ACTION_CANCEL
        ) {
          consumeUntilGestureEnd = false
          parent?.requestDisallowInterceptTouchEvent(false)
        }
        return true
      }
      return super.onTouchEvent(event)
    }

    when (event.actionMasked) {
      MotionEvent.ACTION_MOVE -> {
        if (event.pointerCount != 1) {
          consumeUntilGestureEnd = true
          finishGesture(cancelled = true)
          return true
        }
        // The LazyColumn moves this container while the gesture is active. Local event.y therefore
        // changes with both the pointer and the container, feeding the list's own movement back into
        // the next delta. rawY stays in screen coordinates and tracks only the physical gesture.
        val deltaY = event.rawY - lastY
        lastY = event.rawY
        if (deltaY != 0f) onVerticalDrag(deltaY)
      }
      MotionEvent.ACTION_POINTER_DOWN -> {
        consumeUntilGestureEnd = true
        finishGesture(cancelled = true)
      }
      MotionEvent.ACTION_UP -> finishGesture(cancelled = false)
      MotionEvent.ACTION_CANCEL -> finishGesture(cancelled = true)
    }
    return true
  }

  fun cancelActiveDrag() {
    finishGesture(cancelled = true)
  }

  override fun onDetachedFromWindow() {
    cancelActiveDrag()
    super.onDetachedFromWindow()
  }

  private fun finishGesture(cancelled: Boolean) {
    if (handingOff) onVerticalDragStopped(cancelled)
    handingOff = false
    parent?.requestDisallowInterceptTouchEvent(false)
  }
}

private class McpContentHeightBridge(private val onHeightChanged: (Float) -> Unit) {
  private val mainHandler = Handler(Looper.getMainLooper())

  @JavascriptInterface
  fun reportContentHeight(heightCssPixels: Double) {
    if (!heightCssPixels.isFinite() || heightCssPixels <= 0.0) return
    mainHandler.post { onHeightChanged(heightCssPixels.toFloat()) }
  }
}

private val FIT_CONTENT_HEIGHT_SCRIPT =
  """
  (function() {
    let reportScheduled = false;
    let lastReportedHeight = 0;
    const reportHeight = () => {
      reportScheduled = false;
      const root = document.documentElement;
      const body = document.body;
      const scrolling = document.scrollingElement || root;
      const height = Math.ceil(Math.max(
        scrolling ? scrolling.scrollHeight : 0,
        root ? root.scrollHeight : 0,
        body ? body.scrollHeight : 0,
        body ? body.offsetHeight : 0
      ));
      if (height > 0 && height !== lastReportedHeight && window.McpLayoutHost) {
        lastReportedHeight = height;
        window.McpLayoutHost.reportContentHeight(height);
      }
    };
    const scheduleHeightReport = () => {
      if (reportScheduled) return;
      reportScheduled = true;
      requestAnimationFrame(reportHeight);
    };

    if (!window.__ugotFitContentInstalled) {
      window.__ugotFitContentInstalled = true;
      const style = document.createElement('style');
      style.id = 'ugot-mcp-fit-content';
      style.textContent = 'html,body{overflow-x:hidden!important;overflow-y:hidden!important;}';
      document.head.appendChild(style);

      if (window.ResizeObserver) {
        const resizeObserver = new ResizeObserver(scheduleHeightReport);
        resizeObserver.observe(document.documentElement);
        if (document.body) resizeObserver.observe(document.body);
        window.__ugotFitResizeObserver = resizeObserver;
      }
      const mutationObserver = new MutationObserver(scheduleHeightReport);
      mutationObserver.observe(document.documentElement, {
        childList: true,
        subtree: true,
        characterData: true,
      });
      window.__ugotFitMutationObserver = mutationObserver;
    }

    scheduleHeightReport();
  })();
  """.trimIndent()
