package com.google.ai.edge.gallery.common

import androidx.core.net.toUri
import java.net.URLEncoder
import net.openid.appauth.AuthorizationServiceConfiguration

object UgotAuthConfig {
  const val clientId = "app-client"
  const val mobileClientId = "ugot-mobile"
  const val redirectScheme = "com.ugot.chat"
  const val redirectUri = "com.ugot.chat:/oauth2redirect"
  const val authServerBaseUrl = "https://auth.ugot.uk"
  const val scopes = "openid profile email offline_access api.read mcp.read mcp.write"
  const val mobileScopes = "profile email offline_access api.read mcp.read mcp.write"
  const val huggingFaceDownloadProxyUrl = "$authServerBaseUrl/api/proxy/hf-download"
  const val googleServerClientId =
    "133048024494-v9q4qimam6cl70set38o8tdbj3mcr0ss.apps.googleusercontent.com"

  private const val authEndpoint = "$authServerBaseUrl/oauth2/authorize"
  private const val tokenEndpoint = "$authServerBaseUrl/oauth2/token"

  val authServiceConfig =
    AuthorizationServiceConfiguration(
      authEndpoint.toUri(),
      tokenEndpoint.toUri(),
    )

  fun buildHuggingFaceProxyUrl(sourceUrl: String): String {
    return "$huggingFaceDownloadProxyUrl?sourceUrl=${URLEncoder.encode(sourceUrl, "UTF-8")}"
  }
}
