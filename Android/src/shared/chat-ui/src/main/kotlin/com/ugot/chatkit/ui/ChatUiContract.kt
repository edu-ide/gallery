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

@Immutable
data class ChatSurfaceState(
  val conversationId: String,
  val title: String,
  val providerLabel: String,
  val messages: List<ChatMessageUi> = emptyList(),
  val composer: ChatComposerUiState = ChatComposerUiState(),
  val models: List<ChatModelUi> = emptyList(),
  val connectors: List<ChatConnectorUi> = emptyList(),
  val activeWidget: ChatWidgetUiState? = null,
  val pendingPermission: ChatPermissionUiState? = null,
  val turnActivity: ChatTurnActivityUiState? = null,
  val restoring: Boolean = false,
  val error: String? = null,
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
  val inProgress: Boolean = false,
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

@Immutable
data class ChatAttachmentUi(
  val id: String,
  val type: ChatAttachmentType,
  val displayName: String,
  val contentRef: String,
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
  val statusLabel: String? = null,
)

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
)

sealed interface ChatUiIntent {
  data class DraftChanged(val value: String) : ChatUiIntent

  data object SendClicked : ChatUiIntent

  data object StopClicked : ChatUiIntent

  data class AddAttachmentClicked(val type: ChatAttachmentType) : ChatUiIntent

  data class RemoveAttachment(val id: String) : ChatUiIntent

  data class ModelSelected(val id: String) : ChatUiIntent

  data class ConnectorToggled(val id: String) : ChatUiIntent

  data class OpenWidget(val messageId: String, val fullscreen: Boolean) : ChatUiIntent

  data object CloseWidget : ChatUiIntent

  data class ResolvePermission(
    val requestId: String,
    val decision: ChatPermissionDecision,
  ) : ChatUiIntent
}
