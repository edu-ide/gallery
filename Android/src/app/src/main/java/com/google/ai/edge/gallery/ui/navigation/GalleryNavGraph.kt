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

package com.google.ai.edge.gallery.ui.navigation

import android.net.Uri
import android.os.Bundle
import android.util.Log
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedContentTransitionScope
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ExitTransition
import androidx.compose.animation.core.EaseOutExpo
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.FiniteAnimationSpec
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.calculateStartPadding
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBars
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.navigation.NavHostController
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.navArgument
import com.google.ai.edge.gallery.BuildConfig
import com.google.ai.edge.gallery.GalleryEvent
import com.google.ai.edge.gallery.R
import com.google.ai.edge.gallery.customtasks.common.CustomTaskData
import com.google.ai.edge.gallery.customtasks.common.CustomTaskDataForBuiltinTask
import com.google.ai.edge.gallery.data.BuiltInTaskId
import com.google.ai.edge.gallery.data.ModelDownloadStatusType
import com.google.ai.edge.gallery.data.Task
import com.google.ai.edge.gallery.data.UgotTokenStatus
import com.google.ai.edge.gallery.data.isLegacyTasks
import com.google.ai.edge.gallery.firebaseAnalytics
import com.google.ai.edge.gallery.ui.auth.UgotLoginScreen
import com.google.ai.edge.gallery.ui.benchmark.BenchmarkScreen
import com.google.ai.edge.gallery.ui.common.ErrorDialog
import com.google.ai.edge.gallery.ui.common.ModelPageAppBar
import com.google.ai.edge.gallery.ui.common.chat.ModelDownloadStatusInfoPanel
import com.google.ai.edge.gallery.ui.home.HomeScreen
import com.google.ai.edge.gallery.ui.home.PromoScreenGm4
import com.google.ai.edge.gallery.ui.home.UgotHomeScreen
import com.google.ai.edge.gallery.ui.llmchat.LlmChatScreen
import com.google.ai.edge.gallery.ui.modelmanager.GlobalModelManager
import com.google.ai.edge.gallery.ui.modelmanager.ModelInitializationStatusType
import com.google.ai.edge.gallery.ui.modelmanager.ModelManager
import com.google.ai.edge.gallery.ui.modelmanager.ModelManagerViewModel
import com.google.ai.edge.gallery.ui.unifiedchat.UnifiedChatEntryHint
import com.google.ai.edge.gallery.ui.unifiedchat.buildUnifiedChatRoute
import com.google.ai.edge.gallery.ui.unifiedchat.decodeUnifiedChatEntryHint
import com.google.ai.edge.gallery.ui.theme.emptyStateContent
import com.google.ai.edge.gallery.ui.theme.emptyStateTitle
import java.net.URI
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

private const val TAG = "AGGalleryNavGraph"
private const val LEGACY_APP_DEEP_LINK_SCHEME = "com.google.ai.edge.gallery"
private const val ROUTE_STARTUP = "startup"
private const val ROUTE_AUTH_LOGIN = "auth_login"
private const val ROUTE_HOMESCREEN = "homepage"
private const val ROUTE_DEVELOPER_HOME = "developer_home"
private const val ROUTE_MODEL_LIST = "model_list"
private const val ROUTE_MODEL = "route_model"
private const val ROUTE_UNIFIED_MODEL = "model"
private const val ROUTE_BENCHMARK = "benchmark"
private const val ROUTE_MODEL_MANAGER = "model_manager"
private const val ENTER_ANIMATION_DURATION_MS = 500
private val ENTER_ANIMATION_EASING = EaseOutExpo
private const val ENTER_ANIMATION_DELAY_MS = 100

private const val EXIT_ANIMATION_DURATION_MS = 500
private val EXIT_ANIMATION_EASING = EaseOutExpo

