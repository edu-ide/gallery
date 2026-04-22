package com.google.ai.edge.gallery.customtasks.sajug

import android.content.Context
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.AutoAwesome
import androidx.compose.runtime.Composable
import com.google.ai.edge.gallery.customtasks.common.CustomTask
import com.google.ai.edge.gallery.customtasks.common.CustomTaskData
import com.google.ai.edge.gallery.data.Category
import com.google.ai.edge.gallery.data.DataStoreRepository
import com.google.ai.edge.gallery.data.Model
import com.google.ai.edge.gallery.data.Task
import com.google.ai.edge.gallery.data.UgotAuthStorage
import com.google.ai.edge.gallery.ui.mcp.McpUiSession
import java.io.File
import javax.inject.Inject
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

internal const val UGOT_FORTUNE_TASK_ID = "ugot_fortune_mcp_ui"
internal const val UGOT_FORTUNE_MCP_ENDPOINT = "https://fortune.ugot.uk/mcp"
private const val UGOT_FORTUNE_WIDGET_BASE_URL = "https://fortune.ugot.uk/"

internal class SajugTask(
  private val dataStoreRepository: DataStoreRepository,
) : CustomTask {
  override val task =
    Task(
      id = UGOT_FORTUNE_TASK_ID,
      label = "UGOT Fortune",
      description =
        "Open the shared local AI chat shell with the hosted UGOT Fortune MCP widget connected.",
      shortDescription = "Shared chat with Fortune connector",
      docUrl = "https://modelcontextprotocol.io/",
      sourceCodeUrl = "https://fortune.ugot.uk/",
      category = Category.EXPERIMENTAL,
      icon = Icons.Outlined.AutoAwesome,
      experimental = true,
      models =
        mutableListOf(
          Model(
            name = "UGOT Fortune MCP Runtime",
            displayName = "UGOT Fortune MCP Runtime",
            info =
              "A lightweight host entry that boots the remote UGOT Fortune MCP session and renders its widget. No on-device model download is required.",
            localFileRelativeDirPathOverride = "ugot_fortune_mcp/",
            showBenchmarkButton = false,
            showRunAgainButton = false,
            bestForTaskIds = listOf(UGOT_FORTUNE_TASK_ID),
          )
        ),
    )

  override fun initializeModelFn(
    context: Context,
    coroutineScope: CoroutineScope,
    model: Model,
    onDone: (String) -> Unit,
  ) {
    coroutineScope.launch(Dispatchers.IO) {
      try {
        val session =
          McpUiSession.create(
            endpoint = UGOT_FORTUNE_MCP_ENDPOINT,
            widgetBaseUrl = UGOT_FORTUNE_WIDGET_BASE_URL,
            authToken = UgotAuthStorage.getValidAccessTokenOrNull(dataStoreRepository),
            clientName = "gallery-ugot-fortune-client",
            agentVfsRootPath = File(context.filesDir, "agent_vfs").absolutePath,
            agentVfsSessionId = UGOT_FORTUNE_TASK_ID,
            connectorId = UGOT_FORTUNE_CONNECTOR_ID,
          )
        model.instance = session
        onDone("")
      } catch (error: Exception) {
        model.instance = null
        onDone(error.message ?: "Failed to start UGOT Fortune MCP session")
      }
    }
  }

  override fun cleanUpModelFn(
    context: Context,
    coroutineScope: CoroutineScope,
    model: Model,
    onDone: () -> Unit,
  ) {
    val session = model.instance as? McpUiSession
    if (session == null) {
      onDone()
      return
    }

    coroutineScope.launch(Dispatchers.IO) {
      try {
        session.close()
      } finally {
        onDone()
      }
    }
  }

  @Composable
  override fun MainScreen(data: Any) {
    val customTaskData = data as CustomTaskData
    SajugTaskScreen(
      modelManagerViewModel = customTaskData.modelManagerViewModel,
      selectedModel = customTaskData.selectedModel,
      onNavigateUp = customTaskData.onNavigateUp,
      setTopBarVisible = customTaskData.setTopBarVisible,
    )
  }
}
