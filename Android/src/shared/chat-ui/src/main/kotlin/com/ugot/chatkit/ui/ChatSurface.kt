@file:OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)

/*
 * Copyright 2026 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     https://www.apache.org/licenses/LICENSE-2.0
 */

package com.ugot.chatkit.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp

@Composable
fun ChatSurface(
  state: ChatSurfaceState,
  capabilities: ChatUiCapabilities,
  labels: ChatUiLabels,
  onIntent: (ChatUiIntent) -> Unit,
  modifier: Modifier = Modifier,
  extensionRenderer: @Composable (ChatBlockUi.Extension) -> Unit = {},
) {
  ChatSurfaceScaffold(
    modifier = modifier,
    header = {
      if (capabilities.showTopBar) {
        ChatTopBar(state = state, showProvider = capabilities.showProvider)
      }
      if (capabilities.showModelPicker && state.models.isNotEmpty()) {
        ChatModelPicker(models = state.models, onIntent = onIntent)
      }
      if (capabilities.showConnectors && state.connectors.isNotEmpty()) {
        ChatConnectorRow(connectors = state.connectors, onIntent = onIntent)
      }
    },
    transcript = {
      ChatTranscript(
        messages = state.messages,
        capabilities = capabilities,
        labels = labels,
        onIntent = onIntent,
        extensionRenderer = extensionRenderer,
        modifier = Modifier.fillMaxSize(),
      )
      if (state.restoring) {
        CircularProgressIndicator(modifier = Modifier.align(Alignment.Center))
      }
    },
    activity = { state.turnActivity?.let { activity -> ChatTurnActivity(activity) } },
    composer = {
      ChatComposer(
        state = state.composer,
        capabilities = capabilities,
        labels = labels,
        onIntent = onIntent,
      )
    },
  )

  if (capabilities.showToolApproval) {
    state.pendingPermission?.let { permission ->
      ChatPermissionSurface(permission = permission, labels = labels, onIntent = onIntent)
    }
  }
}

/** Shared small-app shell. Hosts can retain specialized renderers without duplicating layout. */
@Composable
fun ChatSurfaceScaffold(
  transcript: @Composable BoxScope.() -> Unit,
  modifier: Modifier = Modifier,
  header: @Composable () -> Unit = {},
  activity: @Composable () -> Unit = {},
  composer: @Composable () -> Unit,
) {
  Column(modifier = modifier.fillMaxSize()) {
    header()
    Box(modifier = Modifier.weight(1f), content = transcript)
    activity()
    composer()
  }
}

@Composable
private fun ChatTopBar(state: ChatSurfaceState, showProvider: Boolean) {
  Column(modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp)) {
    Text(text = state.title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
    if (showProvider && state.providerLabel.isNotBlank()) {
      Text(
        text = state.providerLabel,
        style = MaterialTheme.typography.labelSmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
      )
    }
  }
}

@Composable
fun ChatTranscript(
  messages: List<ChatMessageUi>,
  capabilities: ChatUiCapabilities,
  labels: ChatUiLabels,
  onIntent: (ChatUiIntent) -> Unit,
  modifier: Modifier = Modifier,
  extensionRenderer: @Composable (ChatBlockUi.Extension) -> Unit = {},
) {
  ChatTimeline(
    items = messages,
    itemKey = { _, message -> message.id },
    modifier = modifier.padding(horizontal = if (capabilities.layout == ChatLayout.COMPACT) 8.dp else 12.dp),
    verticalArrangement = Arrangement.spacedBy(8.dp),
  ) { _, message ->
    ChatMessageRow(
      message = message,
      capabilities = capabilities,
      labels = labels,
      onIntent = onIntent,
      extensionRenderer = extensionRenderer,
    )
  }
}

/**
 * Shared transcript container for hosts with product-specific message bodies.
 *
 * The chat kit owns scrolling and item lifecycle while the host keeps rendering extensions such as
 * camera output, benchmarks, and MCP widgets.
 */