private fun enterTween(): FiniteAnimationSpec<IntOffset> {
  return tween(
    ENTER_ANIMATION_DURATION_MS,
    easing = ENTER_ANIMATION_EASING,
    delayMillis = ENTER_ANIMATION_DELAY_MS,
  )
}

private fun exitTween(): FiniteAnimationSpec<IntOffset> {
  return tween(EXIT_ANIMATION_DURATION_MS, easing = EXIT_ANIMATION_EASING)
}

private fun AnimatedContentTransitionScope<*>.slideEnter(): EnterTransition {
  return slideIntoContainer(
    animationSpec = enterTween(),
    towards = AnimatedContentTransitionScope.SlideDirection.Left,
  )
}

private fun AnimatedContentTransitionScope<*>.slideExit(): ExitTransition {
  return slideOutOfContainer(
    animationSpec = exitTween(),
    towards = AnimatedContentTransitionScope.SlideDirection.Right,
  )
}

private fun AnimatedContentTransitionScope<*>.slideUpEnter(): EnterTransition {
  return slideIntoContainer(
    animationSpec = enterTween(),
    towards = AnimatedContentTransitionScope.SlideDirection.Up,
  )
}

private fun AnimatedContentTransitionScope<*>.slideDownExit(): ExitTransition {
  return slideOutOfContainer(
    animationSpec = exitTween(),
    towards = AnimatedContentTransitionScope.SlideDirection.Down,
  )
}

internal sealed interface DeepLinkDestination {
  data class Model(val taskId: String, val modelName: String) : DeepLinkDestination

  data object GlobalModelManager : DeepLinkDestination
}

internal fun resolveDeepLinkDestination(deepLink: String?): DeepLinkDestination? {
  if (deepLink == null) {
    return null
  }

  val uri =
    try {
      URI.create(deepLink)
    } catch (_: IllegalArgumentException) {
      Log.e(TAG, "Malformed deep link URI received: $deepLink")
      return null
    }

  val scheme = uri.scheme ?: return null
  if (scheme != BuildConfig.APPLICATION_ID && scheme != LEGACY_APP_DEEP_LINK_SCHEME) {
    return null
  }

  val host = uri.host ?: uri.authority
  return when (host) {
    "model" -> {
      val pathSegments =
        uri.path
          ?.split('/')
          ?.filter { it.isNotEmpty() }
          .orEmpty()
      if (pathSegments.size < 2) {
        Log.e(TAG, "Malformed deep link URI received: $deepLink")
        null
      } else {
        DeepLinkDestination.Model(
          taskId = pathSegments[pathSegments.size - 2],
          modelName = pathSegments.last(),
        )
      }
    }
    "global_model_manager" -> DeepLinkDestination.GlobalModelManager
    else -> null
  }
}

private fun resolveDeepLinkRoute(
  data: Uri?,
  modelManagerViewModel: ModelManagerViewModel,
): String? {
  return when (val destination = resolveDeepLinkDestination(data?.toString())) {
    is DeepLinkDestination.Model ->
      modelManagerViewModel
        .getModelByName(name = destination.modelName)
        ?.let { buildUnifiedChatRoute(destination.taskId, it.name, UnifiedChatEntryHint()) }
    DeepLinkDestination.GlobalModelManager -> ROUTE_MODEL_MANAGER
    null -> null
  }
}

internal fun resolveStartupRoute(
  authStatus: UgotTokenStatus,
  loadingModelAllowlist: Boolean,
  deepLinkRoute: String?,
  chatTaskId: String?,
  initialModelName: String?,
  enableDeveloperGallery: Boolean,
  navigationHandled: Boolean,
): String? {
  if (navigationHandled) {
    return null
  }

  if (authStatus != UgotTokenStatus.NOT_EXPIRED) {
    return ROUTE_AUTH_LOGIN
  }

  if (loadingModelAllowlist) {
    return null
  }

  if (deepLinkRoute != null) {
    return deepLinkRoute
  }

  if (chatTaskId != null && initialModelName != null) {
    return "$ROUTE_MODEL/$chatTaskId/$initialModelName"
  }

  return if (enableDeveloperGallery) ROUTE_DEVELOPER_HOME else ROUTE_HOMESCREEN
}

