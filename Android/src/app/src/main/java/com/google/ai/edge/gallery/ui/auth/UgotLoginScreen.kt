package com.google.ai.edge.gallery.ui.auth

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.google.ai.edge.gallery.R
import com.google.ai.edge.gallery.ui.modelmanager.ModelManagerViewModel
import com.google.ai.edge.gallery.ui.modelmanager.TokenRequestResultType

@Composable
fun UgotLoginScreen(
  modelManagerViewModel: ModelManagerViewModel,
  onLoginSuccess: () -> Unit,
  modifier: Modifier = Modifier,
) {
  var loggingIn by remember { mutableStateOf(false) }
  var errorMessage by remember { mutableStateOf<String?>(null) }
  val startNativeSignIn =
    rememberUgotNativeGoogleSignInLauncher(
      modelManagerViewModel = modelManagerViewModel,
      onStarted = {
        loggingIn = true
        errorMessage = null
      },
    ) { tokenResult ->
      loggingIn = false
      when (tokenResult.status) {
        TokenRequestResultType.SUCCEEDED -> {
          errorMessage = null
          onLoginSuccess()
        }
        TokenRequestResultType.FAILED -> {
          errorMessage = tokenResult.errorMessage ?: "Google sign-in failed"
        }
        TokenRequestResultType.USER_CANCELLED -> Unit
      }
    }

  Box(
    modifier =
      modifier
        .fillMaxSize()
        .background(
          Brush.verticalGradient(
            colors = listOf(Color(0xFFF6F7FB), Color(0xFFE6EEF9), Color(0xFFD7E4FF))
          )
        )
        .padding(24.dp)
  ) {
    Surface(
      modifier = Modifier.fillMaxWidth().align(Alignment.Center),
      shape = RoundedCornerShape(28.dp),
      tonalElevation = 2.dp,
      shadowElevation = 8.dp,
      color = Color.White.copy(alpha = 0.9f),
    ) {
      Column(
        modifier = Modifier.padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(16.dp),
      ) {
        Text(
          text = stringResource(R.string.ugot_login_title),
          style = MaterialTheme.typography.headlineMedium,
          color = MaterialTheme.colorScheme.onSurface,
          textAlign = TextAlign.Center,
        )
        Text(
          text = stringResource(R.string.ugot_login_subtitle),
          style = MaterialTheme.typography.bodyLarge,
          color = MaterialTheme.colorScheme.onSurfaceVariant,
          textAlign = TextAlign.Center,
        )
        if (errorMessage != null) {
          Text(
            text = errorMessage!!,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.error,
            textAlign = TextAlign.Center,
          )
        }
        Button(
          onClick = startNativeSignIn,
          enabled = !loggingIn,
          modifier = Modifier.fillMaxWidth(),
          shape = RoundedCornerShape(18.dp),
        ) {
          if (loggingIn) {
            CircularProgressIndicator(
              strokeWidth = 2.dp,
              modifier = Modifier.padding(vertical = 2.dp),
            )
          } else {
            Text(stringResource(R.string.ugot_login_button))
          }
        }
      }
    }
  }
}
