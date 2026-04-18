package com.google.ai.edge.gallery.customtasks.sajug

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.google.ai.edge.gallery.data.Model
import com.google.ai.edge.gallery.ui.common.GalleryWebView
import com.google.ai.edge.gallery.ui.mcp.McpUiSession
import com.google.ai.edge.gallery.ui.mcp.McpUiWebBridge
import com.google.ai.edge.gallery.ui.modelmanager.ModelInitializationStatusType
import com.google.ai.edge.gallery.ui.modelmanager.ModelManagerViewModel

@Composable
internal fun SajugTaskScreen(
  modelManagerViewModel: ModelManagerViewModel,
  selectedModel: Model?,
  bottomPadding: Dp,
) {
  val modelManagerUiState by modelManagerViewModel.uiState.collectAsState()
  val routeModel = selectedModel ?: modelManagerUiState.selectedModel
  val initializationStatus = modelManagerUiState.modelInitializationStatus[routeModel.name]?.status
  val session = routeModel.instance as? McpUiSession
  val context = LocalContext.current
  val bridge = remember(session, context) { session?.let { McpUiWebBridge(context = context, session = it) } }

  Box(
    modifier =
      Modifier
        .fillMaxSize()
        .padding(bottom = bottomPadding)
  ) {
    when {
      session != null && bridge != null -> {
        GalleryWebView(
          modifier = Modifier.fillMaxSize(),
          initialHtml = session.injectedWidgetHtml,
          htmlBaseUrl = session.widgetBaseUrl,
          preventParentScrolling = true,
          allowRequestPermission = true,
          onWebViewCreated = { webView ->
            webView.addJavascriptInterface(bridge, "McpUiHost")
          },
        )
      }

      initializationStatus == ModelInitializationStatusType.INITIALIZING -> {
        CircularProgressIndicator(modifier = Modifier.align(Alignment.Center))
      }

      else -> {
        Text(
          text = "UGOT Fortune MCP session is not ready.",
          modifier = Modifier.align(Alignment.Center).padding(24.dp),
          color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
      }
    }
  }
}