/** Navigation routes. */
@Composable
fun GalleryNavHost(
  navController: NavHostController,
  modifier: Modifier = Modifier,
  modelManagerViewModel: ModelManagerViewModel,
) {
  val lifecycleOwner = LocalLifecycleOwner.current
  var showModelManager by remember { mutableStateOf(false) }
  var pickedTask by remember { mutableStateOf<Task?>(null) }
  var enableHomeScreenAnimation by remember { mutableStateOf(true) }
  var enableModelListAnimation by remember { mutableStateOf(true) }
  var lastNavigatedModelName = remember { "" }
  val enableDeveloperGallery = BuildConfig.DEBUG
  val intent = androidx.activity.compose.LocalActivity.current?.intent
  val currentBackStackEntry by navController.currentBackStackEntryAsState()
  val currentRoute = currentBackStackEntry?.destination?.route

  // Track whether app is in foreground.
  DisposableEffect(lifecycleOwner) {
    val observer = LifecycleEventObserver { _, event ->
      when (event) {
        Lifecycle.Event.ON_START,
        Lifecycle.Event.ON_RESUME -> {
          modelManagerViewModel.setAppInForeground(foreground = true)
        }
        Lifecycle.Event.ON_STOP,
        Lifecycle.Event.ON_PAUSE -> {
          modelManagerViewModel.setAppInForeground(foreground = false)
        }
        else -> {
          /* Do nothing for other events */
        }
      }
    }

    lifecycleOwner.lifecycle.addObserver(observer)

    onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
  }

  NavHost(
    navController = navController,
    startDestination = ROUTE_STARTUP,
    enterTransition = { EnterTransition.None },
    exitTransition = { ExitTransition.None },
  ) {
    composable(route = ROUTE_STARTUP) {
      val uiState by modelManagerViewModel.uiState.collectAsState()
      val chatTask = modelManagerViewModel.getTaskById(BuiltInTaskId.LLM_CHAT)
      val initialModel = modelManagerViewModel.getPreferredModelForTask(BuiltInTaskId.LLM_CHAT)
      var startupNavigationHandled by rememberSaveable { mutableStateOf(false) }

      LaunchedEffect(
        uiState.loadingModelAllowlist,
        chatTask?.id,
        initialModel?.name,
        intent?.dataString,
        startupNavigationHandled,
      ) {
        val authStatus = modelManagerViewModel.getUgotTokenStatusAndData().status
        val deepLinkRoute =
          resolveDeepLinkRoute(data = intent?.data, modelManagerViewModel = modelManagerViewModel)
        val startupRoute =
          resolveStartupRoute(
            authStatus = authStatus,
            loadingModelAllowlist = uiState.loadingModelAllowlist,
            deepLinkRoute = deepLinkRoute,
            chatTaskId = chatTask?.id,
            initialModelName = initialModel?.name,
            enableDeveloperGallery = enableDeveloperGallery,
            navigationHandled = startupNavigationHandled,
          )
        Log.d(
          TAG,
          "startup: loading=${uiState.loadingModelAllowlist}, auth=$authStatus, chatTask=${chatTask?.id}, model=${initialModel?.name}, handled=$startupNavigationHandled",
        )
        startupRoute?.let { route ->
          startupNavigationHandled = true
          when {
            route == ROUTE_AUTH_LOGIN -> {
              navController.navigate(route) { popUpTo(ROUTE_STARTUP) { inclusive = true } }
            }
            deepLinkRoute != null && route == deepLinkRoute -> {
              Log.d(TAG, "startup: handling initial deep link route=$route")
              intent?.data = null
              navController.navigate(route) { popUpTo(ROUTE_STARTUP) { inclusive = true } }
            }
            chatTask != null &&
              initialModel != null &&
              route == "$ROUTE_MODEL/${chatTask.id}/${initialModel.name}" -> {
              Log.d(TAG, "startup: navigating directly to chat model ${initialModel.name}")
              pickedTask = chatTask
              lastNavigatedModelName = ""
              navController.navigate(route) { popUpTo(ROUTE_STARTUP) { inclusive = true } }
            }
            route == ROUTE_DEVELOPER_HOME -> {
              Log.d(TAG, "startup: no chat model, opening developer home")
              navController.navigate(route) { popUpTo(ROUTE_STARTUP) { inclusive = true } }
            }
            else -> {
              Log.d(TAG, "startup: no chat model, opening fallback home")
              navController.navigate(route) { popUpTo(ROUTE_STARTUP) { inclusive = true } }
            }
          }
        }
      }

      Box(modifier = Modifier.fillMaxSize(), contentAlignment = androidx.compose.ui.Alignment.Center) {
        val authStatus = modelManagerViewModel.getUgotTokenStatusAndData().status
        if (authStatus != UgotTokenStatus.NOT_EXPIRED) {
          Text("Checking sign-in…")
        } else if (uiState.loadingModelAllowlist) {
          CircularProgressIndicator()
        } else {
          Text("Opening UGOT Chat…")
        }
      }
    }

    composable(route = ROUTE_AUTH_LOGIN) {
      UgotLoginScreen(
        modelManagerViewModel = modelManagerViewModel,
        onLoginSuccess = {
          navController.navigate(ROUTE_STARTUP) {
            popUpTo(ROUTE_AUTH_LOGIN) { inclusive = true }
          }
        },
      )
    }

    // Home screen.
    composable(route = ROUTE_HOMESCREEN) {
      UgotHomeScreen(
        onStartChat = {
          val task =
            modelManagerViewModel.getTaskById(BuiltInTaskId.LLM_CHAT)
              ?: modelManagerViewModel.uiState.value.tasks.firstOrNull()
          task?.let {
            pickedTask = it
            enableModelListAnimation = true
            navController.navigate(ROUTE_MODEL_LIST)
            firebaseAnalytics?.logEvent(
              GalleryEvent.CAPABILITY_SELECT.id,
              Bundle().apply { putString("capability_name", it.id) },
            )
          }
        },
        onOpenDeveloperGallery =
          if (enableDeveloperGallery) {
            { navController.navigate(ROUTE_DEVELOPER_HOME) }
          } else {
            null
          },
      )
    }

    composable(
      route = ROUTE_DEVELOPER_HOME,
      enterTransition = { slideEnter() },
      exitTransition = { slideExit() },
    ) {
      // Create a state to trigger PromoScreen fade in animation.
      val promoId = "gm4"
      Box(modifier = modifier.fillMaxSize()) {
        var promoDismissed by remember { mutableStateOf(false) }

        val homeScreenContent: @Composable () -> Unit = {
          HomeScreen(
            modelManagerViewModel = modelManagerViewModel,
            tosViewModel = hiltViewModel(),
            enableAnimation = enableHomeScreenAnimation,
            navigateToTaskScreen = { task ->
              pickedTask = task
              enableModelListAnimation = true
              navController.navigate(ROUTE_MODEL_LIST)
              firebaseAnalytics?.logEvent(
                GalleryEvent.CAPABILITY_SELECT.id,
                Bundle().apply { putString("capability_name", task.id) },
              )
            },
            onModelsClicked = { navController.navigate(ROUTE_MODEL_MANAGER) },
            gm4 = true,
          )
        }

        // Show home page directly if promo has been viewed.
        if (modelManagerViewModel.dataStoreRepository.hasViewedPromo(promoId = promoId)) {
          homeScreenContent()
        }
        // If the promo has not been viewed, show promo screen first.
        else {
          AnimatedContent(
            targetState = promoDismissed,
            label = "PromoToHome",
            transitionSpec = { fadeIn() togetherWith fadeOut() },
          ) { dismissed ->
            if (dismissed) {
              homeScreenContent()
            } else {
              var startAnimation by remember { mutableStateOf(false) }
              LaunchedEffect(Unit) {
                delay(0L)
                startAnimation = true
              }
              AnimatedVisibility(
                visible = startAnimation,
                enter = scaleIn(initialScale = 1.05f, animationSpec = tween(durationMillis = 1000)),
              ) {
                PromoScreenGm4(
                  onDismiss = {
                    modelManagerViewModel.dataStoreRepository.addViewedPromoId(promoId = promoId)
                    promoDismissed = true
                  }
                )
              }
            }
          }
        }
      }
    }

    // Model list.
    composable(
      route = ROUTE_MODEL_LIST,
      enterTransition = {
        if (initialState.destination.route == ROUTE_HOMESCREEN) {
          slideEnter()
        } else {
          EnterTransition.None
        }
      },
      exitTransition = {
        if (targetState.destination.route == ROUTE_HOMESCREEN) {
          slideExit()
        } else {
          ExitTransition.None
        }
      },
    ) {
      pickedTask?.let {
        ModelManager(
          viewModel = modelManagerViewModel,
          task = it,
          enableAnimation = enableModelListAnimation,
          onModelClicked = { model ->
            navController.navigate("$ROUTE_MODEL/${it.id}/${model.name}")
          },
          onBenchmarkClicked = { model ->
            firebaseAnalytics?.logEvent(
              GalleryEvent.CAPABILITY_SELECT.id,
              Bundle().apply { putString("capability_name", "benchmark_${model.name}") },
            )
            navController.navigate("$ROUTE_BENCHMARK/${model.name}")
          },
          navigateUp = {
            enableHomeScreenAnimation = false
            navController.navigateUp()
          },
        )
      }
    }

    // Model page.
    composable(
      route = "$ROUTE_MODEL/{taskId}/{modelName}?entry_hint={entry_hint}",
      arguments =
        listOf(
          navArgument("taskId") { type = NavType.StringType },
          navArgument("modelName") { type = NavType.StringType },
          navArgument("entry_hint") {
            type = NavType.StringType
            nullable = true
            defaultValue = ""
          },
        ),
      enterTransition = { slideEnter() },
      exitTransition = { slideExit() },
    ) { backStackEntry ->
      val modelName = backStackEntry.arguments?.getString("modelName") ?: ""
      val taskId = backStackEntry.arguments?.getString("taskId") ?: ""
      val entryHint = decodeUnifiedChatEntryHint(backStackEntry.arguments?.getString("entry_hint"))
      ModelPageScreen(
        navController = navController,
        modelManagerViewModel = modelManagerViewModel,
        taskId = taskId,
        modelName = modelName,
        entryHint = entryHint,
        lastNavigatedModelName = lastNavigatedModelName,
        onLastNavigatedModelNameChange = { lastNavigatedModelName = it },
        onEnableModelListAnimationChange = { enableModelListAnimation = it },
      )
    }

    composable(
      route = "$ROUTE_UNIFIED_MODEL/{taskId}/{modelName}?entry_hint={entry_hint}",
      arguments =
        listOf(
          navArgument("taskId") { type = NavType.StringType },
          navArgument("modelName") { type = NavType.StringType },
          navArgument("entry_hint") {
            type = NavType.StringType
            nullable = true
            defaultValue = ""
          },
        ),
      enterTransition = { slideEnter() },
      exitTransition = { slideExit() },
    ) { backStackEntry ->
      val modelName = backStackEntry.arguments?.getString("modelName") ?: ""
      val taskId = backStackEntry.arguments?.getString("taskId") ?: ""
      val entryHint = decodeUnifiedChatEntryHint(backStackEntry.arguments?.getString("entry_hint"))
      ModelPageScreen(
        navController = navController,
        modelManagerViewModel = modelManagerViewModel,
        taskId = taskId,
        modelName = modelName,
        entryHint = entryHint,
        lastNavigatedModelName = lastNavigatedModelName,
        onLastNavigatedModelNameChange = { lastNavigatedModelName = it },
        onEnableModelListAnimationChange = { enableModelListAnimation = it },
      )
    }

    // Global model manager page.
    composable(
      route = ROUTE_MODEL_MANAGER,
      enterTransition = {
        if (
          initialState.destination.route?.startsWith(ROUTE_BENCHMARK) == true ||
            initialState.destination.route?.startsWith(ROUTE_MODEL) == true
        ) {
          null
        } else {
          slideUpEnter()
        }
      },
      exitTransition = {
        if (
          targetState.destination.route?.startsWith(ROUTE_BENCHMARK) == true ||
            targetState.destination.route?.startsWith(ROUTE_MODEL) == true
        ) {
          null
        } else {
          slideDownExit()
        }
      },
    ) { backStackEntry ->
      GlobalModelManager(
        viewModel = modelManagerViewModel,
        navigateUp = {
          enableHomeScreenAnimation = false
          navController.navigateUp()
        },
        onModelSelected = { task, model ->
          navController.navigate("$ROUTE_MODEL/${task.id}/${model.name}")
        },
        onBenchmarkClicked = { model ->
          firebaseAnalytics?.logEvent(
            GalleryEvent.CAPABILITY_SELECT.id,
            Bundle().apply { putString("capability_name", "benchmark_${model.name}") },
          )
          navController.navigate("$ROUTE_BENCHMARK/${model.name}")
        },
      )
    }

    // Benchmark creation page.
    composable(
      route = "$ROUTE_BENCHMARK/{modelName}",
      arguments = listOf(navArgument("modelName") { type = NavType.StringType }),
      enterTransition = { slideEnter() },
      exitTransition = { slideExit() },
    ) { backStackEntry ->
      val modelName = backStackEntry.arguments?.getString("modelName") ?: ""

      modelManagerViewModel.getModelByName(name = modelName)?.let { model ->
        BenchmarkScreen(
          initialModel = model,
          modelManagerViewModel = modelManagerViewModel,
          onBackClicked = {
            enableModelListAnimation = false
            navController.navigateUp()
          },
        )
      }
    }
  }

  // Handle incoming intents for deep links
  val data = intent?.data
  if (data != null && currentRoute != null && currentRoute != ROUTE_STARTUP) {
    resolveDeepLinkRoute(data = data, modelManagerViewModel = modelManagerViewModel)?.let { route ->
      intent.data = null
      Log.d(TAG, "navigation link clicked: $data")
      navController.navigate(route)
    }
  }
}

