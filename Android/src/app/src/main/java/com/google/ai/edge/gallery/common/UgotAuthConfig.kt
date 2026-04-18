package com.google.ai.edge.gallery.common

import java.net.URLEncoder

object UgotAuthConfig {
  const val mobileClientId = "ugot-mobile"
  const val authServerBaseUrl = "https://auth.ugot.uk"
  const val mobileScopes = "profile email offline_access api.read mcp.read mcp.write"
  const val huggingFaceDownloadProxyUrl = "$authServerBaseUrl/api/proxy/hf-download"
  const val googleServerClientId =
    "133048024494-v9q4qimam6cl70set38o8tdbj3mcr0ss.apps.googleusercontent.com"

  fun buildHuggingFaceProxyUrl(sourceUrl: String): String {
    return "$huggingFaceDownloadProxyUrl?sourceUrl=${URLEncoder.encode(sourceUrl, "UTF-8")}"
  }
}
