/*
 * Copyright 2025 Google LLC
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

package com.google.ai.edge.gallery.ui.llmchat

import android.graphics.Bitmap
import android.util.Base64
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import android.content.Context
import androidx.core.os.bundleOf
import androidx.hilt.navigation.compose.hiltViewModel
import com.google.ai.edge.gallery.agent.vfs.AgentVfsFactory
import com.google.ai.edge.gallery.agent.vfs.AgentVfsPaths
import com.google.ai.edge.gallery.agent.vfs.AgentVfsUserAttachmentIngestor
import com.google.ai.edge.gallery.agent.turn.AgentTurnRoute
import com.google.ai.edge.gallery.agent.turn.agentTurnEventGenerateFinalAnswer
import com.google.ai.edge.gallery.agent.turn.agentTurnEventReadVisibleContext
import com.google.ai.edge.gallery.agent.turn.agentTurnEventSearchTools
import com.google.ai.edge.gallery.agent.turn.agentTurnEventSkipToolSearch
import com.google.ai.edge.gallery.agent.turn.agentTurnFinalAnswerSourceModel
import com.google.ai.edge.gallery.agent.turn.agentTurnOutcomeAnswered
import com.google.ai.edge.gallery.agent.turn.agentTurnRouteMcpConnector
import com.google.ai.edge.gallery.agent.turn.agentTurnRouteMcpConnectors
import com.google.ai.edge.gallery.agent.turn.agentTurnRouteModel
import com.google.ai.edge.gallery.agent.turn.planAgentTurnOpeningEvents
import com.google.ai.edge.gallery.GalleryEvent
import com.google.ai.edge.gallery.R
import com.google.ai.edge.gallery.data.BuiltInTaskId
import com.google.ai.edge.gallery.data.Model
import com.google.ai.edge.gallery.data.RuntimeType
import com.google.ai.edge.gallery.data.Task
import com.google.ai.edge.gallery.firebaseAnalytics
import com.google.ai.edge.gallery.ui.common.chat.ChatMessageAudioClip
import com.google.ai.edge.gallery.ui.common.chat.ChatMessageImage
import com.google.ai.edge.gallery.ui.common.chat.ChatMessageText
import com.google.ai.edge.gallery.ui.common.chat.ChatView
import com.google.ai.edge.gallery.ui.common.chat.ChatMessage
import com.google.ai.edge.gallery.ui.common.chat.ChatSide
import com.google.ai.edge.gallery.ui.common.chat.SendMessageTrigger
import com.google.ai.edge.gallery.ui.mcp.McpUiSession
import com.google.ai.edge.gallery.ui.modelmanager.ModelManagerViewModel
import com.google.ai.edge.gallery.ui.unifiedchat.ConnectorBar
import com.google.ai.edge.gallery.ui.unifiedchat.ConnectorBarDisplayMode
import com.google.ai.edge.gallery.ui.unifiedchat.ConnectorBarState
import com.google.ai.edge.gallery.ui.unifiedchat.UnifiedChatEntryHint
import com.google.ai.edge.gallery.ui.unifiedchat.createUnifiedChatSessionState
import com.google.ai.edge.gallery.ui.unifiedchat.toUnifiedChatModelCapabilities
import com.google.ai.edge.gallery.ui.unifiedchat.mcp.McpWidgetFullscreenOverlay
import com.google.ai.edge.gallery.ui.unifiedchat.mcp.McpWidgetHostState
import com.google.ai.edge.gallery.ui.unifiedchat.mcp.McpWidgetSessionHost
import com.google.ai.edge.gallery.ui.unifiedchat.mcp.McpWidgetSnapshot
import com.google.ai.edge.gallery.ui.unifiedchat.messages.ChatMessageMcpWidgetCard
import com.google.ai.edge.gallery.ui.unifiedchat.session.UnifiedChatPersistedSession
import com.google.ai.edge.gallery.ui.unifiedchat.session.UnifiedChatSessionFileStore
import com.google.ai.edge.gallery.ui.unifiedchat.session.decodePersistedChatMessage
import com.google.ai.edge.gallery.ui.unifiedchat.session.buildUnifiedChatSessionId
import com.google.ai.edge.gallery.ui.unifiedchat.session.encodePersistableChatMessage
import com.google.ai.edge.gallery.ui.unifiedchat.session.deriveConversationTitleFromUnifiedMessages
import com.google.ai.edge.gallery.ui.unifiedchat.session.toUnifiedChatMessages
import com.google.ai.edge.gallery.ui.theme.emptyStateContent
import com.google.ai.edge.gallery.ui.theme.emptyStateTitle
import java.io.ByteArrayOutputStream
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

private const val TAG = "AGLlmChatScreen"
private const val UNIFIED_CHAT_SESSION_SAVE_DEBOUNCE_MS = 300L

private data class PendingUnifiedSessionSnapshot(
  val messages: List<ChatMessage> = emptyList(),
  val activeConnectorIds: List<String> = emptyList(),
  val sessionRestored: Boolean = false,
)

@Composable
fun LlmChatScreen(
  modelManagerViewModel: ModelManagerViewModel,
  navigateUp: () -> Unit,
  modifier: Modifier = Modifier,
  taskId: String = BuiltInTaskId.LLM_CHAT,
  onFirstToken: (Model) -> Unit = {},
  onGenerateResponseDone: (Model) -> Unit = {},
  onSkillClicked: () -> Unit = {},
  onResetSessionClickedOverride: ((Task, Model) -> Unit)? = null,
  composableBelowMessageList: @Composable (Model) -> Unit = {},
  viewModel: LlmChatViewModel = hiltViewModel(),
  entryHint: UnifiedChatEntryHint = UnifiedChatEntryHint(),
  allowEditingSystemPrompt: Boolean = false,
  curSystemPrompt: String = "",
  onSystemPromptChanged: (String) -> Unit = {},
  emptyStateComposable: @Composable (Model) -> Unit = {},
  sendMessageTrigger: SendMessageTrigger? = null,
  showImagePicker: Boolean = false,
  showAudioPicker: Boolean = false,
  showTopBar: Boolean = true,
  selectedModelOverride: Model? = null,
  mcpWidgetHostState: McpWidgetHostState? = null,
  mcpUiSession: McpWidgetSessionHost? = null,
  onMcpWidgetHostStateChange: (McpWidgetHostState) -> Unit = {},
  mcpWidgetFullscreenOverlay:
    @Composable
    (snapshot: McpWidgetSnapshot, session: McpWidgetSessionHost, onClose: () -> Unit) -> Unit =
      { snapshot, session, onClose ->
        McpWidgetFullscreenOverlay(
          snapshot = snapshot,
          session = session,
          onClose = onClose,
        )
      },
) {
  ChatViewWrapper(
    viewModel = viewModel,
    modelManagerViewModel = modelManagerViewModel,
    taskId = taskId,
    navigateUp = navigateUp,
    modifier = modifier,
    onSkillClicked = onSkillClicked,
    onFirstToken = onFirstToken,
    onGenerateResponseDone = onGenerateResponseDone,
    onResetSessionClickedOverride = onResetSessionClickedOverride,
    composableBelowMessageList = composableBelowMessageList,
    allowEditingSystemPrompt = allowEditingSystemPrompt,
    curSystemPrompt = curSystemPrompt,
    onSystemPromptChanged = onSystemPromptChanged,
    emptyStateComposable = emptyStateComposable,
    sendMessageTrigger = sendMessageTrigger,
    showImagePicker = showImagePicker,
    showAudioPicker = showAudioPicker,
    showTopBar = showTopBar,
    selectedModelOverride = selectedModelOverride,
    entryHint = entryHint,
    mcpWidgetHostState = mcpWidgetHostState,
    mcpUiSession = mcpUiSession,
    onMcpWidgetHostStateChange = onMcpWidgetHostStateChange,
    mcpWidgetFullscreenOverlay = mcpWidgetFullscreenOverlay,
  )
}

@Composable
fun LlmAskImageScreen(
  modelManagerViewModel: ModelManagerViewModel,
  navigateUp: () -> Unit,
  modifier: Modifier = Modifier,
  viewModel: LlmAskImageViewModel = hiltViewModel(),
) {
  ChatViewWrapper(
    viewModel = viewModel,
    modelManagerViewModel = modelManagerViewModel,
    taskId = BuiltInTaskId.LLM_ASK_IMAGE,
    navigateUp = navigateUp,
    modifier = modifier,
    showImagePicker = true,
    showAudioPicker = false,
    entryHint = UnifiedChatEntryHint(activateImage = true),
    emptyStateComposable = { model ->
      Box(modifier = Modifier.fillMaxSize()) {
        Column(
          modifier =
            Modifier.align(Alignment.Center).padding(horizontal = 48.dp).padding(bottom = 48.dp),
          horizontalAlignment = Alignment.CenterHorizontally,
          verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
          Text(stringResource(R.string.askimage_emptystate_title), style = emptyStateTitle)
          val contentRes =
            if (model.runtimeType == RuntimeType.AICORE) R.string.askimage_emptystate_content_aicore
            else R.string.askimage_emptystate_content
          Text(
            stringResource(contentRes),
            style = emptyStateContent,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
          )
        }
      }
    },
  )
}

@Composable
fun LlmAskAudioScreen(
  modelManagerViewModel: ModelManagerViewModel,
  navigateUp: () -> Unit,
  modifier: Modifier = Modifier,
  viewModel: LlmAskAudioViewModel = hiltViewModel(),
) {
  ChatViewWrapper(
    viewModel = viewModel,
    modelManagerViewModel = modelManagerViewModel,
    taskId = BuiltInTaskId.LLM_ASK_AUDIO,
    navigateUp = navigateUp,
    modifier = modifier,
    showImagePicker = false,
    showAudioPicker = true,
    entryHint = UnifiedChatEntryHint(activateAudio = true),
    emptyStateComposable = {
      Box(modifier = Modifier.fillMaxSize()) {
        Column(
          modifier =
            Modifier.align(Alignment.Center).padding(horizontal = 48.dp).padding(bottom = 48.dp),
          horizontalAlignment = Alignment.CenterHorizontally,
          verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
          Text(stringResource(R.string.askaudio_emptystate_title), style = emptyStateTitle)
          Text(
            stringResource(R.string.askaudio_emptystate_content),
            style = emptyStateContent,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
          )
        }
      }
    },
  )
}

@Composable
fun ChatViewWrapper(
  viewModel: LlmChatViewModelBase,
  modelManagerViewModel: ModelManagerViewModel,
  taskId: String,
  navigateUp: () -> Unit,
  modifier: Modifier = Modifier,
  onSkillClicked: () -> Unit = {},
  onFirstToken: (Model) -> Unit = {},
  onGenerateResponseDone: (Model) -> Unit = {},
  onResetSessionClickedOverride: ((Task, Model) -> Unit)? = null,
  composableBelowMessageList: @Composable (Model) -> Unit = {},
  emptyStateComposable: @Composable (Model) -> Unit = {},
  allowEditingSystemPrompt: Boolean = false,
  curSystemPrompt: String = "",
  onSystemPromptChanged: (String) -> Unit = {},
  sendMessageTrigger: SendMessageTrigger? = null,
  showImagePicker: Boolean = false,
  showAudioPicker: Boolean = false,
  showTopBar: Boolean = true,
  selectedModelOverride: Model? = null,
  entryHint: UnifiedChatEntryHint = UnifiedChatEntryHint(),
  mcpWidgetHostState: McpWidgetHostState? = null,
  mcpUiSession: McpWidgetSessionHost? = null,
  onMcpWidgetHostStateChange: (McpWidgetHostState) -> Unit = {},
  mcpWidgetFullscreenOverlay:
    @Composable
    (snapshot: McpWidgetSnapshot, session: McpWidgetSessionHost, onClose: () -> Unit) -> Unit =
      { snapshot, session, onClose ->
        McpWidgetFullscreenOverlay(
          snapshot = snapshot,
          session = session,
          onClose = onClose,
        )
      },
) {
  val context = LocalContext.current
  val appContext = context.applicationContext
  val task = modelManagerViewModel.getTaskById(id = taskId)!!
  val allowThinking = task.allowThinking()
  val chatUiState by viewModel.uiState.collectAsState()
  val modelManagerUiState by modelManagerViewModel.uiState.collectAsState()
  val selectedModel = selectedModelOverride ?: modelManagerUiState.selectedModel
  val visibleConnectorIds = entryHint.activateMcpConnectorIds.distinct()
  val sessionId =
    buildUnifiedChatSessionId(
      taskId = taskId,
      modelName = selectedModel.name,
      entryHint = entryHint,
    )
  var unifiedSessionState by
    remember(sessionId, selectedModel.name, visibleConnectorIds) {
      mutableStateOf(
        createUnifiedChatSessionState(
          modelName = selectedModel.name,
          modelDisplayName = selectedModel.displayName,
          taskId = taskId,
          modelCapabilities = selectedModel.toUnifiedChatModelCapabilities(),
          entryHint = entryHint,
          visibleConnectorIds = visibleConnectorIds,
        )
      )
    }
  val chromePolicy = unifiedSessionState.chromePolicy()
  val activeConnectorIds = unifiedSessionState.connectorBarState.activeConnectorIds.toList()
  fun setActiveConnectorIds(connectorIds: List<String>) {
    unifiedSessionState =
      unifiedSessionState.copy(
        connectorBarState =
          ConnectorBarState(
            visibleConnectorIds = visibleConnectorIds,
            activeConnectorIds = connectorIds.toSet(),
          )
      )
  }
  // Foundation scope: only persist the text/MCP unified chat path for now.
  val canPersistUnifiedSession =
    taskId == BuiltInTaskId.LLM_CHAT && !entryHint.activateImage && !entryHint.activateAudio
  val currentMessages = chatUiState.messagesByModel[selectedModel.name]?.toList().orEmpty()
  val sessionFileStore =
    remember(appContext) {
      UnifiedChatSessionFileStore(File(appContext.filesDir, "unified_chat_sessions"))
    }
  val restoredSessionIds = remember { mutableStateMapOf<String, Boolean>() }
  val pendingSnapshotsBySession = remember { mutableStateMapOf<String, PendingUnifiedSessionSnapshot>() }
  val (sessionRestored, setSessionRestored) = remember(sessionId) { mutableStateOf(false) }
  val latestCanPersistUnifiedSession by rememberUpdatedState(canPersistUnifiedSession)
  val latestSessionId by rememberUpdatedState(sessionId)
  val latestSessionRestored by rememberUpdatedState(sessionRestored)
  val latestActiveConnectorIds by rememberUpdatedState(activeConnectorIds.toList())
  val latestSelectedModelName by rememberUpdatedState(selectedModel.name)
  val messagesAtComposition = currentMessages.toList()
  val activeConnectorIdsAtComposition = activeConnectorIds.toList()
  val sessionRestoredAtComposition = sessionRestored

  LaunchedEffect(sessionId, visibleConnectorIds) {
    setSessionRestored(false)
    setActiveConnectorIds(visibleConnectorIds)
  }

  LaunchedEffect(sessionId, canPersistUnifiedSession) {
    if (!canPersistUnifiedSession) {
      restoredSessionIds[sessionId] = true
      setSessionRestored(true)
      return@LaunchedEffect
    }

    if (restoredSessionIds[sessionId] == true) {
      restoredSessionIds[sessionId] = true
      setSessionRestored(true)
      return@LaunchedEffect
    }

    val restoredSession = withContext(Dispatchers.IO) { sessionFileStore.load(sessionId) }
    restoredSessionIds[sessionId] = true
    if (restoredSession == null) {
      setSessionRestored(true)
      return@LaunchedEffect
    }

    val currentMessagesBeforeRestore =
      viewModel.uiState.value.messagesByModel[selectedModel.name]?.toList().orEmpty()
    if (
      !shouldRestorePersistedUnifiedSession(
        hasHandledRestoreForSession = false,
        currentMessages = currentMessagesBeforeRestore,
      )
    ) {
      setSessionRestored(true)
      return@LaunchedEffect
    }

    val restoredMessages = restoredSession.messagesJson.mapNotNull(::decodePersistedChatMessage)
    val restoredSnapshotsInTranscript =
      restoredMessages.filterIsInstance<ChatMessageMcpWidgetCard>().map { it.snapshot }.toSet()
    val synthesizedWidgetCards =
      restoredSession.widgetSnapshots
        .filterNot(restoredSnapshotsInTranscript::contains)
        .map(::createDormantWidgetCard)

    viewModel.clearAllMessages(selectedModel)
    (restoredMessages + synthesizedWidgetCards).forEach { restoredMessage ->
      viewModel.addMessage(model = selectedModel, message = restoredMessage)
    }
    setActiveConnectorIds(restoredSession.activeConnectorIds.distinct())
    setSessionRestored(true)
  }

  LaunchedEffect(
    sessionId,
    canPersistUnifiedSession,
    sessionRestored,
    currentMessages,
    activeConnectorIds,
  ) {
    pendingSnapshotsBySession[sessionId] =
      PendingUnifiedSessionSnapshot(
        messages = currentMessages.toList(),
        activeConnectorIds = activeConnectorIds.toList(),
        sessionRestored = sessionRestored,
      )

    if (!canPersistUnifiedSession || !sessionRestored) {
      return@LaunchedEffect
    }

    val messagesToPersist = currentMessages.toList()
    val connectorIdsToPersist = activeConnectorIds.toList()
    delay(UNIFIED_CHAT_SESSION_SAVE_DEBOUNCE_MS)

    withContext(Dispatchers.IO) {
      persistUnifiedSessionSnapshot(
        sessionFileStore = sessionFileStore,
        sessionId = sessionId,
        messages = messagesToPersist,
        activeConnectorIds = connectorIdsToPersist,
      )
    }
  }

  DisposableEffect(sessionFileStore) {
    onDispose {
      if (!latestCanPersistUnifiedSession || !latestSessionRestored) {
        return@onDispose
      }

      val pendingSnapshot = pendingSnapshotsBySession[latestSessionId]
      val messagesToPersist =
        pendingSnapshot?.messages
          ?: viewModel.uiState.value.messagesByModel[latestSelectedModelName]?.toList().orEmpty()
      val connectorIdsToPersist =
        pendingSnapshot?.activeConnectorIds ?: latestActiveConnectorIds.toList()
      CoroutineScope(Dispatchers.IO).launch {
        persistUnifiedSessionSnapshot(
          sessionFileStore = sessionFileStore,
          sessionId = latestSessionId,
          messages = messagesToPersist,
          activeConnectorIds = connectorIdsToPersist,
        )
      }
    }
  }

  DisposableEffect(sessionId, sessionFileStore) {
    onDispose {
      val pendingSnapshot = pendingSnapshotsBySession[sessionId]
      if (
        !canPersistUnifiedSession ||
          !(pendingSnapshot?.sessionRestored ?: sessionRestoredAtComposition)
      ) {
        return@onDispose
      }

      CoroutineScope(Dispatchers.IO).launch {
        persistUnifiedSessionSnapshot(
          sessionFileStore = sessionFileStore,
          sessionId = sessionId,
          messages = pendingSnapshot?.messages ?: messagesAtComposition,
          activeConnectorIds = pendingSnapshot?.activeConnectorIds ?: activeConnectorIdsAtComposition,
        )
      }
    }
  }

  val connectorBarContent: (@Composable () -> Unit)? =
    if (chromePolicy.showInlineConnectorRowAboveComposer) {
      {
        ConnectorBar(
          state = unifiedSessionState.connectorBarState,
          onConnectorClicked = { connectorId ->
            if (!sessionRestored) {
              return@ConnectorBar
            }
            unifiedSessionState = unifiedSessionState.toggleConnector(connectorId)
          },
          onOpenConnectorSheet = {},
          displayMode = ConnectorBarDisplayMode.InlineRow,
        )
      }
    } else {
      null
    }

  ChatView(
    task = task,
    viewModel = viewModel,
    modelManagerViewModel = modelManagerViewModel,
    onSendMessage = { model, messages ->
      if (!sessionRestored) {
        return@ChatView
      }
      for (message in messages) {
        viewModel.addMessage(model = model, message = message)
      }

      var text = ""
      val images: MutableList<Bitmap> = mutableListOf()
      val audioMessages: MutableList<ChatMessageAudioClip> = mutableListOf()
      var chatMessageText: ChatMessageText? = null
      for (message in messages) {
        if (message is ChatMessageText) {
          chatMessageText = message
          text = message.content
        } else if (message is ChatMessageImage) {
          images.addAll(message.bitmaps)
        } else if (message is ChatMessageAudioClip) {
          audioMessages.add(message)
        }
      }
      if ((text.isNotEmpty() && chatMessageText != null) || images.isNotEmpty() || audioMessages.isNotEmpty()) {
        val effectiveInputText =
          text.ifBlank {
            if (images.isNotEmpty() || audioMessages.isNotEmpty()) {
              "Please describe the attached input."
            } else {
              ""
            }
          }
        if (text.isNotEmpty()) {
          modelManagerViewModel.addTextInputHistory(text)
        }
        val attachmentCount = images.size + audioMessages.size
        val activeSkillIdsForTurn = unifiedSessionState.agentSkillState.activeSkillIds.toList()
        val connectorIdsForTurn = activeConnectorIds.toList()
        val hasPreexistingAgentContext = mcpUiSession.hasAgentReadableContext()
        viewModel.beginAgentTurn(
          model = model,
          userPrompt = effectiveInputText,
          attachmentCount = attachmentCount,
          activeSkillIds = activeSkillIdsForTurn,
          activeConnectorIds = connectorIdsForTurn,
        )
        planAgentTurnOpeningEvents(
            route = androidAgentTurnRoute(connectorIds = connectorIdsForTurn),
            attachmentCount = attachmentCount,
            shouldReadVisibleContext = hasPreexistingAgentContext,
            connectorSearchTitle = null,
          )
          .events
          .forEach { event -> viewModel.applyAgentTurnEvent(model = model, event = event) }
        CoroutineScope(Dispatchers.IO).launch {
          val attachmentVfsContext =
            ingestUserAttachmentsToAgentVfs(
              context = context,
              sessionId = sessionId,
              images = images,
              audioMessages = audioMessages,
            )
          withContext(Dispatchers.Main) {
            if (!hasPreexistingAgentContext && attachmentVfsContext.isNotBlank()) {
              viewModel.applyAgentTurnEvent(
                model = model,
                event = agentTurnEventReadVisibleContext(),
              )
            }
            if (connectorIdsForTurn.isNotEmpty()) {
              val connectorTitle = androidConnectorSearchTitle(connectorIdsForTurn)
              viewModel.applyAgentTurnEvent(
                model = model,
                event = agentTurnEventSearchTools(connectorTitle),
              )
              viewModel.applyAgentTurnEvent(
                model = model,
                event = agentTurnEventSkipToolSearch(connectorTitle),
              )
            }
            viewModel.applyAgentTurnEvent(
              model = model,
              event = agentTurnEventGenerateFinalAnswer(agentTurnFinalAnswerSourceModel()),
            )
            viewModel.generateResponse(
              model = model,
              input = effectiveInputText.withAgentVfsContext(mcpUiSession, attachmentVfsContext),
              images = images,
              audioMessages = audioMessages,
              onFirstToken = onFirstToken,
              onDone = {
                onGenerateResponseDone(model)
                viewModel.completeAgentTurn(model = model, outcome = agentTurnOutcomeAnswered())
              },
              onError = { errorMessage ->
                viewModel.failAgentTurn(
                  model = model,
                  reason = errorMessage.ifBlank { "Model inference failed" },
                )
                viewModel.handleError(
                  context = context,
                  task = task,
                  model = model,
                  errorMessage = errorMessage,
                  modelManagerViewModel = modelManagerViewModel,
                )
              },
              allowThinking = allowThinking,
            )

            firebaseAnalytics?.logEvent(
              GalleryEvent.GENERATE_ACTION.id,
              bundleOf("capability_name" to task.id, "model_id" to model.name),
            )
          }
        }
      }
    },
    onRunAgainClicked = { model, message ->
      if (message is ChatMessageText) {
        viewModel.runAgain(
          model = model,
          message = message,
          onError = { errorMessage ->
            viewModel.handleError(
              context = context,
              task = task,
              model = model,
              errorMessage = errorMessage,
              modelManagerViewModel = modelManagerViewModel,
            )
          },
          allowThinking = allowThinking,
        )
      }
    },
    onBenchmarkClicked = { _, _, _, _ -> },
    onResetSessionClicked = { model ->
      if (onResetSessionClickedOverride != null) {
        onResetSessionClickedOverride(task, model)
      } else {
        viewModel.resetSession(
          task = task,
          model = model,
          supportImage = showImagePicker,
          supportAudio = showAudioPicker,
        )
      }
    },
    showStopButtonInInputWhenInProgress = true,
    onStopButtonClicked = { model ->
      viewModel.cancelAgentTurn(model = model, reason = "User stopped generation")
      viewModel.stopResponse(model = model)
    },
    onSkillClicked = onSkillClicked,
    navigateUp = navigateUp,
    modifier = modifier,
    composableBelowMessageList = composableBelowMessageList,
    showImagePicker = showImagePicker,
    emptyStateComposable = emptyStateComposable,
    allowEditingSystemPrompt = allowEditingSystemPrompt,
    curSystemPrompt = curSystemPrompt,
    onSystemPromptChanged = onSystemPromptChanged,
    sendMessageTrigger = sendMessageTrigger,
    showAudioPicker = showAudioPicker,
    showStandaloneAudioRecordButtonInComposer =
      chromePolicy.showStandaloneAudioRecordButtonInComposer,
    showTopBar = showTopBar,
    selectedModelOverride = selectedModelOverride,
    showConversationHistoryButton = chromePolicy.showInputHistoryInTopBar,
    connectorBarContent = connectorBarContent,
    mcpWidgetHostState = mcpWidgetHostState,
    mcpUiSession = mcpUiSession,
    onMcpWidgetHostStateChange = onMcpWidgetHostStateChange,
    mcpWidgetFullscreenOverlay = mcpWidgetFullscreenOverlay,
  )
}

private fun androidAgentTurnRoute(connectorIds: List<String>): AgentTurnRoute =
  when (connectorIds.size) {
    0 -> agentTurnRouteModel()
    1 ->
      agentTurnRouteMcpConnector(
        id = connectorIds.single(),
        title = androidConnectorTitle(connectorIds.single()),
      )
    else -> agentTurnRouteMcpConnectors(count = connectorIds.size)
  }

private fun androidConnectorSearchTitle(connectorIds: List<String>): String =
  when (connectorIds.size) {
    0 -> "MCP"
    1 -> androidConnectorTitle(connectorIds.single())
    else -> "Active MCP connectors"
  }

private fun androidConnectorTitle(connectorId: String): String =
  when (connectorId) {
    "fortune.ugot.uk/mcp" -> "UGOT Fortune"
    else ->
      connectorId
        .split('_', '-')
        .filter { it.isNotBlank() }
        .joinToString(" ") { token ->
          token.lowercase().replaceFirstChar { firstChar -> firstChar.titlecase() }
        }
  }

private fun McpWidgetSessionHost?.hasAgentReadableContext(): Boolean =
  ((this as? McpUiSession)?.getAgentVfsContextSummary())
    ?.trim()
    ?.takeIf { it.isNotBlank() && it != "Available agent files: none" } != null

private fun String.withAgentVfsContext(
  mcpUiSession: McpWidgetSessionHost?,
  userAttachmentSummary: String = "",
): String {
  val summaries =
    listOf(
        (mcpUiSession as? McpUiSession)?.getAgentVfsContextSummary().orEmpty(),
        userAttachmentSummary,
      )
      .map { it.trim() }
      .filter { it.isNotBlank() && it != "Available agent files: none" }
  if (summaries.isEmpty()) {
    return this
  }
  val summary = summaries.joinToString(separator = "\n\n")
  return """
Relevant agent workspace files from MCP tools and user attachments are available below. Use them when the user asks about the current widget, resources, files, attachments, or previous tool output.

$summary

User message:
$this
""".trimIndent()
}

private fun ingestUserAttachmentsToAgentVfs(
  context: Context,
  sessionId: String,
  images: List<Bitmap>,
  audioMessages: List<ChatMessageAudioClip>,
): String {
  if (images.isEmpty() && audioMessages.isEmpty()) {
    return ""
  }
  return runCatching {
      val vfs =
        AgentVfsFactory.createSystem(File(context.filesDir, "agent_vfs").absolutePath) {
          System.currentTimeMillis()
        }
      val ingestor = AgentVfsUserAttachmentIngestor(vfs)
      images.forEachIndexed { index, bitmap ->
        val output = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.JPEG, 88, output)
        ingestor.ingestDefault(
          sessionId = sessionId,
          fileName = "image-${index + 1}.jpg",
          mimeType = "image/jpeg",
          text = null,
          blobBase64 = Base64.encodeToString(output.toByteArray(), Base64.NO_WRAP),
          externalUri = null,
          overwrite = false,
        )
      }
      audioMessages.forEachIndexed { index, audio ->
        ingestor.ingestDefault(
          sessionId = sessionId,
          fileName = "audio-${index + 1}.wav",
          mimeType = "audio/wav",
          text = null,
          blobBase64 = Base64.encodeToString(audio.genByteArrayForWav(), Base64.NO_WRAP),
          externalUri = null,
          overwrite = false,
        )
      }
      val sanitizedSessionId = AgentVfsPaths.sanitizeOpaqueSegment(sessionId, fallback = "session")
      vfs.contextSummary("/session/$sanitizedSessionId")
    }
    .getOrDefault("")
}

internal fun shouldRestorePersistedUnifiedSession(
  hasHandledRestoreForSession: Boolean,
  currentMessages: List<ChatMessage>,
): Boolean = !hasHandledRestoreForSession && currentMessages.isEmpty()

private fun persistUnifiedSessionSnapshot(
  sessionFileStore: UnifiedChatSessionFileStore,
  sessionId: String,
  messages: List<ChatMessage>,
  activeConnectorIds: List<String>,
) {
  val persistedWidgetSnapshots = messages.collectPersistedWidgetSnapshots()
  val encodedMessages = messages.mapNotNull(::encodePersistableChatMessage)
  if (
    encodedMessages.isEmpty() &&
      activeConnectorIds.isEmpty() &&
      persistedWidgetSnapshots.isEmpty()
  ) {
    sessionFileStore.delete(sessionId)
    return
  }

  sessionFileStore.save(
    UnifiedChatPersistedSession(
      id = sessionId,
      title = deriveConversationTitleFromUnifiedMessages(messages.toUnifiedChatMessages()),
      activeAgentSkillIds = emptyList(),
      activeConnectorIds = activeConnectorIds,
      messagesJson = encodedMessages,
      widgetSnapshots = persistedWidgetSnapshots,
    )
  )
}

private fun List<ChatMessage>.collectPersistedWidgetSnapshots(): List<McpWidgetSnapshot> =
  filterIsInstance<ChatMessageMcpWidgetCard>().map { it.snapshot }.distinct()

private fun createDormantWidgetCard(snapshot: McpWidgetSnapshot): ChatMessageMcpWidgetCard =
  ChatMessageMcpWidgetCard(
    connectorId = snapshot.connectorId,
    title = snapshot.title,
    summary = snapshot.summary,
    snapshot = snapshot,
  )
