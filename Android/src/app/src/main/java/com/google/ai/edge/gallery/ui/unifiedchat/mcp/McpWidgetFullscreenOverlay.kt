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

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.key
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.google.ai.edge.gallery.R
import com.google.ai.edge.gallery.ui.common.GalleryWebView

@Composable
fun McpWidgetFullscreenOverlay(
  session: McpWidgetSessionHost,
  snapshot: McpWidgetSnapshot,
  onClose: () -> Unit,
  modifier: Modifier = Modifier,
) {
  val context = LocalContext.current
  val bridge = remember(session, context) { session.createJavascriptBridge(context) }

  BackHandler(onBack = onClose)

  Box(
    modifier =
      modifier
        .fillMaxSize()
        .background(MaterialTheme.colorScheme.surface)
        .systemBarsPadding()
  ) {
    // Keep fullscreen rendering scoped to the live session. Snapshot restore can layer in later.
    key(session, snapshot) {
      GalleryWebView(
        modifier = Modifier.fillMaxSize(),
        initialHtml = session.injectedWidgetHtml,
        htmlBaseUrl = session.widgetBaseUrl,
        preventParentScrolling = true,
        allowRequestPermission = true,
        onWebViewCreated = { webView ->
          webView.addJavascriptInterface(bridge, "McpUiHost")
        },
      )
    }

    Row(
      modifier =
        Modifier
          .align(Alignment.TopStart)
          .statusBarsPadding()
          .padding(horizontal = 16.dp, vertical = 12.dp),
      verticalAlignment = Alignment.CenterVertically,
    ) {
      Text(
        text = snapshot.title,
        style = MaterialTheme.typography.titleMedium,
        color = MaterialTheme.colorScheme.onSurface,
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
        modifier = Modifier.weight(1f, fill = false),
      )
    }

    IconButton(
      onClick = onClose,
      colors =
        IconButtonDefaults.iconButtonColors(
          containerColor = MaterialTheme.colorScheme.surfaceVariant
        ),
      modifier =
        Modifier
          .align(Alignment.TopEnd)
          .statusBarsPadding()
          .padding(horizontal = 16.dp, vertical = 12.dp),
    ) {
      Icon(
        imageVector = Icons.Rounded.Close,
        contentDescription = stringResource(R.string.cd_close_icon),
        tint = MaterialTheme.colorScheme.onSurfaceVariant,
      )
    }
  }
}
