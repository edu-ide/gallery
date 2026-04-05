package com.google.ai.edge.gallery.ui.home

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.google.ai.edge.gallery.GalleryTopAppBar
import com.google.ai.edge.gallery.R

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun UgotHomeScreen(
  onStartChat: () -> Unit,
  onOpenDeveloperGallery: (() -> Unit)?,
  modifier: Modifier = Modifier,
) {
  Scaffold(
    modifier = modifier,
    containerColor = MaterialTheme.colorScheme.background,
    topBar = {
      GalleryTopAppBar(title = stringResource(R.string.app_name))
    },
  ) { innerPadding ->
    Box(
      modifier =
        Modifier
          .fillMaxSize()
          .padding(innerPadding)
          .background(
            Brush.verticalGradient(
              colors =
                listOf(
                  Color(0xFFF6F7FB),
                  Color(0xFFE6EEF9),
                  Color(0xFFD7E4FF),
                )
            )
          )
          .padding(horizontal = 24.dp, vertical = 20.dp)
    ) {
      Column(
        modifier = Modifier.fillMaxWidth().align(Alignment.Center),
        verticalArrangement = Arrangement.spacedBy(20.dp),
      ) {
        Text(
          text = stringResource(R.string.ugot_home_title),
          style = MaterialTheme.typography.displaySmall,
          color = MaterialTheme.colorScheme.onBackground,
        )
        Text(
          text = stringResource(R.string.ugot_home_subtitle),
          style = MaterialTheme.typography.bodyLarge,
          color = MaterialTheme.colorScheme.onSurfaceVariant,
        )

        Surface(
          shape = RoundedCornerShape(28.dp),
          tonalElevation = 2.dp,
          shadowElevation = 8.dp,
          color = Color.White.copy(alpha = 0.88f),
          modifier = Modifier.fillMaxWidth(),
        ) {
          Column(
            modifier = Modifier.padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
          ) {
            Text(
              text = stringResource(R.string.ugot_home_primary_label),
              style = MaterialTheme.typography.labelLarge,
              color = MaterialTheme.colorScheme.primary,
            )
            Text(
              text = stringResource(R.string.ugot_home_primary_description),
              style = MaterialTheme.typography.headlineSmall,
              color = MaterialTheme.colorScheme.onSurface,
            )
            Text(
              text = stringResource(R.string.ugot_home_primary_hint),
              style = MaterialTheme.typography.bodyMedium,
              color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Button(
              onClick = onStartChat,
              shape = RoundedCornerShape(18.dp),
              modifier = Modifier.fillMaxWidth().height(54.dp),
            ) {
              Text(stringResource(R.string.ugot_home_start_chat))
            }
          }
        }

        if (onOpenDeveloperGallery != null) {
          Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
          ) {
            OutlinedButton(
              onClick = onOpenDeveloperGallery,
              shape = RoundedCornerShape(16.dp),
            ) {
              Text(stringResource(R.string.ugot_home_developer_tools))
            }
            Spacer(modifier = Modifier.width(4.dp))
            Text(
              text = stringResource(R.string.ugot_home_developer_caption),
              style = MaterialTheme.typography.bodySmall,
              color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
          }
        }
      }
    }
  }
}
