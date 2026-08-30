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

import android.view.Choreographer
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.automirrored.rounded.Send
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.rounded.ArrowDropDown
import androidx.compose.material.icons.rounded.History
import androidx.compose.material.icons.rounded.MapsUgc
import androidx.compose.material.icons.rounded.Stop
import androidx.compose.material.icons.rounded.Tune
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedIconButton
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.ProvideTextStyle
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.halilibo.richtext.commonmark.Markdown
import com.halilibo.richtext.ui.material3.RichText

/**
 * Lets an embedded native view participate in the transcript's active user drag without owning the
 * list state. The transcript remains the only scroll owner; widget hosts only report pointer motion.
 */
interface ChatTranscriptVerticalDragHandler {
  fun onDragStarted()

  fun onDrag(deltaY: Float)

  fun onDragStopped(cancelled: Boolean)
}

val LocalChatTranscriptVerticalDragHandler =
  staticCompositionLocalOf<ChatTranscriptVerticalDragHandler?> { null }

private class LazyListVerticalDragHandler(
  private val listState: LazyListState,
) : ChatTranscriptVerticalDragHandler, Choreographer.FrameCallback {
  private val choreographer = Choreographer.getInstance()
  private var pendingScrollDelta = 0f
  private var frameScheduled = false

  override fun onDragStarted() = Unit

  override fun onDrag(deltaY: Float) {
    if (deltaY != 0f) {
      pendingScrollDelta -= deltaY
      if (!frameScheduled) {
        frameScheduled = true
        choreographer.postFrameCallback(this)
      }
    }
  }

  override fun onDragStopped(cancelled: Boolean) {
    if (cancelled) pendingScrollDelta = 0f
  }

  override fun doFrame(frameTimeNanos: Long) {
    frameScheduled = false
    val delta = pendingScrollDelta
    pendingScrollDelta = 0f
    if (delta != 0f) {
      // The native container already owns this gesture. Coalesce input to one list mutation per
      // display frame so a large WebView is never remeasured repeatedly inside the same vsync.
      listState.dispatchRawDelta(delta)
    }
  }

  fun dispose() {
    if (frameScheduled) choreographer.removeFrameCallback(this)
    frameScheduled = false
    pendingScrollDelta = 0f
  }
}

