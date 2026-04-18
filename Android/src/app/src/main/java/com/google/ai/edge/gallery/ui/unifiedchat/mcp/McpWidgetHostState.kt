/*
 * Copyright 2026 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package com.google.ai.edge.gallery.ui.unifiedchat.mcp

import android.content.Context

enum class McpWidgetDisplayMode {
  INLINE,
  FULLSCREEN,
}

interface McpWidgetSessionHost {
  val injectedWidgetHtml: String
  val widgetBaseUrl: String

  fun createJavascriptBridge(context: Context): Any
}

data class McpWidgetHostState(
  val activeSnapshot: McpWidgetSnapshot? = null,
  val displayMode: McpWidgetDisplayMode = McpWidgetDisplayMode.INLINE,
) {
  fun activate(snapshot: McpWidgetSnapshot, fullscreen: Boolean): McpWidgetHostState =
    copy(
      activeSnapshot = snapshot,
      displayMode =
        if (fullscreen) {
          McpWidgetDisplayMode.FULLSCREEN
        } else {
          McpWidgetDisplayMode.INLINE
        },
    )

  fun close(): McpWidgetHostState =
    copy(
      activeSnapshot = null,
      displayMode = McpWidgetDisplayMode.INLINE,
    )
}
