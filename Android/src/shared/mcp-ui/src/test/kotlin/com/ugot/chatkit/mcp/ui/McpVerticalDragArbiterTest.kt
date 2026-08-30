package com.ugot.chatkit.mcp.ui

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class McpVerticalDragArbiterTest {
  @Test
  fun `movement below touch slop stays in WebView`() {
    val arbiter = McpVerticalDragArbiter(touchSlop = 10f)

    arbiter.onDown(x = 0f, y = 0f)

    assertFalse(arbiter.shouldStartHandoff(x = 3f, y = 9f, pointerCount = 1))
  }

  @Test
  fun `vertical dominant drag hands off to transcript`() {
    val arbiter = McpVerticalDragArbiter(touchSlop = 10f)

    arbiter.onDown(x = 0f, y = 0f)

    assertTrue(arbiter.shouldStartHandoff(x = 2f, y = 12f, pointerCount = 1))
  }

  @Test
  fun `horizontal drag remains owned by WebView for the whole gesture`() {
    val arbiter = McpVerticalDragArbiter(touchSlop = 10f)

    arbiter.onDown(x = 0f, y = 0f)

    assertFalse(arbiter.shouldStartHandoff(x = 12f, y = 2f, pointerCount = 1))
    assertFalse(arbiter.shouldStartHandoff(x = 12f, y = 30f, pointerCount = 1))
  }

  @Test
  fun `multi-touch remains owned by WebView`() {
    val arbiter = McpVerticalDragArbiter(touchSlop = 10f)

    arbiter.onDown(x = 0f, y = 0f)

    assertFalse(arbiter.shouldStartHandoff(x = 0f, y = 12f, pointerCount = 2))
    assertFalse(arbiter.shouldStartHandoff(x = 0f, y = 30f, pointerCount = 1))
  }

  @Test
  fun `new touch resets a previous WebView-owned gesture`() {
    val arbiter = McpVerticalDragArbiter(touchSlop = 10f)

    arbiter.onDown(x = 0f, y = 0f)
    assertFalse(arbiter.shouldStartHandoff(x = 12f, y = 2f, pointerCount = 1))

    arbiter.onDown(x = 0f, y = 0f)
    assertTrue(arbiter.shouldStartHandoff(x = 2f, y = 12f, pointerCount = 1))
  }
}