@Composable
fun UgotChatExperience(
  state: ChatSurfaceState,
  capabilities: ChatUiCapabilities,
  labels: ChatUiLabels,
  onIntent: (ChatUiIntent) -> Unit,
  modifier: Modifier = Modifier,
  extensionRenderer: @Composable (ChatBlockUi.Extension) -> Unit = {},
  widgetRenderer: @Composable (ChatWidgetUiState, ChatUiLabels, (ChatUiIntent) -> Unit) -> Unit =
    { widget, currentLabels, currentOnIntent ->
      ChatWidgetCard(widget, currentLabels, currentOnIntent)
    },
  widgetOverlayRenderer: @Composable (ChatWidgetUiState, ChatUiLabels, (ChatUiIntent) -> Unit) -> Unit =
    { widget, currentLabels, currentOnIntent ->
      UgotChatWidgetOverlay(widget, currentLabels, currentOnIntent)
    },
) {
  UgotChatExperienceScaffold(
    modifier = modifier,
    header = {
      if (capabilities.showTopBar) {
        UgotChatTopBar(
          state = state,
          capabilities = capabilities,
          labels = labels,
          onIntent = onIntent,
        )
      }
      if (capabilities.showConnectors && state.connectors.isNotEmpty()) {
        ChatConnectorRow(connectors = state.connectors, onIntent = onIntent)
      }
    },
    transcript = {
      if (state.messages.isEmpty() && !state.restoring && state.emptyState != null) {
        UgotChatEmptyState(state.emptyState, onIntent, modifier = Modifier.fillMaxSize())
      } else {
        ChatTranscript(
          messages = state.messages,
          capabilities = capabilities,
          labels = labels,
          onIntent = onIntent,
          extensionRenderer = extensionRenderer,
          widgetRenderer = widgetRenderer,
          modifier = Modifier.fillMaxSize(),
        )
      }
      if (state.restoring) {
        CircularProgressIndicator(modifier = Modifier.align(Alignment.Center))
      }
    },
    activity = {
      state.error?.let { error ->
        Text(
          text = error,
          color = MaterialTheme.colorScheme.error,
          style = MaterialTheme.typography.bodySmall,
          modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 4.dp),
        )
      }
      state.turnActivity?.let { activity -> ChatTurnActivity(activity) }
    },
    composer = {
      UgotChatComposer(
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
  state.history?.takeIf(ChatHistoryUiState::visible)?.let { history ->
    UgotChatHistoryDialog(history = history, labels = labels, onIntent = onIntent)
  }
  state.attachmentViewer?.let { viewer ->
    UgotChatAttachmentViewer(viewer = viewer, labels = labels, onIntent = onIntent)
  }
  state.activeWidget?.let { widget ->
    if (capabilities.showWidgets && widget.displayMode == ChatWidgetDisplayMode.FULLSCREEN) {
      widgetOverlayRenderer(widget, labels, onIntent)
    }
  }
}

@Composable
private fun UgotChatEmptyState(
  state: ChatEmptyStateUi,
  onIntent: (ChatUiIntent) -> Unit,
  modifier: Modifier = Modifier,
) {
  Box(modifier = modifier.padding(horizontal = 32.dp), contentAlignment = Alignment.Center) {
    Column(
      horizontalAlignment = Alignment.CenterHorizontally,
      verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
      Text(state.title, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
      Text(
        state.description,
        style = MaterialTheme.typography.bodyMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
      )
      FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        state.suggestions.forEach { suggestion ->
          FilterChip(
            selected = false,
            onClick = { onIntent(ChatUiIntent.SuggestionClicked(suggestion)) },
            label = { Text(suggestion) },
          )
        }
      }
    }
  }
}

@Composable
private fun UgotChatHistoryDialog(
  history: ChatHistoryUiState,
  labels: ChatUiLabels,
  onIntent: (ChatUiIntent) -> Unit,
) {
  AlertDialog(
    onDismissRequest = { onIntent(ChatUiIntent.HistoryDismissed) },
    title = { Text(labels.openHistory) },
    text = {
      Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        history.conversations.forEach { item ->
          TextButton(onClick = { onIntent(ChatUiIntent.HistoryConversationSelected(item.id)) }) {
            Column(modifier = Modifier.fillMaxWidth()) {
              Text(item.title, fontWeight = if (item.selected) FontWeight.Bold else FontWeight.Normal)
              item.detail?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
            }
          }
        }
      }
    },
    confirmButton = {
      TextButton(onClick = { onIntent(ChatUiIntent.HistoryDismissed) }) { Text(labels.close) }
    },
  )
}

@Composable
private fun UgotChatAttachmentViewer(
  viewer: ChatAttachmentViewerUiState,
  labels: ChatUiLabels,
  onIntent: (ChatUiIntent) -> Unit,
) {
  AlertDialog(
    onDismissRequest = { onIntent(ChatUiIntent.CloseAttachmentViewer) },
    title = { Text(viewer.title) },
    text = { Text(viewer.attachmentId, style = MaterialTheme.typography.bodySmall) },
    confirmButton = {
      TextButton(onClick = { onIntent(ChatUiIntent.CloseAttachmentViewer) }) { Text(labels.close) }
    },
  )
}

@Composable
private fun UgotChatWidgetOverlay(
  widget: ChatWidgetUiState,
  labels: ChatUiLabels,
  onIntent: (ChatUiIntent) -> Unit,
) {
  Surface(modifier = Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.surface) {
    Column(modifier = Modifier.fillMaxSize().padding(16.dp)) {
      Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
      ) {
        Text(widget.title, style = MaterialTheme.typography.titleLarge)
        TextButton(onClick = { onIntent(ChatUiIntent.CloseWidget) }) { Text(labels.close) }
      }
      Text(widget.summary, modifier = Modifier.padding(top = 16.dp))
    }
  }
}

