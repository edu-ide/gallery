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

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.google.ai.edge.gallery.ui.unifiedchat.mcp.McpWidgetSnapshot
import com.ugot.chatkit.mcp.runtime.McpWidgetSessionHost
import com.ugot.chatkit.ui.ChatBlockUi
import com.ugot.chatkit.ui.ChatSurfaceState
import com.ugot.chatkit.ui.ChatUiCapabilities
import com.ugot.chatkit.ui.ChatUiIntent
import com.ugot.chatkit.ui.ChatUiLabels
import com.ugot.chatkit.ui.ChatWidgetUiState
import com.ugot.chatkit.ui.UgotChatExperience

data class McpWidgetUiLabels(
  val widget: String = "MCP Widget",
  val toolDetails: String = "Tool details",
  val hideToolDetails: String = "Hide tool details",
  val connector: String = "Connector",
  val title: String = "Title",
  val summary: String = "Summary",
)

/** Canonical UGOT chat surface with the shared MCP App renderer installed. */
@Composable
fun McpEnabledUgotChatExperience(
  state: ChatSurfaceState,
  capabilities: ChatUiCapabilities,
  labels: ChatUiLabels,
  session: McpWidgetSessionHost?,
  onIntent: (ChatUiIntent) -> Unit,
  modifier: Modifier = Modifier,
  mcpLabels: McpWidgetUiLabels = McpWidgetUiLabels(),
  extensionRenderer: @Composable (ChatBlockUi.Extension) -> Unit = {},
) {
  UgotChatExperience(
    state = state,
    capabilities = capabilities,
    labels = labels,
    onIntent = onIntent,
    modifier = modifier,
    extensionRenderer = extensionRenderer,
    widgetRenderer = { widget, currentLabels, currentOnIntent ->
      var collapsed by rememberSaveable(widget.messageId) { mutableStateOf(false) }
      if (session == null) {
        McpWidgetFallback(
          widget = widget,
          actionLabel = currentLabels.fullscreen,
          onExpand = { currentOnIntent(ChatUiIntent.OpenWidget(widget.messageId, true)) },
        )
      } else if (collapsed) {
        McpWidgetFallback(
          widget = widget,
          actionLabel = currentLabels.expand,
          onExpand = { collapsed = false },
        )
      } else {
        McpWidgetInlinePanel(
          snapshot = widget.toSnapshot(),
          session = session,
          labels = mcpLabels,
          openFullscreenLabel = currentLabels.fullscreen,
          closeLabel = currentLabels.close,
          onOpenFullscreen = {
            currentOnIntent(ChatUiIntent.OpenWidget(widget.messageId, true))
          },
          onClose = { collapsed = true },
        )
      }
    },
    widgetOverlayRenderer = { widget, currentLabels, currentOnIntent ->
      if (session == null) {
        McpWidgetFallback(
          widget = widget,
          actionLabel = currentLabels.close,
          onExpand = { currentOnIntent(ChatUiIntent.CloseWidget) },
        )
      } else {
        McpWidgetFullscreenOverlay(
          snapshot = widget.toSnapshot(),
          session = session,
          onClose = { currentOnIntent(ChatUiIntent.CloseWidget) },
        )
      }
    },
  )
}

@Composable
private fun McpWidgetFallback(
  widget: ChatWidgetUiState,
  actionLabel: String,
  onExpand: () -> Unit,
) {
  Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
    Text(widget.title, style = MaterialTheme.typography.titleSmall)
    if (widget.summary.isNotBlank()) {
      Text(
        text = widget.summary,
        maxLines = 3,
        overflow = TextOverflow.Ellipsis,
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
      )
    }
    TextButton(onClick = onExpand) {
      Text(actionLabel)
    }
  }
}

private fun ChatWidgetUiState.toSnapshot(): McpWidgetSnapshot =
  McpWidgetSnapshot(
    connectorId = connectorId,
    title = title,
    summary = summary,
    widgetStateJson = stateJson,
  )