@Composable
fun <T> ChatTimeline(
  items: List<T>,
  modifier: Modifier = Modifier,
  state: LazyListState = rememberLazyListState(),
  verticalArrangement: Arrangement.Vertical = Arrangement.Top,
  itemKey: ((index: Int, item: T) -> Any)? = null,
  itemContent: @Composable (index: Int, item: T) -> Unit,
) {
  LazyColumn(modifier = modifier, state = state, verticalArrangement = verticalArrangement) {
    if (itemKey == null) {
      itemsIndexed(items) { index, item -> itemContent(index, item) }
    } else {
      itemsIndexed(items, key = itemKey) { index, item -> itemContent(index, item) }
    }
  }
}

@Composable
private fun ChatMessageRow(
  message: ChatMessageUi,
  capabilities: ChatUiCapabilities,
  labels: ChatUiLabels,
  onIntent: (ChatUiIntent) -> Unit,
  extensionRenderer: @Composable (ChatBlockUi.Extension) -> Unit,
) {
  val horizontal =
    when (message.role) {
      ChatRole.USER -> Alignment.End
      ChatRole.ASSISTANT -> Alignment.Start
      ChatRole.SYSTEM -> Alignment.CenterHorizontally
    }
  Column(modifier = Modifier.fillMaxWidth(), horizontalAlignment = horizontal) {
    if (capabilities.showSenderLabels && !message.senderLabel.isNullOrBlank()) {
      Text(
        text = message.senderLabel,
        style = MaterialTheme.typography.labelSmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
      )
    }
    Surface(
      shape = RoundedCornerShape(16.dp),
      color =
        when (message.role) {
          ChatRole.USER -> MaterialTheme.colorScheme.primaryContainer
          ChatRole.ASSISTANT -> MaterialTheme.colorScheme.surfaceContainerHigh
          ChatRole.SYSTEM -> MaterialTheme.colorScheme.surfaceContainer
        },
    ) {
      Column(
        modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
      ) {
        message.blocks.forEach { block ->
          when (block) {
            is ChatBlockUi.Text -> Text(block.value, style = MaterialTheme.typography.bodyMedium)
            is ChatBlockUi.Thinking ->
              if (capabilities.showThinking) {
                Text(
                  block.value,
                  style = MaterialTheme.typography.bodySmall,
                  color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
              }
            is ChatBlockUi.Notice ->
              Text(
                block.text,
                color =
                  if (block.level == ChatNoticeLevel.ERROR) MaterialTheme.colorScheme.error
                  else MaterialTheme.colorScheme.onSurfaceVariant,
              )
            is ChatBlockUi.Attachment -> Text(block.attachment.displayName)
            is ChatBlockUi.Widget ->
              if (capabilities.showWidgets) {
                ChatWidgetCard(block.widget, labels, onIntent)
              }
            is ChatBlockUi.Extension -> extensionRenderer(block)
          }
        }
      }
    }
    if (capabilities.showTimestamps && !message.timestampLabel.isNullOrBlank()) {
      Text(
        text = message.timestampLabel,
        style = MaterialTheme.typography.labelSmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
      )
    }
  }
}

@Composable
fun ChatComposer(
  state: ChatComposerUiState,
  capabilities: ChatUiCapabilities,
  labels: ChatUiLabels,
  onIntent: (ChatUiIntent) -> Unit,
  modifier: Modifier = Modifier,
) {
  Column(modifier = modifier.fillMaxWidth().padding(8.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
    if (state.attachments.isNotEmpty()) {
      FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        state.attachments.forEach { attachment ->
          FilterChip(
            selected = true,
            onClick = { onIntent(ChatUiIntent.RemoveAttachment(attachment.id)) },
            label = { Text("${attachment.displayName} ×") },
          )
        }
      }
    }
    Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
      OutlinedTextField(
        value = state.draft,
        onValueChange = { onIntent(ChatUiIntent.DraftChanged(it)) },
        enabled = state.enabled,
        placeholder = { Text(labels.inputPlaceholder) },
        minLines = 1,
        maxLines = capabilities.composerMaxLines,
        modifier = Modifier.weight(1f).heightIn(min = 52.dp),
      )
      if (state.inProgress && capabilities.showStopButton) {
        OutlinedButton(onClick = { onIntent(ChatUiIntent.StopClicked) }) { Text(labels.stop) }
      } else {
        Button(onClick = { onIntent(ChatUiIntent.SendClicked) }, enabled = state.canSend()) {
          Text(labels.send)
        }
      }
    }
    if (capabilities.allowImages || capabilities.allowAudio) {
      Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        if (capabilities.allowImages) {
          TextButton(onClick = { onIntent(ChatUiIntent.AddAttachmentClicked(ChatAttachmentType.IMAGE)) }) {
            Text(labels.addImage)
          }
        }
        if (capabilities.allowAudio) {
          TextButton(onClick = { onIntent(ChatUiIntent.AddAttachmentClicked(ChatAttachmentType.AUDIO)) }) {
            Text(labels.addAudio)
          }
        }
      }
    }
  }
}

