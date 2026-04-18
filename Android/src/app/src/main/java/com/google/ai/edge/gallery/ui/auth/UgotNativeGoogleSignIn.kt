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

package com.google.ai.edge.gallery.ui.auth

import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.platform.LocalContext
import androidx.credentials.CredentialManager
import androidx.credentials.CustomCredential
import androidx.credentials.GetCredentialRequest
import androidx.credentials.exceptions.GetCredentialCancellationException
import androidx.credentials.exceptions.GetCredentialException
import androidx.credentials.exceptions.NoCredentialException
import com.google.ai.edge.gallery.common.UgotAuthConfig
import com.google.ai.edge.gallery.ui.modelmanager.ModelManagerViewModel
import com.google.ai.edge.gallery.ui.modelmanager.TokenRequestResult
import com.google.ai.edge.gallery.ui.modelmanager.TokenRequestResultType
import com.google.android.libraries.identity.googleid.GetSignInWithGoogleOption
import com.google.android.libraries.identity.googleid.GoogleIdTokenCredential
import com.google.android.libraries.identity.googleid.GoogleIdTokenParsingException
import java.util.UUID
import kotlinx.coroutines.launch

@Composable
internal fun rememberUgotNativeGoogleSignInLauncher(
  modelManagerViewModel: ModelManagerViewModel,
  onStarted: () -> Unit = {},
  onResult: (TokenRequestResult) -> Unit,
): () -> Unit {
  val context = LocalContext.current
  val scope = rememberCoroutineScope()
  val credentialManager = remember(context) { CredentialManager.create(context) }

  return remember(context, scope, credentialManager, modelManagerViewModel, onStarted, onResult) {
    {
      onStarted()
      scope.launch {
        try {
          val googleOption =
            GetSignInWithGoogleOption.Builder(UgotAuthConfig.googleServerClientId)
              .setNonce(UUID.randomUUID().toString())
              .build()
          val request = GetCredentialRequest.Builder().addCredentialOption(googleOption).build()
          val result = credentialManager.getCredential(context, request)
          val credential = result.credential
          if (
            credential is CustomCredential &&
              credential.type == GoogleIdTokenCredential.TYPE_GOOGLE_ID_TOKEN_CREDENTIAL
          ) {
            val googleCredential = GoogleIdTokenCredential.createFrom(credential.data)
            modelManagerViewModel.exchangeGoogleIdTokenForUgotTokens(
              idToken = googleCredential.idToken,
              onDone = onResult,
            )
          } else {
            onResult(
              TokenRequestResult(
                status = TokenRequestResultType.FAILED,
                errorMessage = "Google sign-in was not available on this device",
              )
            )
          }
        } catch (_: GetCredentialCancellationException) {
          onResult(TokenRequestResult(status = TokenRequestResultType.USER_CANCELLED))
        } catch (_: NoCredentialException) {
          onResult(
            TokenRequestResult(
              status = TokenRequestResultType.FAILED,
              errorMessage = "Google sign-in was not available on this device",
            )
          )
        } catch (e: GoogleIdTokenParsingException) {
          onResult(
            TokenRequestResult(
              status = TokenRequestResultType.FAILED,
              errorMessage = e.message ?: "Failed to parse Google token",
            )
          )
        } catch (e: GetCredentialException) {
          onResult(
            TokenRequestResult(
              status = TokenRequestResultType.FAILED,
              errorMessage = e.message ?: "Native sign-in failed",
            )
          )
        } catch (e: Exception) {
          onResult(
            TokenRequestResult(
              status = TokenRequestResultType.FAILED,
              errorMessage = e.message ?: "Native sign-in failed",
            )
          )
        }
      }
    }
  }
}
