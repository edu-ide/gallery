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

package com.google.ai.edge.gallery.ui.common

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.google.ai.edge.gallery.R
import com.google.ai.edge.gallery.data.Model
import com.google.ai.edge.gallery.data.Task
import com.google.ai.edge.gallery.ui.common.modelitem.StatusIcon
import com.google.ai.edge.gallery.ui.modelmanager.ModelInitializationStatusType
import com.google.ai.edge.gallery.ui.modelmanager.ModelManagerViewModel
import com.ugot.chatkit.ui.UgotChatModelTrigger

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ModelPickerChip(
  enabled: Boolean,
  task: Task,
  initialModel: Model,
  modelManagerViewModel: ModelManagerViewModel,
  onModelSelected: (prev: Model, cur: Model) -> Unit,
) {
  var showModelPicker by remember { mutableStateOf(false) }
  var modelPickerModel by remember { mutableStateOf<Model?>(null) }
  val modelManagerUiState by modelManagerViewModel.uiState.collectAsState()
  val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
  val density = LocalDensity.current
  val windowInfo = LocalWindowInfo.current
  val screenWidthDp = remember { with(density) { windowInfo.containerSize.width.toDp() } }

  val modelInitializationStatus = modelManagerUiState.modelInitializationStatus[initialModel.name]

  Box(modifier = Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
    val modelName = initialModel.displayName.ifEmpty { initialModel.name }
    val cdChangeModel = stringResource(R.string.cd_change_model, modelName)
    UgotChatModelTrigger(
      label = modelName,
      enabled = enabled,
      onClick = {
        modelPickerModel = initialModel
        showModelPicker = true
      },
      modifier =
        Modifier.widthIn(max = screenWidthDp - 250.dp).semantics {
          contentDescription = cdChangeModel
        },
      leadingIcon = {
        Box(contentAlignment = Alignment.Center, modifier = Modifier.size(21.dp)) {
          StatusIcon(
            task = task,
            model = initialModel,
            downloadStatus = modelManagerUiState.modelDownloadStatus[initialModel.name],
          )
          AnimatedVisibility(
            visible =
              modelInitializationStatus?.status == ModelInitializationStatusType.INITIALIZING,
            enter = scaleIn() + fadeIn(),
            exit = scaleOut() + fadeOut(),
          ) {
            // Circular progress indicator.
            CircularProgressIndicator(
              modifier = Modifier.size(24.dp).alpha(0.5f),
              strokeWidth = 2.dp,
              color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
          }
        }
      },
    )
  }

  // Model picker.
  val curModelPickerModel = modelPickerModel
  if (showModelPicker && curModelPickerModel != null) {
    ModalBottomSheet(onDismissRequest = { showModelPicker = false }, sheetState = sheetState) {
      ModelPicker(
        task = task,
        modelManagerViewModel = modelManagerViewModel,
        onModelSelected = { selectedModel ->
          showModelPicker = false
          val prevSelectedModel = modelManagerUiState.selectedModel
          onModelSelected(prevSelectedModel, selectedModel)
        },
      )
    }
  }
}
