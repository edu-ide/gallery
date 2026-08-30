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

package com.ugot.chatkit.mcp.ui

import android.annotation.SuppressLint
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Fullscreen
import androidx.compose.material3.Card
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.google.ai.edge.gallery.ui.unifiedchat.mcp.McpWidgetSnapshot
import com.ugot.chatkit.mcp.runtime.McpWidgetSessionHost
import org.json.JSONObject

@SuppressLint("JavascriptInterface")
@Composable
fun McpWidgetInlinePanel(
  snapshot: McpWidgetSnapshot,
  session: McpWidgetSessionHost,
  labels: McpWidgetUiLabels,
  openFullscreenLabel: String,
  closeLabel: String,
  onOpenFullscreen: () -> Unit,
  onClose: () -> Unit,
  modifier: Modifier = Modifier,
) {
  val context = LocalContext.current
  val bridge = remember(session, context) { session.createJavascriptBridge(context) }
  val toolName = remember(snapshot.widgetStateJson, snapshot.title) { snapshot.toolNameForDisplay() }
  var showToolDetails by remember(snapshot.widgetStateJson) { mutableStateOf(false) }
  var contentHeightDp by remember(snapshot.widgetStateJson) { mutableFloatStateOf(320f) }

  Card(modifier = modifier.fillMaxWidth()) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
      Row(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
      ) {
        Surface(
          modifier = Modifier.weight(1f),
          color = MaterialTheme.colorScheme.primary.copy(alpha = 0.12f),
          shape = MaterialTheme.shapes.small,
        ) {
          Text(
            text = "${labels.widget} · $toolName",
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 6.dp),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.primary,
          )
        }
        TextButton(
          onClick = { showToolDetails = !showToolDetails },
          contentPadding = PaddingValues(horizontal = 6.dp, vertical = 0.dp),
        ) {
          Text(
            text = if (showToolDetails) labels.hideToolDetails else labels.toolDetails,
            maxLines = 1,
            style = MaterialTheme.typography.labelSmall,
          )
        }
        IconButton(onClick = onOpenFullscreen, modifier = Modifier.size(48.dp)) {
          Icon(Icons.Rounded.Fullscreen, contentDescription = openFullscreenLabel)
        }
        IconButton(onClick = onClose, modifier = Modifier.size(48.dp)) {
          Icon(Icons.Rounded.Close, contentDescription = closeLabel)
        }
      }
      if (showToolDetails) {
        Column(
          modifier = Modifier.padding(start = 12.dp, end = 12.dp, bottom = 8.dp),
          verticalArrangement = Arrangement.spacedBy(3.dp),
        ) {
          ToolDetailRow(label = labels.connector, value = snapshot.connectorId)
          ToolDetailRow(label = labels.title, value = snapshot.title)
          if (snapshot.summary.isNotBlank()) {
            ToolDetailRow(label = labels.summary, value = snapshot.summary)
          }
        }
      }

      McpWidgetWebView(
        modifier = Modifier.fillMaxWidth().height(contentHeightDp.dp),
        initialHtml = session.injectedWidgetHtml,
        htmlBaseUrl = session.widgetBaseUrl,
        scrollPolicy = McpWidgetScrollPolicy.PARENT_VERTICAL_HANDOFF,
        fitContentHeight = true,
        onContentHeightChanged = { measuredHeight ->
          contentHeightDp = measuredHeight.coerceIn(320f, 12_000f)
        },
        onWebViewCreated = { webView ->
          webView.addJavascriptInterface(bridge, "McpUiHost")
        },
      )
    }
  }
}

@Composable
private fun ToolDetailRow(label: String, value: String) {
  Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
    Text(
      text = label,
      style = MaterialTheme.typography.labelSmall,
      color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
    Text(
      text = value,
      style = MaterialTheme.typography.bodySmall,
      color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
  }
}

private fun McpWidgetSnapshot.toolNameForDisplay(): String =
  runCatching {
      JSONObject(widgetStateJson)
        .optString("toolName")
        .trim()
        .takeIf { it.isNotEmpty() }
    }
    .getOrNull()
    ?: title