/**
 * Compatibility entry point for hosts which have not yet migrated to the canonical name.
 * New hosts must call [UgotChatExperience] so ownership can be verified statically.
 */
@Composable
fun ChatSurface(
  state: ChatSurfaceState,
  capabilities: ChatUiCapabilities,
  labels: ChatUiLabels,
  onIntent: (ChatUiIntent) -> Unit,
  modifier: Modifier = Modifier,
  extensionRenderer: @Composable (ChatBlockUi.Extension) -> Unit = {},
  widgetRenderer: @Composable (ChatWidgetUiState, ChatUiLabels, (ChatUiIntent) -> Unit) -> Unit =
    { widget, currentLabels, currentOnIntent ->
      ChatWidgetCard(widget, currentLabels, currentOnIntent)
    },
  widgetOverlayRenderer: @Composable (ChatWidgetUiState, ChatUiLabels, (ChatUiIntent) -> Unit) -> Unit =
    { widget, currentLabels, currentOnIntent ->
      UgotChatWidgetOverlay(widget, currentLabels, currentOnIntent)
    },
) =
  UgotChatExperience(
    state = state,
    capabilities = capabilities,
    labels = labels,
    onIntent = onIntent,
    modifier = modifier,
    extensionRenderer = extensionRenderer,
    widgetRenderer = widgetRenderer,
    widgetOverlayRenderer = widgetOverlayRenderer,
  )

