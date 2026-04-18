package com.google.ai.edge.gallery.customtasks.sajug

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import com.google.ai.edge.gallery.data.Model
import com.google.ai.edge.gallery.ui.common.chat.ChatMessage
import com.google.ai.edge.gallery.ui.common.chat.ChatSide
import com.google.ai.edge.gallery.ui.common.chat.ChatMessageText
import com.google.ai.edge.gallery.ui.llmchat.LlmChatScreen
import com.google.ai.edge.gallery.ui.llmchat.LlmChatViewModel
import com.google.ai.edge.gallery.ui.mcp.McpUiSession
import com.google.ai.edge.gallery.ui.modelmanager.ModelInitializationStatusType
import com.google.ai.edge.gallery.ui.modelmanager.ModelManagerViewModel
import com.google.ai.edge.gallery.ui.unifiedchat.UnifiedChatEntryHint
import com.google.ai.edge.gallery.ui.unifiedchat.mcp.McpWidgetHostState
import com.google.ai.edge.gallery.ui.unifiedchat.messages.ChatMessageMcpWidgetCard

private const val UGOT_FORTUNE_CONNECTOR_ID = "ugot_fortune"
private const val UGOT_FORTUNE_BOOTSTRAP_SUMMARY =
  "Hosted Fortune MCP widget connected in the shared chat shell."

@Composable
internal fun SajugTaskScreen(
  modelManagerViewModel: ModelManagerViewModel,
  selectedModel: Model?,
  onNavigateUp: () -> Unit,
  setTopBarVisible: (Boolean) -> Unit,
  viewModel: LlmChatViewModel = hiltViewModel(),
) {
  val modelManagerUiState by modelManagerViewModel.uiState.collectAsState()
  val routeModel = selectedModel ?: modelManagerUiState.selectedModel
  val initializationStatus = modelManagerUiState.modelInitializationStatus[routeModel.name]?.status
  val session = routeModel.instance as? McpUiSession
  val messages = viewModel.uiState.collectAsState().value.messagesByModel[routeModel.name].orEmpty()
  var hostState by remember(routeModel.name) { mutableStateOf(McpWidgetHostState()) }

  LaunchedEffect(Unit) { setTopBarVisible(false) }
  DisposableEffect(Unit) { onDispose { setTopBarVisible(true) } }

  LaunchedEffect(session, routeModel.name) {
    if (session == null) {
      hostState = hostState.close()
    }
  }

  LaunchedEffect(routeModel.name, messages) {
    if (shouldClearBootstrapOnlyFortuneTranscript(messages)) {
      viewModel.clearAllMessages(routeModel)
    }
  }

  LlmChatScreen(
    modelManagerViewModel = modelManagerViewModel,
    navigateUp = onNavigateUp,
    taskId = UGOT_FORTUNE_TASK_ID,
    viewModel = viewModel,
    entryHint =
      UnifiedChatEntryHint(activateMcpConnectorIds = listOf(UGOT_FORTUNE_CONNECTOR_ID)),
    emptyStateComposable = {
      Box(modifier = Modifier.fillMaxSize()) {
        val message =
          if (initializationStatus == ModelInitializationStatusType.INITIALIZING) {
            "Starting UGOT Fortune connector…"
          } else {
            "UGOT Fortune MCP session is not ready."
          }
        Text(
          text = message,
          modifier = Modifier.align(Alignment.Center).padding(24.dp),
          color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
      }
    },
    showTopBar = false,
    mcpWidgetHostState = hostState,
    mcpUiSession = session,
    onMcpWidgetHostStateChange = { hostState = it },
  )
}

internal fun shouldClearBootstrapOnlyFortuneTranscript(messages: List<ChatMessage>): Boolean {
  if (messages.size != 1) {
    return false
  }

  val onlyMessage = messages.single()
  if (onlyMessage is ChatMessageText) {
    return false
  }

  return onlyMessage is ChatMessageMcpWidgetCard &&
    onlyMessage.connectorId == UGOT_FORTUNE_CONNECTOR_ID &&
    onlyMessage.summary == UGOT_FORTUNE_BOOTSTRAP_SUMMARY &&
    onlyMessage.side == ChatSide.AGENT
}
