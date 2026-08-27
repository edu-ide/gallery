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

package com.google.ai.edge.gallery.ui.common.chat

import android.graphics.Bitmap
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.VisibilityThreshold
import androidx.compose.animation.core.spring
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.slideInVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.nestedscroll.NestedScrollConnection
import androidx.compose.ui.input.nestedscroll.NestedScrollSource
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.google.ai.edge.gallery.R
import com.google.ai.edge.gallery.data.BuiltInTaskId
import com.google.ai.edge.gallery.data.Model
import com.google.ai.edge.gallery.data.Task
import com.google.ai.edge.gallery.ui.common.AudioAnimation
import com.google.ai.edge.gallery.ui.common.ErrorDialog
import com.google.ai.edge.gallery.ui.common.FloatingBanner
import com.google.ai.edge.gallery.ui.common.RotationalLoader
import com.google.ai.edge.gallery.ui.common.humanReadableDuration
import com.google.ai.edge.gallery.ui.unifiedchat.messages.ChatMessageMcpWidgetCard
import com.google.ai.edge.gallery.ui.unifiedchat.messages.MessageBodyMcpWidgetCard
import com.google.ai.edge.gallery.ui.modelmanager.ModelInitializationStatusType
import com.google.ai.edge.gallery.ui.modelmanager.ModelManagerViewModel
import com.ugot.chatkit.ui.ChatTurnActivity
import com.ugot.chatkit.ui.ChatTurnActivityUiState
import com.ugot.chatkit.ui.ChatTimeline
import com.ugot.chatkit.ui.ChatMessageActionUi
import com.ugot.chatkit.ui.ChatRole
import com.ugot.chatkit.ui.UgotChatExperienceScaffold
import com.ugot.chatkit.ui.UgotChatMessageFrame
import kotlinx.coroutines.delay