@Composable
private fun ModelPageScreen(
  navController: NavHostController,
  modelManagerViewModel: ModelManagerViewModel,
  taskId: String,
  modelName: String,
  entryHint: UnifiedChatEntryHint,
  lastNavigatedModelName: String,
  onLastNavigatedModelNameChange: (String) -> Unit,
  onEnableModelListAnimationChange: (Boolean) -> Unit,
) {
  val scope = rememberCoroutineScope()
  val context = LocalContext.current

  modelManagerViewModel.getModelByName(name = modelName)?.let { initialModel ->
    if (lastNavigatedModelName != modelName) {
      modelManagerViewModel.selectModel(initialModel)
      onLastNavigatedModelNameChange(modelName)
    }

    if (taskId == BuiltInTaskId.LLM_CHAT) {
      LlmChatScreen(
        modelManagerViewModel = modelManagerViewModel,
        navigateUp = {
          onEnableModelListAnimationChange(false)
          onLastNavigatedModelNameChange("")
          navController.navigateUp()
        },
        taskId = taskId,
        entryHint = entryHint,
        emptyStateComposable = {
          Box(modifier = Modifier.fillMaxSize()) {
            Column(
              modifier =
                Modifier.align(Alignment.Center).padding(horizontal = 48.dp).padding(bottom = 48.dp),
              horizontalAlignment = Alignment.CenterHorizontally,
              verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
              Text(stringResource(R.string.aichat_emptystate_title), style = emptyStateTitle)
              Text(
                stringResource(R.string.aichat_emptystate_content),
                style = emptyStateContent,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
              )
            }
          }
        },
      )
    } else {
      val customTask = modelManagerViewModel.getCustomTaskByTaskId(id = taskId)
      if (customTask != null) {
        if (isLegacyTasks(customTask.task.id)) {
          customTask.MainScreen(
            data =
              CustomTaskDataForBuiltinTask(
                modelManagerViewModel = modelManagerViewModel,
                onNavUp = {
                  onEnableModelListAnimationChange(false)
                  onLastNavigatedModelNameChange("")
                  navController.navigateUp()
                },
              )
          )
        } else {
          var disableAppBarControls by remember { mutableStateOf(false) }
          var hideTopBar by remember { mutableStateOf(false) }
          var customNavigateUpCallback by remember { mutableStateOf<(() -> Unit)?>(null) }
          CustomTaskScreen(
            task = customTask.task,
            modelManagerViewModel = modelManagerViewModel,
            onNavigateUp = {
              if (customNavigateUpCallback != null) {
                customNavigateUpCallback?.invoke()
              } else {
                onEnableModelListAnimationChange(false)
                onLastNavigatedModelNameChange("")
                navController.navigateUp()

                // clean up all models.
                for (curModel in customTask.task.models) {
                  val instanceToCleanUp = curModel.instance
                  scope.launch(Dispatchers.Default) {
                    modelManagerViewModel.cleanupModel(
                      context = context,
                      task = customTask.task,
                      model = curModel,
                      instanceToCleanUp = instanceToCleanUp,
                    )
                  }
                }
              }
            },
            disableAppBarControls = disableAppBarControls,
            hideTopBar = hideTopBar,
            useThemeColor = customTask.task.useThemeColor,
          ) { bottomPadding ->
            customTask.MainScreen(
              data =
                CustomTaskData(
                  modelManagerViewModel = modelManagerViewModel,
                  selectedModel = initialModel,
                  bottomPadding = bottomPadding,
                  setAppBarControlsDisabled = { disableAppBarControls = it },
                  setTopBarVisible = { hideTopBar = !it },
                  setCustomNavigateUpCallback = { customNavigateUpCallback = it },
                )
            )
          }
        }
      }
    }
  }
}

