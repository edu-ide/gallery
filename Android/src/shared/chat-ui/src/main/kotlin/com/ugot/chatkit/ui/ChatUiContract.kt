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

import androidx.compose.runtime.Immutable

enum class ChatLayout {
  FULL,
  COMPACT,
}

@Immutable
data class ChatUiCapabilities(
  val layout: ChatLayout = ChatLayout.FULL,
  val showTopBar: Boolean = true,
  val navigationMode: ChatNavigationMode = ChatNavigationMode.NONE,
  val showHistoryAction: Boolean = false,
  val showSettingsAction: Boolean = false,
  val showResetAction: Boolean = false,
  val showModelPicker: Boolean = true,
  val showProvider: Boolean = true,
  val showSenderLabels: Boolean = true,
  val showTimestamps: Boolean = false,
  val showThinking: Boolean = true,
  val showMessageActions: Boolean = true,
  val allowImages: Boolean = true,
  val allowAudio: Boolean = true,
  val showConnectors: Boolean = true,
  val showWidgets: Boolean = true,
  val showToolApproval: Boolean = true,
  val showStopButton: Boolean = true,
  val composerMaxLines: Int = 6,
) {
  init {
    require(composerMaxLines > 0) { "Composer max lines must be positive" }
  }
}

enum class ChatNavigationMode {
  NONE,
  BACK,
  HISTORY,
}

@Immutable
data class ChatSurfaceState(
  val conversationId: String,
  val title: String,
  val providerLabel: String,
  val messages: List<ChatMessageUi> = emptyList(),
  val composer: ChatComposerUiState = ChatComposerUiState(),
  val models: List<ChatModelUi> = emptyList(),
  val connectors: List<ChatConnectorUi> = emptyList(),
  val emptyState: ChatEmptyStateUi? = null,
  val history: ChatHistoryUiState? = null,
  val activeWidget: ChatWidgetUiState? = null,
  val attachmentViewer: ChatAttachmentViewerUiState? = null,
  val pendingPermission: ChatPermissionUiState? = null,
  val turnActivity: ChatTurnActivityUiState? = null,
  val restoring: Boolean = false,
  val error: String? = null,
)

@Immutable
data class ChatEmptyStateUi(
  val title: String,
  val description: String,
  val suggestions: List<String> = emptyList(),
)

@Immutable
data class ChatHistoryUiState(
  val visible: Boolean = false,
  val conversations: List<ChatHistoryItemUi> = emptyList(),
)

@Immutable
data class ChatHistoryItemUi(
  val id: String,
  val title: String,
  val detail: String? = null,
  val selected: Boolean = false,
)

enum class ChatRole {
  USER,
  ASSISTANT,
  SYSTEM,
}

@Immutable
data class ChatMessageUi(
  val id: String,
  val role: ChatRole,
  val blocks: List<ChatBlockUi>,
  val senderLabel: String? = null,
  val timestampLabel: String? = null,
  val metadataLabel: String? = null,
  val actions: List<ChatMessageActionUi> = emptyList(),
  val inProgress: Boolean = false,
)

@Immutable
data class ChatMessageActionUi(
  val id: String,
  val label: String,
  val enabled: Boolean = true,
)

sealed interface ChatBlockUi {
  @Immutable data class Text(val value: String, val markdown: Boolean = true) : ChatBlockUi

  @Immutable data class Thinking(val value: String, val inProgress: Boolean) : ChatBlockUi

  @Immutable data class Notice(val level: ChatNoticeLevel, val text: String) : ChatBlockUi

  @Immutable data class Attachment(val attachment: ChatAttachmentUi) : ChatBlockUi

  @Immutable data class Widget(val widget: ChatWidgetUiState) : ChatBlockUi

  @Immutable data class Extension(val rendererKey: String, val contentRef: String) : ChatBlockUi
}

enum class ChatNoticeLevel {
  INFO,
  WARNING,
  ERROR,
}

enum class ChatAttachmentType {
  IMAGE,
  AUDIO,
  FILE,
}

enum class ChatAttachmentSource {
  CAMERA,
  PHOTO_LIBRARY,
  AUDIO_RECORDER,
  AUDIO_FILE,
  FILE,
}