/** Shared small-app shell. Hosts can retain specialized renderers without duplicating layout. */
@Composable
fun UgotChatExperienceScaffold(
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
fun ChatSurfaceScaffold(
  transcript: @Composable BoxScope.() -> Unit,
  modifier: Modifier = Modifier,
  header: @Composable () -> Unit = {},
  activity: @Composable () -> Unit = {},
  composer: @Composable () -> Unit,
) =
  UgotChatExperienceScaffold(
    transcript = transcript,
    modifier = modifier,
    header = header,
    activity = activity,
    composer = composer,
  )

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun UgotChatTopBar(
  navigationMode: ChatNavigationMode,
  navigationEnabled: Boolean,
  navigationContentDescription: String,
  onNavigationClicked: () -> Unit,
  modifier: Modifier = Modifier,
  title: @Composable () -> Unit,
  actions: @Composable RowScope.() -> Unit = {},
) {
  CenterAlignedTopAppBar(
    modifier = modifier,
    title = title,
    navigationIcon = {
      if (navigationMode != ChatNavigationMode.NONE) {
        IconButton(onClick = onNavigationClicked, enabled = navigationEnabled) {
          Icon(
            imageVector =
              if (navigationMode == ChatNavigationMode.HISTORY) Icons.Rounded.History
              else Icons.AutoMirrored.Rounded.ArrowBack,
            contentDescription = navigationContentDescription,
          )
        }
      }
    },
    actions = actions,
  )
}

@Composable
fun UgotChatTopBar(
  state: ChatSurfaceState,
  capabilities: ChatUiCapabilities,
  labels: ChatUiLabels,
  onIntent: (ChatUiIntent) -> Unit,
  modifier: Modifier = Modifier,
) {
  UgotChatTopBar(
    navigationMode = capabilities.navigationMode,
    navigationEnabled = !state.composer.inProgress && !state.restoring,
    navigationContentDescription =
      if (capabilities.navigationMode == ChatNavigationMode.HISTORY) labels.openHistory
      else labels.navigateBack,
    onNavigationClicked = {
      onIntent(
        if (capabilities.navigationMode == ChatNavigationMode.HISTORY) ChatUiIntent.HistoryClicked
        else ChatUiIntent.NavigateBackClicked
      )
    },
    modifier = modifier,
    title = {
      Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(4.dp),
      ) {
        Text(text = state.title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
        when {
          capabilities.showModelPicker && state.models.isNotEmpty() ->
            UgotChatModelPicker(models = state.models, onIntent = onIntent)
          capabilities.showProvider && state.providerLabel.isNotBlank() ->
            Text(
              text = state.providerLabel,
              style = MaterialTheme.typography.labelSmall,
              color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
      }
    },
    actions = {
      if (capabilities.showHistoryAction) {
        IconButton(onClick = { onIntent(ChatUiIntent.HistoryClicked) }) {
          Icon(Icons.Rounded.History, contentDescription = labels.openHistory)
        }
      }
      if (capabilities.showSettingsAction) {
        IconButton(onClick = { onIntent(ChatUiIntent.SettingsClicked) }) {
          Icon(Icons.Rounded.Tune, contentDescription = labels.openSettings)
        }
      }
      if (capabilities.showResetAction) {
        IconButton(
          onClick = { onIntent(ChatUiIntent.ResetConversationClicked) },
          enabled = !state.composer.inProgress && !state.restoring,
        ) {
          Box(
            modifier = Modifier.size(32.dp).clip(RoundedCornerShape(16.dp)).background(
              MaterialTheme.colorScheme.surfaceContainer
            ),
            contentAlignment = Alignment.Center,
          ) {
            Icon(
              Icons.Rounded.MapsUgc,
              contentDescription = labels.resetConversation,
              modifier = Modifier.size(20.dp),
            )
          }
        }
      }
    },
  )
}

@Composable
fun ChatTranscript(
  messages: List<ChatMessageUi>,
  capabilities: ChatUiCapabilities,
  labels: ChatUiLabels,
  onIntent: (ChatUiIntent) -> Unit,
  modifier: Modifier = Modifier,
  extensionRenderer: @Composable (ChatBlockUi.Extension) -> Unit = {},
  widgetRenderer: @Composable (ChatWidgetUiState, ChatUiLabels, (ChatUiIntent) -> Unit) -> Unit =
    { widget, currentLabels, currentOnIntent ->
      ChatWidgetCard(widget, currentLabels, currentOnIntent)
    },
) {
  val listState = rememberLazyListState()
  val verticalDragHandler =
    remember(listState) { LazyListVerticalDragHandler(listState = listState) }
  DisposableEffect(verticalDragHandler) { onDispose(verticalDragHandler::dispose) }
  val autoScrollKey = transcriptAutoScrollKey(messages)
  LaunchedEffect(autoScrollKey) {
    if (messages.isNotEmpty()) {
      listState.scrollToItem(messages.lastIndex)
    }
  }
  CompositionLocalProvider(LocalChatTranscriptVerticalDragHandler provides verticalDragHandler) {
    ChatTimeline(
      items = messages,
      itemKey = { _, message -> message.id },
      state = listState,
      modifier = modifier.padding(horizontal = if (capabilities.layout == ChatLayout.COMPACT) 8.dp else 12.dp),
      verticalArrangement = Arrangement.spacedBy(8.dp),
    ) { _, message ->
      ChatMessageRow(
        message = message,
        capabilities = capabilities,
        labels = labels,
        onIntent = onIntent,
        extensionRenderer = extensionRenderer,
        widgetRenderer = widgetRenderer,
      )
    }
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
  widgetRenderer: @Composable (ChatWidgetUiState, ChatUiLabels, (ChatUiIntent) -> Unit) -> Unit,
) {
  val runs = orderedVisibleChatBlockRuns(message.blocks, capabilities)
  runs.forEachIndexed { index, run ->
    val isFirstRun = index == 0
    val isLastRun = index == runs.lastIndex
    UgotChatMessageFrame(
      role = message.role,
      senderLabel = message.senderLabel,
      timestampLabel = if (isLastRun) message.timestampLabel else null,
      metadataLabel = if (isLastRun) message.metadataLabel else null,
      actions = if (isLastRun) message.actions else emptyList(),
      showSenderLabel = isFirstRun && capabilities.showSenderLabels,
      showTimestamp = isLastRun && capabilities.showTimestamps,
      showActions = isLastRun && capabilities.showMessageActions,
      bubbleEnabled = !run.isWidget,
      fullWidth = run.isWidget,
      onActionClicked = { actionId ->
        onIntent(ChatUiIntent.MessageActionClicked(message.id, actionId))
      },
    ) {
      ChatMessageBlocks(
        blocks = run.blocks,
        messageInProgress = message.inProgress,
        capabilities = capabilities,
        labels = labels,
        onIntent = onIntent,
        extensionRenderer = extensionRenderer,
        widgetRenderer = widgetRenderer,
        modifier =
          if (run.isWidget) Modifier.fillMaxWidth()
          else Modifier.padding(horizontal = 14.dp, vertical = 10.dp),
      )
    }
  }
}

internal data class ChatBlockRenderRun(
  val isWidget: Boolean,
  val blocks: List<ChatBlockUi>,
)

/** Preserves the canonical block order while keeping widgets outside regular message bubbles. */
internal fun orderedVisibleChatBlockRuns(
  blocks: List<ChatBlockUi>,
  capabilities: ChatUiCapabilities,
): List<ChatBlockRenderRun> {
  val runs = mutableListOf<ChatBlockRenderRun>()
  val pendingRegularBlocks = mutableListOf<ChatBlockUi>()

  fun flushRegularBlocks() {
    if (pendingRegularBlocks.isEmpty()) return
    runs += ChatBlockRenderRun(isWidget = false, blocks = pendingRegularBlocks.toList())
    pendingRegularBlocks.clear()
  }

  blocks.forEach { block ->
    val visible =
      when (block) {
        is ChatBlockUi.Widget -> capabilities.showWidgets
        is ChatBlockUi.Text -> block.value.isNotBlank()
        is ChatBlockUi.Thinking -> capabilities.showThinking && block.value.isNotBlank()
        else -> true
      }
    if (!visible) return@forEach

    if (block is ChatBlockUi.Widget) {
      flushRegularBlocks()
      runs += ChatBlockRenderRun(isWidget = true, blocks = listOf(block))
    } else {
      pendingRegularBlocks += block
    }
  }
  flushRegularBlocks()
  return runs
}

@Composable
private fun ChatMessageBlocks(
  blocks: List<ChatBlockUi>,
  messageInProgress: Boolean,
  capabilities: ChatUiCapabilities,
  labels: ChatUiLabels,
  onIntent: (ChatUiIntent) -> Unit,
  extensionRenderer: @Composable (ChatBlockUi.Extension) -> Unit,
  widgetRenderer: @Composable (ChatWidgetUiState, ChatUiLabels, (ChatUiIntent) -> Unit) -> Unit,
  modifier: Modifier = Modifier,
) {
  Column(modifier = modifier, verticalArrangement = Arrangement.spacedBy(6.dp)) {
    blocks.forEach { block ->
      when (block) {
        is ChatBlockUi.Text ->
          if (shouldRenderMarkdown(block.markdown, messageInProgress)) {
            ChatMarkdownText(block.value)
          } else {
            Text(block.value, style = MaterialTheme.typography.bodyMedium)
          }
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
            widgetRenderer(block.widget, labels, onIntent)
          }
        is ChatBlockUi.Extension -> extensionRenderer(block)
      }
    }
  }
}

internal data class TranscriptAutoScrollKey(
  val messageCount: Int,
  val lastMessageId: String?,
  val lastMessageInProgress: Boolean,
)

/**
 * Token deltas only change blocks, so they deliberately keep the same key. The transcript follows
 * a newly inserted message and its terminal transition without forcing a synchronous list layout
 * for every model callback.
 */
internal fun transcriptAutoScrollKey(messages: List<ChatMessageUi>): TranscriptAutoScrollKey {
  val lastMessage = messages.lastOrNull()
  return TranscriptAutoScrollKey(
    messageCount = messages.size,
    lastMessageId = lastMessage?.id,
    lastMessageInProgress = lastMessage?.inProgress == true,
  )
}

/** CommonMark parsing is deferred until the complete message is stable. */
internal fun shouldRenderMarkdown(markdown: Boolean, messageInProgress: Boolean): Boolean =
  markdown && !messageInProgress

/** Markdown is owned by the shared chat renderer so every host presents the same message body. */
@Composable
private fun ChatMarkdownText(text: String, modifier: Modifier = Modifier) {
  ProvideTextStyle(
    MaterialTheme.typography.bodyMedium.copy(color = MaterialTheme.colorScheme.onSurface)
  ) {
    RichText(modifier = modifier) { Markdown(content = text) }
  }
}

@Composable
fun UgotChatMessageFrame(
  role: ChatRole,
  senderLabel: String?,
  timestampLabel: String?,
  metadataLabel: String?,
  actions: List<ChatMessageActionUi>,
  showSenderLabel: Boolean,
  showTimestamp: Boolean,
  showActions: Boolean,
  bubbleEnabled: Boolean = true,
  fullWidth: Boolean = false,
  onActionClicked: (String) -> Unit,
  modifier: Modifier = Modifier,
  content: @Composable () -> Unit,
) {
  val horizontal =
    when (role) {
      ChatRole.USER -> Alignment.End
      ChatRole.ASSISTANT -> Alignment.Start
      ChatRole.SYSTEM -> Alignment.CenterHorizontally
    }
  val horizontalPadding = if (role == ChatRole.SYSTEM) 24.dp else 48.dp
  val shape =
    when (role) {
      ChatRole.USER -> RoundedCornerShape(topStart = 16.dp, topEnd = 4.dp, bottomStart = 16.dp, bottomEnd = 16.dp)
      ChatRole.ASSISTANT -> RoundedCornerShape(topStart = 4.dp, topEnd = 16.dp, bottomStart = 16.dp, bottomEnd = 16.dp)
      ChatRole.SYSTEM -> RoundedCornerShape(16.dp)
    }
  val color =
    when (role) {
      ChatRole.USER -> MaterialTheme.colorScheme.primaryContainer
      ChatRole.ASSISTANT -> MaterialTheme.colorScheme.surfaceContainerHigh
      ChatRole.SYSTEM -> MaterialTheme.colorScheme.surfaceContainer
    }
  Column(
    modifier =
      modifier.fillMaxWidth().padding(
        start =
          if (fullWidth) 0.dp
          else if (role == ChatRole.ASSISTANT) 12.dp
          else horizontalPadding,
        end =
          if (fullWidth) 0.dp
          else if (role == ChatRole.USER) 12.dp
          else horizontalPadding,
        top = 6.dp,
        bottom = 6.dp,
      ),
    horizontalAlignment = horizontal,
  ) {
    if (showSenderLabel && !senderLabel.isNullOrBlank()) {
      Text(
        text = senderLabel,
        style = MaterialTheme.typography.labelSmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
      )
    }
    if (bubbleEnabled) {
      Surface(shape = shape, color = color, content = content)
    } else {
      content()
    }
    if (!metadataLabel.isNullOrBlank()) {
      Text(
        text = metadataLabel,
        style = MaterialTheme.typography.labelSmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
      )
    }
    if (showTimestamp && !timestampLabel.isNullOrBlank()) {
      Text(
        text = timestampLabel,
        style = MaterialTheme.typography.labelSmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
      )
    }
    if (showActions && actions.isNotEmpty()) {
      Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        actions.forEach { action ->
          TextButton(
            onClick = { onActionClicked(action.id) },
            enabled = action.enabled,
          ) {
            Text(action.label)
          }
        }
      }
    }
  }
}

@Composable
fun UgotChatComposerFrame(
  draft: String,
  enabled: Boolean,
  inProgress: Boolean,
  canSend: Boolean,
  showStopButton: Boolean,
  placeholder: String,
  maxLines: Int,
  sendContentDescription: String,
  stopContentDescription: String,
  onDraftChanged: (String) -> Unit,
  onSendClicked: () -> Unit,
  onStopClicked: () -> Unit,
  modifier: Modifier = Modifier,
  draftModifier: Modifier = Modifier,
  attachments: @Composable () -> Unit = {},
  leadingActions: @Composable RowScope.() -> Unit = {},
) {
  Column(modifier = modifier.fillMaxWidth()) {
    attachments()
    Column(
      modifier =
        Modifier.padding(horizontal = 12.dp, vertical = 8.dp)
          .border(1.dp, MaterialTheme.colorScheme.outlineVariant, RoundedCornerShape(16.dp))
    ) {
      UgotChatDraftField(
        value = draft,
        maxLines = maxLines,
        onValueChange = onDraftChanged,
        enabled = enabled,
        placeholder = placeholder,
        modifier = draftModifier,
      )
      Row(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween,
      ) {
        Row(
          verticalAlignment = Alignment.CenterVertically,
          horizontalArrangement = Arrangement.spacedBy(4.dp),
          content = leadingActions,
        )
        UgotChatSendOrStopButton(
          inProgress = inProgress,
          showStopButton = showStopButton,
          canSend = canSend,
          sendContentDescription = sendContentDescription,
          stopContentDescription = stopContentDescription,
          onSendClicked = onSendClicked,
          onStopClicked = onStopClicked,
        )
      }
    }
  }
}

/** Shared horizontal attachment chrome. Hosts only render their domain-specific preview bodies. */
@Composable
fun UgotChatAttachmentStrip(
  modifier: Modifier = Modifier,
  content: @Composable RowScope.() -> Unit,
) {
  Row(
    modifier =
      modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 12.dp),
    horizontalArrangement = Arrangement.spacedBy(8.dp),
    verticalAlignment = Alignment.CenterVertically,
    content = content,
  )
}

@Composable
fun UgotChatDraftField(
  value: String,
  maxLines: Int,
  enabled: Boolean,
  placeholder: String,
  onValueChange: (String) -> Unit,
  modifier: Modifier = Modifier,
) {
  TextField(
    value = value,
    minLines = 1,
    maxLines = maxLines,
    onValueChange = onValueChange,
    enabled = enabled,
    colors =
      TextFieldDefaults.colors(
        unfocusedContainerColor = Color.Transparent,
        focusedContainerColor = Color.Transparent,
        focusedIndicatorColor = Color.Transparent,
        unfocusedIndicatorColor = Color.Transparent,
        disabledIndicatorColor = Color.Transparent,
        disabledContainerColor = Color.Transparent,
      ),
    modifier = modifier.fillMaxWidth(),
    placeholder = { Text(placeholder) },
  )
}

@Composable
fun UgotChatSendOrStopButton(
  inProgress: Boolean,
  showStopButton: Boolean,
  canSend: Boolean,
  sendContentDescription: String,
  stopContentDescription: String,
  onSendClicked: () -> Unit,
  onStopClicked: () -> Unit,
  modifier: Modifier = Modifier,
) {
  if (inProgress && showStopButton) {
    IconButton(
      onClick = onStopClicked,
      modifier = modifier,
      colors =
        IconButtonDefaults.iconButtonColors(
          containerColor = MaterialTheme.colorScheme.secondaryContainer
        ),
    ) {
      Icon(
        Icons.Rounded.Stop,
        contentDescription = stopContentDescription,
        tint = MaterialTheme.colorScheme.primary,
      )
    }
  } else {
    IconButton(
      enabled = canSend,
      onClick = onSendClicked,
      modifier = modifier,
      colors =
        IconButtonDefaults.iconButtonColors(
          containerColor = MaterialTheme.colorScheme.primary,
          disabledContainerColor = MaterialTheme.colorScheme.primary.copy(alpha = 0.3f),
        ),
    ) {
      Icon(
        Icons.AutoMirrored.Rounded.Send,
        contentDescription = sendContentDescription,
        tint = Color.White,
      )
    }
  }
}

@Composable
fun UgotChatComposer(
  state: ChatComposerUiState,
  capabilities: ChatUiCapabilities,
  labels: ChatUiLabels,
  onIntent: (ChatUiIntent) -> Unit,
  modifier: Modifier = Modifier,
) {
  var showAddMenu by remember { mutableStateOf(false) }
  UgotChatComposerFrame(
    draft = state.draft,
    enabled = state.enabled,
    inProgress = state.inProgress,
    canSend = state.canSend(),
    showStopButton = capabilities.showStopButton,
    placeholder = labels.inputPlaceholder,
    maxLines = capabilities.composerMaxLines,
    sendContentDescription = labels.send,
    stopContentDescription = labels.stop,
    onDraftChanged = { onIntent(ChatUiIntent.DraftChanged(it)) },
    onSendClicked = { onIntent(ChatUiIntent.SendClicked) },
    onStopClicked = { onIntent(ChatUiIntent.StopClicked) },
    modifier = modifier,
    attachments = {
      if (state.attachments.isNotEmpty()) {
        UgotChatAttachmentStrip {
          state.attachments.forEach { attachment ->
            FilterChip(
              selected = true,
              onClick = { onIntent(ChatUiIntent.RemoveAttachment(attachment.id)) },
              label = { Text("${attachment.displayName} ×") },
            )
          }
        }
      }
    },
    leadingActions = {
      if (capabilities.allowImages || capabilities.allowAudio) {
        Box {
          OutlinedIconButton(
            onClick = { showAddMenu = true },
            enabled = state.enabled && !state.inProgress,
          ) {
            Icon(Icons.Outlined.Add, contentDescription = labels.addContent)
          }
          DropdownMenu(expanded = showAddMenu, onDismissRequest = { showAddMenu = false }) {
            if (capabilities.allowImages) {
              DropdownMenuItem(
                text = { Text(labels.addImage) },
                onClick = {
                  showAddMenu = false
                  onIntent(ChatUiIntent.AddAttachmentClicked(ChatAttachmentType.IMAGE))
                },
              )
            }
            if (capabilities.allowAudio) {
              DropdownMenuItem(
                text = { Text(labels.addAudio) },
                onClick = {
                  showAddMenu = false
                  onIntent(ChatUiIntent.AddAttachmentClicked(ChatAttachmentType.AUDIO))
                },
              )
            }
          }
        }
      }
    },
  )
}

@Composable
fun UgotChatModelPicker(models: List<ChatModelUi>, onIntent: (ChatUiIntent) -> Unit) {
  var expanded by remember { mutableStateOf(false) }
  val selected = models.firstOrNull(ChatModelUi::selected) ?: models.first()
  Box {
    UgotChatModelTrigger(
      label = selected.label,
      statusLabel = selected.statusLabel,
      enabled = true,
      onClick = { expanded = true },
    )
    DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
      models.forEach { model ->
        DropdownMenuItem(
          text = {
            Column {
              Text(model.label)
              model.statusLabel?.let {
                Text(
                  text = it,
                  style = MaterialTheme.typography.labelSmall,
                  color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
              }
            }
          },
          enabled = model.enabled || model.setupActionLabel != null,
          onClick = {
            expanded = false
            if (model.enabled) onIntent(ChatUiIntent.ModelSelected(model.id))
            else onIntent(ChatUiIntent.ModelSetupClicked(model.id))
          },
        )
      }
    }
  }
}

/** Shared model-picker trigger. Hosts may keep provider-specific selection surfaces behind it. */
@Composable
fun UgotChatModelTrigger(
  label: String,
  statusLabel: String? = null,
  enabled: Boolean,
  onClick: () -> Unit,
  modifier: Modifier = Modifier,
  leadingIcon: (@Composable () -> Unit)? = null,
) {
  FilterChip(
    selected = true,
    enabled = enabled,
    onClick = onClick,
    modifier = modifier,
    label = { Text(statusLabel?.let { "$label · $it" } ?: label) },
    leadingIcon = leadingIcon,
    trailingIcon = {
      Icon(Icons.Rounded.ArrowDropDown, contentDescription = null, modifier = Modifier.size(20.dp))
    },
  )
}

@Composable
fun ChatComposer(
  state: ChatComposerUiState,
  capabilities: ChatUiCapabilities,
  labels: ChatUiLabels,
  onIntent: (ChatUiIntent) -> Unit,
  modifier: Modifier = Modifier,
) =
  UgotChatComposer(
    state = state,
    capabilities = capabilities,
    labels = labels,
    onIntent = onIntent,
    modifier = modifier,
  )

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