@Composable
private fun ChatModelPicker(models: List<ChatModelUi>, onIntent: (ChatUiIntent) -> Unit) {
  FlowRow(
    modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp),
    horizontalArrangement = Arrangement.spacedBy(8.dp),
  ) {
    models.forEach { model ->
      FilterChip(
        selected = model.selected,
        enabled = model.enabled,
        onClick = { onIntent(ChatUiIntent.ModelSelected(model.id)) },
        label = { Text(model.statusLabel?.let { "${model.label} · $it" } ?: model.label) },
      )
    }
  }
}

@Composable
private fun ChatConnectorRow(connectors: List<ChatConnectorUi>, onIntent: (ChatUiIntent) -> Unit) {
  FlowRow(
    modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp),
    horizontalArrangement = Arrangement.spacedBy(8.dp),
  ) {
    connectors.forEach { connector ->
      FilterChip(
        selected = connector.active,
        enabled = connector.enabled,
        onClick = { onIntent(ChatUiIntent.ConnectorToggled(connector.id)) },
        label = { Text(connector.label) },
      )
    }
  }
}

@Composable
private fun ChatWidgetCard(
  widget: ChatWidgetUiState,
  labels: ChatUiLabels,
  onIntent: (ChatUiIntent) -> Unit,
) {
  Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
    Text(widget.title, fontWeight = FontWeight.SemiBold)
    Text(widget.summary, style = MaterialTheme.typography.bodySmall)
    TextButton(onClick = { onIntent(ChatUiIntent.OpenWidget(widget.messageId, true)) }) {
      Text(labels.expand)
    }
  }
}

@Composable
private fun ChatPermissionSurface(
  permission: ChatPermissionUiState,
  labels: ChatUiLabels,
  onIntent: (ChatUiIntent) -> Unit,
) {
  AlertDialog(
    onDismissRequest = {
      onIntent(ChatUiIntent.ResolvePermission(permission.requestId, ChatPermissionDecision.DENY))
    },
    title = { Text(permission.title) },
    text = {
      Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(permission.rationale)
        permission.riskLabel?.let { Text(it, color = MaterialTheme.colorScheme.error) }
      }
    },
    confirmButton = {
      TextButton(
        onClick = {
          onIntent(
            ChatUiIntent.ResolvePermission(
              permission.requestId,
              ChatPermissionDecision.ALLOW_ONCE,
            )
          )
        }
      ) {
        Text(labels.allowOnce)
      }
    },
    dismissButton = {
      TextButton(
        onClick = {
          onIntent(ChatUiIntent.ResolvePermission(permission.requestId, ChatPermissionDecision.DENY))
        }
      ) {
        Text(labels.deny)
      }
    },
  )
}

@Composable
fun ChatTurnActivity(activity: ChatTurnActivityUiState, modifier: Modifier = Modifier) {
  Surface(
    modifier = modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp),
    shape = RoundedCornerShape(16.dp),
    color = MaterialTheme.colorScheme.surfaceContainerHigh,
  ) {
    Row(
      modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 10.dp),
      verticalAlignment = Alignment.CenterVertically,
    ) {
      if (activity.showsProgress) {
        CircularProgressIndicator(modifier = Modifier.width(16.dp), strokeWidth = 2.dp)
        Spacer(Modifier.width(12.dp))
      }
      Column {
        Text(activity.title, style = MaterialTheme.typography.labelLarge)
        Text(
          activity.detail,
          style = MaterialTheme.typography.bodySmall,
          color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
      }
    }
  }
}
