/*
 * Copyright 2026 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     https://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package com.ugot.chatkit.mcp.runtime

import android.content.Context

/** Android host contract exposed by a live MCP session to the shared widget renderer. */
interface McpWidgetSessionHost {
  val injectedWidgetHtml: String
  val widgetBaseUrl: String

  fun createJavascriptBridge(context: Context): Any
}