/** Composable function for the main chat panel, displaying messages and handling user input. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ChatPanel(
  modelManagerViewModel: ModelManagerViewModel,
  task: Task,
  selectedModel: Model,
  viewModel: ChatViewModel,
  innerPadding: PaddingValues,
  onSendMessage: (Model, List<ChatMessage>) -> Unit,
  onRunAgainClicked: (Model, ChatMessage) -> Unit,
  onBenchmarkClicked: (Model, ChatMessage, warmUpIterations: Int, benchmarkIterations: Int) -> Unit,
  navigateUp: () -> Unit,
  modifier: Modifier = Modifier,
  onStreamImageMessage: (Model, ChatMessageImage) -> Unit = { _, _ -> },
  onStreamEnd: (Int) -> Unit = {},
  onStopButtonClicked: () -> Unit = {},
  onSkillClicked: () -> Unit = {},
  onImageSelected: (bitmaps: List<Bitmap>, selectedBitmapIndex: Int) -> Unit = { _, _ -> },
  showStopButtonInInputWhenInProgress: Boolean = false,
  showImagePicker: Boolean = false,
  showAudioPicker: Boolean = false,
  showStandaloneAudioRecordButtonInComposer: Boolean = false,
  emptyStateComposable: @Composable (Model) -> Unit = {},
  connectorBarContent: (@Composable () -> Unit)? = null,
  onMcpWidgetResumeClicked: (ChatMessageMcpWidgetCard) -> Unit = {},
  onMcpWidgetExpandClicked: (ChatMessageMcpWidgetCard) -> Unit = {},
) {
  val uiState by viewModel.uiState.collectAsState()
  val modelManagerUiState by modelManagerViewModel.uiState.collectAsState()
  val messages = uiState.messagesByModel[selectedModel.name] ?: listOf()
  val agentTurnActivity = uiState.agentTurnsByModel[selectedModel.name]?.activity
  val streamingMessage = uiState.streamingMessagesByModel[selectedModel.name]
  val snackbarHostState = remember { SnackbarHostState() }
  val scope = rememberCoroutineScope()
  val haptic = LocalHapticFeedback.current
  val imageCountToLastConfigChange =
    remember(messages) {
      var imageCount = 0
      for (message in messages.reversed()) {
        if (message is ChatMessageConfigValuesChange) {
          break
        }
        if (message is ChatMessageImage) {
          imageCount += message.bitmaps.size
        }
      }
      imageCount
    }
  val audioClipMesssageCountToLastconfigChange =
    remember(messages) {
      var audioClipMessageCount = 0
      for (message in messages.reversed()) {
        if (message is ChatMessageConfigValuesChange) {
          break
        }
        if (message is ChatMessageAudioClip) {
          audioClipMessageCount++
        }
      }
      audioClipMessageCount
    }

  var curMessage by remember { mutableStateOf("") } // Correct state
  val focusManager = LocalFocusManager.current

  // Remember the LazyListState to control scrolling
  val listState = rememberLazyListState()
  val density = LocalDensity.current
  var showBenchmarkConfigsDialog by remember { mutableStateOf(false) }
  val benchmarkMessage: MutableState<ChatMessage?> = remember { mutableStateOf(null) }

  var showErrorDialog by remember { mutableStateOf(false) }

  var showAudioRecorder by remember { mutableStateOf(false) }
  var curAmplitude by remember { mutableIntStateOf(0) }
  var pickedImagesCount by remember { mutableIntStateOf(0) }
  var pickedAudioClipsCount by remember { mutableIntStateOf(0) }

  var showImageLimitBanner by remember { mutableStateOf(false) }

  LaunchedEffect(showImageLimitBanner) {
    if (showImageLimitBanner) {
      delay(3000) // 3 seconds
      showImageLimitBanner = false
    }
  }

  // Keep track of the last message and last message content.
  val lastMessage: MutableState<ChatMessage?> = remember { mutableStateOf(null) }
  val lastMessageContent: MutableState<String> = remember { mutableStateOf("") }
  if (messages.isNotEmpty()) {
    val tmpLastMessage = messages.last()
    lastMessage.value = tmpLastMessage
    if (tmpLastMessage is ChatMessageText) {
      lastMessageContent.value = tmpLastMessage.content
    }
  }

  // Scroll to bottom when IME is toggled.
  LaunchedEffect(WindowInsets.ime.getBottom(density)) {
    scrollToBottom(listState = listState, animate = true)
  }

  // Auto-scroll to bottom when a new message is added or message type changes.
  LaunchedEffect(messages.size, lastMessage.value?.type) {
    if (messages.isNotEmpty()) {
      scrollToBottom(listState = listState, animate = true)
    }
  }

  // Scroll to keep up with streaming, ONLY if we are already at the bottom.
  LaunchedEffect(lastMessage.value, lastMessageContent.value, lastMessage.value?.latencyMs) {
    if (messages.isNotEmpty()) {
      val lastVisibleItem = listState.layoutInfo.visibleItemsInfo.lastOrNull()
      if (lastVisibleItem != null) {
        // Determines if an automatic scroll is necessary. It is true if the scroll position is
        // close to the bottom (within 90 pixels of the end offset. 90 is slightly taller than
        // the "show stats" chip).
        val canScroll =
          lastVisibleItem.index == messages.size - 1 &&
            lastVisibleItem.offset + lastVisibleItem.size - listState.layoutInfo.viewportEndOffset <
              90
        if (canScroll) {
          scrollToBottom(listState = listState, animate = true)
        }
      }
    }
  }

  val nestedScrollConnection = remember {
    object : NestedScrollConnection {
      override fun onPreScroll(available: Offset, source: NestedScrollSource): Offset {
        // If downward scroll, clear the focus from any currently focused composable.
        // This is useful for dismissing software keyboards or hiding text input fields
        // when the user starts scrolling down a list.
        if (available.y > 0) {
          focusManager.clearFocus()
        }
        // Let LazyColumn handle the scroll
        return Offset.Zero
      }
    }
  }

  val modelInitializationStatus = modelManagerUiState.modelInitializationStatus[selectedModel.name]

  LaunchedEffect(modelInitializationStatus) {
    showErrorDialog = modelInitializationStatus?.status == ModelInitializationStatusType.ERROR
  }

  Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.BottomCenter) {
    // Audio record animation.
    AnimatedVisibility(
      showAudioRecorder,
      enter =
        slideInVertically(
          animationSpec =
            spring(
              stiffness = Spring.StiffnessLow,
              visibilityThreshold = IntOffset.VisibilityThreshold,
            )
        ) {
          it
        } + fadeIn(animationSpec = spring(stiffness = Spring.StiffnessLow)),
      exit = fadeOut(),
      modifier = Modifier.graphicsLayer { alpha = 0.8f },
    ) {
      AudioAnimation(bgColor = MaterialTheme.colorScheme.surface, amplitude = curAmplitude)
    }

    UgotChatExperienceScaffold(
      modifier = modifier.padding(innerPadding).consumeWindowInsets(innerPadding).imePadding(),
      transcript = {
      Box(contentAlignment = Alignment.BottomCenter, modifier = Modifier.fillMaxSize()) {
        val cdChatPanel = stringResource(R.string.cd_chat_panel)
        ChatTimeline(
          items = messages,
          modifier =
            Modifier.fillMaxSize().nestedScroll(nestedScrollConnection).semantics {
              contentDescription = cdChatPanel
            },
          state = listState,
          verticalArrangement = Arrangement.Top,
        ) { index, message ->
            val imageHistoryCurIndex = remember { mutableIntStateOf(0) }
            val role =
              when (message.side) {
                ChatSide.USER -> ChatRole.USER
                ChatSide.AGENT -> ChatRole.ASSISTANT
                ChatSide.SYSTEM -> ChatRole.SYSTEM
              }
            var agentName = stringResource(task.agentNameRes)
            if (message.accelerator.isNotEmpty()) {
              agentName = "$agentName on ${message.accelerator}"
            }
            val senderLabel =
              when (message.side) {
                ChatSide.USER -> stringResource(R.string.chat_you)
                ChatSide.AGENT -> agentName
                ChatSide.SYSTEM -> null
              }
            val runAgainLabel = stringResource(R.string.run_again)
            val benchmarkLabel = stringResource(R.string.run_benchmark)
            val actions =
              if (message.side == ChatSide.USER) {
                buildList {
                  if (selectedModel.showRunAgainButton) {
                    add(ChatMessageActionUi("run_again", runAgainLabel, !uiState.inProgress))
                  }
                  if (selectedModel.showBenchmarkButton) {
                    add(ChatMessageActionUi("benchmark", benchmarkLabel, !uiState.inProgress))
                  }
                }
              } else {
                emptyList()
              }
            val bubbleEnabled =
              !message.disableBubbleShape &&
                message.type !in
                  setOf(
                    ChatMessageType.INFO,
                    ChatMessageType.WARNING,
                    ChatMessageType.ERROR,
                    ChatMessageType.CONFIG_VALUES_CHANGE,
                    ChatMessageType.PROMPT_TEMPLATES,
                    ChatMessageType.IMAGE,
                  )

            UgotChatMessageFrame(
              role = role,
              senderLabel = senderLabel,
              timestampLabel = null,
              metadataLabel =
                if (message.side == ChatSide.AGENT && message.latencyMs >= 0) {
                  message.latencyMs.humanReadableDuration()
                } else {
                  null
                },
              actions = actions,
              showSenderLabel = !message.hideSenderLabel,
              showTimestamp = false,
              showActions = true,
              bubbleEnabled = bubbleEnabled,
              onActionClicked = { actionId ->
                when (actionId) {
                  "run_again" -> onRunAgainClicked(selectedModel, message)
                  "benchmark" -> {
                    showBenchmarkConfigsDialog = true
                    benchmarkMessage.value = message
                  }
                }
              },
            ) {
              when (message) {
                is ChatMessageLoading -> MessageBodyLoading(message = message)
                is ChatMessageInfo -> MessageBodyInfo(message = message)
                is ChatMessageWarning -> MessageBodyWarning(message = message)
                is ChatMessageError -> MessageBodyError(message = message)
                is ChatMessageConfigValuesChange -> MessageBodyConfigUpdate(message = message)
                is ChatMessagePromptTemplates ->
                  MessageBodyPromptTemplates(
                    message = message,
                    task = task,
                    onPromptClicked = { template ->
                      onSendMessage(
                        selectedModel,
                        listOf(ChatMessageText(content = template.prompt, side = ChatSide.USER)),
                      )
                    },
                  )
                is ChatMessageText ->
                  MessageBodyText(message = message, inProgress = uiState.inProgress)
                is ChatMessageImage ->
                  MessageBodyImage(message = message, onImageClicked = onImageSelected)
                is ChatMessageImageWithHistory ->
                  MessageBodyImageWithHistory(
                    message = message,
                    imageHistoryCurIndex = imageHistoryCurIndex,
                  )
                is ChatMessageAudioClip -> MessageBodyAudioClip(message = message)
                is ChatMessageClassification ->
                  MessageBodyClassification(
                    message = message,
                    modifier = Modifier.width(message.maxBarWidth ?: CLASSIFICATION_BAR_MAX_WIDTH),
                  )
                is ChatMessageBenchmarkResult -> MessageBodyBenchmark(message = message)
                is ChatMessageBenchmarkLlmResult ->
                  MessageBodyBenchmarkLlm(message = message, modifier = Modifier.wrapContentWidth())
                is ChatMessageWebView -> MessageBodyWebview(message = message)
                is ChatMessageMcpWidgetCard ->
                  MessageBodyMcpWidgetCard(
                    message = message,
                    onExpandClicked = onMcpWidgetExpandClicked,
                    onResumeClicked = onMcpWidgetResumeClicked,
                  )
                is ChatMessageCollapsableProgressPanel ->
                  MessageBodyCollapsableProgressPanel(message = message)
                is ChatMessageThinking ->
                  MessageBodyThinking(
                    thinkingText = message.content,
                    inProgress = message.inProgress,
                  )
              }
            }
        }

        SnackbarHost(hostState = snackbarHostState, modifier = Modifier.padding(vertical = 4.dp))

        // Show empty state.
        if (messages.isEmpty() && pickedImagesCount == 0 && pickedAudioClipsCount == 0) {
          emptyStateComposable(selectedModel)
        }
        // Loading screen when model is initialized for that first time.
        val isFirstInitializing =
          modelInitializationStatus?.status == ModelInitializationStatusType.INITIALIZING &&
            modelInitializationStatus.isFirstInitialization(selectedModel)
        Column(
          horizontalAlignment = Alignment.CenterHorizontally,
          verticalArrangement = Arrangement.Center,
        ) {
          AnimatedVisibility(
            isFirstInitializing,
            enter = fadeIn() + scaleIn(initialScale = 0.9f),
            exit = fadeOut() + scaleOut(targetScale = 0.9f),
          ) {
            Box(modifier = Modifier.background(MaterialTheme.colorScheme.surface).fillMaxSize()) {
              Column(
                modifier = Modifier.align(Alignment.Center),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(8.dp),
              ) {
                RotationalLoader(size = 32.dp)
                Text(
                  stringResource(R.string.aichat_initializing_title),
                  style =
                    MaterialTheme.typography.headlineLarge.copy(
                      fontSize = 24.sp,
                      fontWeight = FontWeight.Bold,
                    ),
                )
                Text(
                  stringResource(R.string.aichat_initializing_content),
                  style = MaterialTheme.typography.bodyMedium,
                  color = MaterialTheme.colorScheme.onSurfaceVariant,
                  textAlign = TextAlign.Center,
                )
              }
            }
          }
        }

        FloatingBanner(
          visible = showImageLimitBanner,
          text = stringResource(R.string.aicore_image_limit_message),
          modifier =
            Modifier.align(Alignment.TopCenter).padding(horizontal = 16.dp, vertical = 8.dp),
        )
      }

      },
      activity = {
      AnimatedVisibility(
        visible = agentTurnActivity != null,
        enter = fadeIn(),
        exit = fadeOut(),
      ) {
        agentTurnActivity?.let { activity ->
          ChatTurnActivity(
            activity =
              ChatTurnActivityUiState(
                title = activity.title,
                detail = activity.detail,
                showsProgress = activity.showsProgress,
              ),
          )
        }
      }

      },
      composer = {
      MessageInputText(
        task = task,
        modelManagerViewModel = modelManagerViewModel,
        curMessage = curMessage,
        inProgress = uiState.inProgress,
        isResettingSession = uiState.isResettingSession,
        modelPreparing = uiState.preparing,
        imageCount = imageCountToLastConfigChange,
        audioClipMessageCount = audioClipMesssageCountToLastconfigChange,
        modelInitializing =
          modelInitializationStatus?.status == ModelInitializationStatusType.INITIALIZING,
        textFieldPlaceHolderRes = task.textInputPlaceHolderRes,
        onValueChanged = { curMessage = it },
        onSendMessage = {
          onSendMessage(selectedModel, it)
          curMessage = ""
          // Hide software keyboard.
          focusManager.clearFocus()
        },
        onOpenPromptTemplatesClicked = {
          onSendMessage(
            selectedModel,
            listOf(
              ChatMessagePromptTemplates(
                templates = selectedModel.llmPromptTemplates,
                showMakeYourOwn = false,
              )
            ),
          )
        },
        onStopButtonClicked = onStopButtonClicked,
        onSetAudioRecorderVisible = { start ->
          showAudioRecorder = start
          if (!showAudioRecorder) {
            curAmplitude = 0
          }
        },
        onAmplitudeChanged = { curAmplitude = it },
        onSkillsClicked = onSkillClicked,
        onPickedImagesChanged = { pickedImagesCount = it.size },
        onPickedAudioClipsChanged = { pickedAudioClipsCount = it.size },
        showPromptTemplatesInMenu = false,
        showSkillsPicker = task.id === BuiltInTaskId.LLM_AGENT_CHAT,
        showImagePicker = showImagePicker,
        showAudioPicker = showAudioPicker,
        showStandaloneAudioRecordButton = showStandaloneAudioRecordButtonInComposer,
        showStopButtonWhenInProgress = showStopButtonInInputWhenInProgress,
        onImageLimitExceeded = { showImageLimitBanner = true },
        extraTopContent = connectorBarContent,
      )
      },
    )
  }

  // Error dialog.
  if (showErrorDialog) {
    ErrorDialog(
      error = modelInitializationStatus?.error ?: "",
      onDismiss = { showErrorDialog = false },
    )
  }

  // Benchmark config dialog.
  if (showBenchmarkConfigsDialog) {
    BenchmarkConfigDialog(
      onDismissed = { showBenchmarkConfigsDialog = false },
      messageToBenchmark = benchmarkMessage.value,
      onBenchmarkClicked = { message, warmUpIterations, benchmarkIterations ->
        onBenchmarkClicked(selectedModel, message, warmUpIterations, benchmarkIterations)
      },
    )
  }
}


private suspend fun scrollToBottom(listState: LazyListState, animate: Boolean = false) {
  val itemCount = listState.layoutInfo.totalItemsCount
  if (itemCount > 0) {
    if (animate) {
      listState.animateScrollToItem(itemCount - 1, scrollOffset = 1000000)
    } else {
      listState.scrollToItem(itemCount - 1, scrollOffset = 1000000)
    }
  }
}
