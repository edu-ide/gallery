package com.google.ai.edge.gallery.ui.auth

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.credentials.CredentialManager
import androidx.credentials.CustomCredential
import androidx.credentials.GetCredentialRequest
import androidx.credentials.exceptions.GetCredentialException
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
import androidx.compose.material3.OutlinedButton
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.google.ai.edge.gallery.R
import com.google.ai.edge.gallery.common.UgotAuthConfig
import com.google.ai.edge.gallery.ui.modelmanager.ModelManagerViewModel
import com.google.ai.edge.gallery.ui.modelmanager.TokenRequestResultType
import com.google.android.libraries.identity.googleid.GetSignInWithGoogleOption
import com.google.android.libraries.identity.googleid.GoogleIdTokenCredential
import com.google.android.libraries.identity.googleid.GoogleIdTokenParsingException
import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

@Composable
fun UgotLoginScreen(
  modelManagerViewModel: ModelManagerViewModel,
  onLoginSuccess: () -> Unit,
  modifier: Modifier = Modifier,
) {
  var loggingIn by remember { mutableStateOf(false) }
  var errorMessage by remember { mutableStateOf<String?>(null) }
  val context = LocalContext.current
  val scope = remember { CoroutineScope(Dispatchers.Main) }
  val credentialManager = remember(context) { CredentialManager.create(context) }

  val authResultLauncher =
    rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
      modelManagerViewModel.handleUgotAuthResult(result) { tokenResult ->
        loggingIn = false
        when (tokenResult.status) {
          TokenRequestResultType.SUCCEEDED -> {
            errorMessage = null
            onLoginSuccess()
          }
          TokenRequestResultType.FAILED -> {
            errorMessage = tokenResult.errorMessage ?: "Sign-in failed"
          }
          TokenRequestResultType.USER_CANCELLED -> Unit
        }
      }
    }

  fun launchBrowserFallback() {
    loggingIn = true
    errorMessage = null
    val request = modelManagerViewModel.getUgotAuthorizationRequest()
    val intent = modelManagerViewModel.authService.getAuthorizationRequestIntent(request)
    authResultLauncher.launch(intent)
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
          onClick = {
            loggingIn = true
            errorMessage = null
            scope.launch {
              try {
                val googleOption =
                  GetSignInWithGoogleOption.Builder(UgotAuthConfig.googleServerClientId)
                    .setNonce(UUID.randomUUID().toString())
                    .build()
                val request =
                  GetCredentialRequest.Builder()
                    .addCredentialOption(googleOption)
                    .build()
                val result = credentialManager.getCredential(context, request)
                val credential = result.credential
                if (
                  credential is CustomCredential &&
                    credential.type == GoogleIdTokenCredential.TYPE_GOOGLE_ID_TOKEN_CREDENTIAL
                ) {
                  val googleCredential = GoogleIdTokenCredential.createFrom(credential.data)
                  modelManagerViewModel.exchangeGoogleIdTokenForUgotTokens(googleCredential.idToken) { tokenResult ->
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
                } else {
                  loggingIn = false
                  errorMessage = "Google sign-in was not available on this device"
                }
              } catch (e: GoogleIdTokenParsingException) {
                loggingIn = false
                errorMessage = e.message ?: "Failed to parse Google token"
              } catch (e: GetCredentialException) {
                loggingIn = false
                errorMessage = e.message ?: "Native sign-in failed"
              } catch (e: Exception) {
                loggingIn = false
                errorMessage = e.message ?: "Native sign-in failed"
              }
            }
          },
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
        OutlinedButton(
          onClick = { launchBrowserFallback() },
          enabled = !loggingIn,
          modifier = Modifier.fillMaxWidth(),
          shape = RoundedCornerShape(18.dp),
        ) {
          Text(stringResource(R.string.ugot_login_browser_fallback))
        }
      }
    }
  }
}