@Immutable
data class ChatAttachmentUi(
  val id: String,
  val type: ChatAttachmentType,
  val displayName: String,
  val contentRef: String,
  val mimeType: String? = null,
  val durationLabel: String? = null,
  val previewRef: String? = null,
)

@Immutable
data class ChatAttachmentViewerUiState(
  val attachmentId: String,
  val title: String,
)

@Immutable
data class ChatComposerUiState(
  val draft: String = "",
  val attachments: List<ChatAttachmentUi> = emptyList(),
  val enabled: Boolean = true,
  val inProgress: Boolean = false,
) {
  fun canSend(): Boolean = enabled && !inProgress && (draft.isNotBlank() || attachments.isNotEmpty())
}

@Immutable
data class ChatModelUi(
  val id: String,
  val label: String,
  val selected: Boolean,
  val enabled: Boolean = true,
  val state: ChatModelState = ChatModelState.READY,
  val progress: Float? = null,
  val statusLabel: String? = null,
  val setupActionLabel: String? = null,
)

enum class ChatModelState {
  READY,
  DOWNLOADING,
  INITIALIZING,
  REQUIRES_SETUP,
  UNAVAILABLE,
  ERROR,
}

@Immutable
data class ChatConnectorUi(
  val id: String,
  val label: String,
  val active: Boolean,
  val enabled: Boolean = true,
)

enum class ChatWidgetDisplayMode {
  CARD,
  INLINE,
  FULLSCREEN,
}

@Immutable
data class ChatWidgetUiState(
  val messageId: String,
  val title: String,
  val summary: String,
  val displayMode: ChatWidgetDisplayMode = ChatWidgetDisplayMode.CARD,
)

enum class ChatPermissionKind {
  PLATFORM,
  MCP_TOOL,
}

enum class ChatPermissionDecision {
  ALLOW_ONCE,
  DENY,
}

@Immutable
data class ChatPermissionUiState(
  val requestId: String,
  val kind: ChatPermissionKind,
  val title: String,
  val rationale: String,
  val riskLabel: String? = null,
)

@Immutable
data class ChatTurnActivityUiState(
  val title: String,
  val detail: String,
  val showsProgress: Boolean,
)

@Immutable
data class ChatUiLabels(
  val send: String,
  val stop: String,
  val addImage: String,
  val addAudio: String,
  val removeAttachment: String,
  val allowOnce: String,
  val deny: String,
  val expand: String,
  val close: String,
  val inputPlaceholder: String,
  val navigateBack: String = "Back",
  val openHistory: String = "History",
  val openSettings: String = "Settings",
  val resetConversation: String = "New conversation",
  val addContent: String = "Add content",
)

sealed interface ChatUiIntent {
  data class DraftChanged(val value: String) : ChatUiIntent

  data object SendClicked : ChatUiIntent

  data object StopClicked : ChatUiIntent

  data object NavigateBackClicked : ChatUiIntent

  data object HistoryClicked : ChatUiIntent

  data object SettingsClicked : ChatUiIntent

  data object ResetConversationClicked : ChatUiIntent

  data class AddAttachmentClicked(val type: ChatAttachmentType) : ChatUiIntent

  data class AddAttachmentSourceClicked(val source: ChatAttachmentSource) : ChatUiIntent

  data class RemoveAttachment(val id: String) : ChatUiIntent

  data class OpenAttachment(val id: String) : ChatUiIntent

  data object CloseAttachmentViewer : ChatUiIntent

  data class ModelSelected(val id: String) : ChatUiIntent

  data class ModelSetupClicked(val id: String) : ChatUiIntent

  data class MessageActionClicked(val messageId: String, val actionId: String) : ChatUiIntent

  data class SuggestionClicked(val value: String) : ChatUiIntent

  data class HistoryConversationSelected(val id: String) : ChatUiIntent

  data class HistoryConversationDeleted(val id: String) : ChatUiIntent

  data object HistoryDismissed : ChatUiIntent

  data class ConnectorToggled(val id: String) : ChatUiIntent

  data class OpenWidget(val messageId: String, val fullscreen: Boolean) : ChatUiIntent

  data object CloseWidget : ChatUiIntent

  data class ResolvePermission(
    val requestId: String,
    val decision: ChatPermissionDecision,
  ) : ChatUiIntent
}
