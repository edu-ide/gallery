/*
 * Copyright 2026 Google LLC
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

package com.google.ai.edge.gallery.ui.unifiedchat

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.AssistChip
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.google.ai.edge.gallery.R

private fun defaultConnectorLabel(connectorId: String): String =
  connectorId
    .split('_', '-')
    .filter { it.isNotBlank() }
    .joinToString(" ") { token ->
      token.lowercase().replaceFirstChar { firstChar -> firstChar.titlecase() }
    }

@Composable
fun ConnectorBar(
  state: ConnectorBarState,
  onConnectorClicked: (String) -> Unit,
  onOpenConnectorSheet: () -> Unit,
  modifier: Modifier = Modifier,
  connectorLabel: (String) -> String = ::defaultConnectorLabel,
) {
  Row(
    modifier = modifier.horizontalScroll(rememberScrollState()),
    horizontalArrangement = Arrangement.spacedBy(8.dp),
  ) {
    state.visibleConnectorIds.forEach { connectorId ->
      FilterChip(
        selected = state.activeConnectorIds.contains(connectorId),
        onClick = { onConnectorClicked(connectorId) },
        label = { Text(connectorLabel(connectorId)) },
      )
    }
    AssistChip(
      onClick = onOpenConnectorSheet,
      label = { Text(stringResource(R.string.connector_bar_open_sheet)) },
    )
  }
}
