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

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material3.Card
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.google.ai.edge.gallery.ui.common.GalleryWebView
import org.json.JSONObject

@Composable
fun McpWidgetInlinePanel(
  snapshot: McpWidgetSnapshot,
  session: McpWidgetSessionHost,
  onClose: () -> Unit,
  modifier: Modifier = Modifier,
) {
  val context = LocalContext.current
  val bridge = remember(session, context) { session.createJavascriptBridge(context) }
  val toolName = remember(snapshot.widgetStateJson, snapshot.title) { snapshot.toolNameForDisplay() }
  var showToolDetails by remember(snapshot.widgetStateJson) { mutableStateOf(false) }

  Card(modifier = modifier.fillMaxWidth()) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
      Row(
        modifier = Modifier.fillMaxWidth().padding(start = 16.dp, top = 16.dp, end = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
      ) {
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
          Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
          ) {
            Text(
              text = "MCP Widget",
              style = MaterialTheme.typography.labelSmall,
              color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Surface(
              color = MaterialTheme.colorScheme.primary.copy(alpha = 0.12f),
              shape = MaterialTheme.shapes.small,
            ) {
              Text(
                text = toolName,
                modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp),
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.primary,
              )
            }
          }
          TextButton(onClick = { showToolDetails = !showToolDetails }) {
            Text(if (showToolDetails) "Hide tool details" else "Tool details")
          }
          if (showToolDetails) {
            Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
              ToolDetailRow(label = "Connector", value = snapshot.connectorId)
              ToolDetailRow(label = "Title", value = snapshot.title)
              if (snapshot.summary.isNotBlank()) {
                ToolDetailRow(label = "Summary", value = snapshot.summary)
              }
            }
          }
        }
        IconButton(onClick = onClose) {
          Icon(Icons.Rounded.Close, contentDescription = null)
        }
      }

      GalleryWebView(
        modifier = Modifier.fillMaxWidth().height(320.dp),
        initialHtml = session.injectedWidgetHtml,
        htmlBaseUrl = session.widgetBaseUrl,
        preventParentScrolling = true,
        allowRequestPermission = true,
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