@Composable
private fun CustomTaskScreen(
  task: Task,
  modelManagerViewModel: ModelManagerViewModel,
  disableAppBarControls: Boolean,
  hideTopBar: Boolean,
  useThemeColor: Boolean,
  onNavigateUp: () -> Unit,
  content: @Composable (bottomPadding: Dp) -> Unit,
) {
  val modelManagerUiState by modelManagerViewModel.uiState.collectAsState()
  val selectedModel = modelManagerUiState.selectedModel
  val activeModel = task.models.find { it.name == selectedModel.name } ?: task.models.firstOrNull()
  val scope = rememberCoroutineScope()
  val context = LocalContext.current
  var navigatingUp by remember { mutableStateOf(false) }
  var showErrorDialog by remember { mutableStateOf(false) }
  var appBarHeight by remember { mutableIntStateOf(0) }

  if (activeModel == null) {
    return
  }

  val handleNavigateUp = {
    navigatingUp = true
    onNavigateUp()
  }

  // Handle system's edge swipe.
  BackHandler { handleNavigateUp() }

  // Initialize model when model/download state changes.
  val curDownloadStatus = modelManagerUiState.modelDownloadStatus[activeModel.name]
  LaunchedEffect(curDownloadStatus, activeModel.name) {
    if (!navigatingUp) {
      if (curDownloadStatus?.status == ModelDownloadStatusType.SUCCEEDED) {
        Log.d(
          TAG,
          "Initializing model '${activeModel.name}' from CustomTaskScreen launched effect",
        )
        modelManagerViewModel.initializeModel(context, task = task, model = activeModel)
      }
    }
  }

  val modelInitializationStatus = modelManagerUiState.modelInitializationStatus[activeModel.name]
  LaunchedEffect(modelInitializationStatus) {
    showErrorDialog = modelInitializationStatus?.status == ModelInitializationStatusType.ERROR
  }

  Scaffold(
    topBar = {
      AnimatedVisibility(
        !hideTopBar,
        enter = slideInVertically { -it },
        exit = slideOutVertically { -it },
      ) {
        ModelPageAppBar(
          task = task,
          model = activeModel,
          modelManagerViewModel = modelManagerViewModel,
          inProgress = disableAppBarControls,
          modelPreparing = disableAppBarControls,
          canShowResetSessionButton = false,
          useThemeColor = useThemeColor,
          modifier =
            Modifier.onGloballyPositioned { coordinates -> appBarHeight = coordinates.size.height },
          hideModelSelector = task.models.size <= 1,
          onConfigChanged = { _, _ -> },
          onBackClicked = { handleNavigateUp() },
          onModelSelected = { prevModel, newSelectedModel ->
            val instanceToCleanUp = prevModel.instance
            scope.launch(Dispatchers.Default) {
              // Clean up prev model.
              if (prevModel.name != newSelectedModel.name) {
                modelManagerViewModel.cleanupModel(
                  context = context,
                  task = task,
                  model = prevModel,
                  instanceToCleanUp = instanceToCleanUp,
                )
              }

              // Update selected model.
              Log.d(TAG, "from model picker. new: ${newSelectedModel.name}")
              modelManagerViewModel.selectModel(model = newSelectedModel)
            }
          },
        )
      }
    }
  ) { innerPadding ->
    // Calculate the target height in Dp for the content's top padding.
    val targetPaddingDp =
      if (!hideTopBar && appBarHeight > 0) {
        // Convert measured pixel height to Dp
        with(LocalDensity.current) { appBarHeight.toDp() }
      } else {
        WindowInsets.statusBars.asPaddingValues().calculateTopPadding()
      }

    // Animate the actual top padding value.
    val animatedTopPadding by
      animateDpAsState(
        targetValue = targetPaddingDp,
        animationSpec = tween(durationMillis = 220, easing = FastOutSlowInEasing),
        label = "TopPaddingAnimation",
      )

    Box(
      modifier =
        Modifier.padding(
          top = if (!hideTopBar) innerPadding.calculateTopPadding() else animatedTopPadding,
          start = innerPadding.calculateStartPadding(LocalLayoutDirection.current),
          end = innerPadding.calculateStartPadding(LocalLayoutDirection.current),
        )
    ) {
      val curModelDownloadStatus = modelManagerUiState.modelDownloadStatus[activeModel.name]
      AnimatedContent(
        targetState = curModelDownloadStatus?.status == ModelDownloadStatusType.SUCCEEDED
      ) { targetState ->
        when (targetState) {
          // Main UI when model is downloaded.
          true -> content(innerPadding.calculateBottomPadding())
          // Model download
          false ->
            ModelDownloadStatusInfoPanel(
              model = activeModel,
              task = task,
              modelManagerViewModel = modelManagerViewModel,
            )
        }
      }
    }
  }

  if (showErrorDialog) {
    ErrorDialog(
      error = modelInitializationStatus?.error ?: "",
      onDismiss = {
        showErrorDialog = false
        onNavigateUp()
      },
    )
  }
}
