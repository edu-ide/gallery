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
import javax.inject.Inject
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

internal class SajugTask(
  private val dataStoreRepository: DataStoreRepository,
) : CustomTask {
  override val task =
    Task(
      id = SajugMcpSession.TASK_ID,
      label = "Demo MCP UI",
      description =
        "Hosts a local demo MCP widget inside Gallery using the official Kotlin MCP client and a WebView bridge compatible with window.openai.callTool.",
      shortDescription = "Run demo MCP UI",
      docUrl = "https://modelcontextprotocol.io/docs/sdk",
      sourceCodeUrl = "https://github.com/modelcontextprotocol/kotlin-sdk",
      category = Category.EXPERIMENTAL,
      icon = Icons.Outlined.AutoAwesome,
      experimental = true,
      models =
        mutableListOf(
          Model(
            name = "Demo MCP Runtime",
            displayName = "Demo MCP Runtime",
            info =
              "A lightweight host model that boots a local demo MCP session and renders a widget. No local model file is required.",
            localFileRelativeDirPathOverride = "demo_mcp/",
            showBenchmarkButton = false,
            showRunAgainButton = false,
            bestForTaskIds = listOf(SajugMcpSession.TASK_ID),
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
          SajugMcpSession.create(
            authToken = UgotAuthStorage.getValidAccessTokenOrNull(dataStoreRepository)
          )
        model.instance = session
        onDone("")
      } catch (error: Exception) {
        model.instance = null
        onDone(error.message ?: "Failed to start demo MCP session")
      }
    }
  }

  override fun cleanUpModelFn(
    context: Context,
    coroutineScope: CoroutineScope,
    model: Model,
    onDone: () -> Unit,
  ) {
    val session = model.instance as? SajugMcpSession
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
      bottomPadding = customTaskData.bottomPadding,
    )
  }
}
