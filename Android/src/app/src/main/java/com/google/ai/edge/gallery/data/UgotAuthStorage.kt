package com.google.ai.edge.gallery.data

private const val UGOT_ACCESS_TOKEN_KEY = "ugot_access_token"
private const val UGOT_REFRESH_TOKEN_KEY = "ugot_refresh_token"
private const val UGOT_EXPIRES_AT_KEY = "ugot_expires_at"

data class UgotTokenData(
  val accessToken: String,
  val refreshToken: String?,
  val expiresAtMs: Long?,
)

enum class UgotTokenStatus {
  NOT_STORED,
  EXPIRED,
  NOT_EXPIRED,
}

data class UgotTokenStatusAndData(
  val status: UgotTokenStatus,
  val data: UgotTokenData? = null,
)

object UgotAuthStorage {
  fun saveTokenData(
    dataStoreRepository: DataStoreRepository,
    accessToken: String,
    refreshToken: String?,
    expiresAtMs: Long?,
  ) {
    dataStoreRepository.saveSecret(UGOT_ACCESS_TOKEN_KEY, accessToken)
    dataStoreRepository.saveSecret(UGOT_REFRESH_TOKEN_KEY, refreshToken.orEmpty())
    dataStoreRepository.saveSecret(UGOT_EXPIRES_AT_KEY, expiresAtMs?.toString().orEmpty())
  }

  fun clearTokenData(dataStoreRepository: DataStoreRepository) {
    dataStoreRepository.deleteSecret(UGOT_ACCESS_TOKEN_KEY)
    dataStoreRepository.deleteSecret(UGOT_REFRESH_TOKEN_KEY)
    dataStoreRepository.deleteSecret(UGOT_EXPIRES_AT_KEY)
  }

  fun getTokenStatusAndData(dataStoreRepository: DataStoreRepository): UgotTokenStatusAndData {
    val accessToken = dataStoreRepository.readSecret(UGOT_ACCESS_TOKEN_KEY).orEmpty()
    if (accessToken.isBlank()) {
      return UgotTokenStatusAndData(UgotTokenStatus.NOT_STORED)
    }

    val refreshToken = dataStoreRepository.readSecret(UGOT_REFRESH_TOKEN_KEY).orEmpty().ifBlank { null }
    val expiresAtMs = dataStoreRepository.readSecret(UGOT_EXPIRES_AT_KEY)?.toLongOrNull()
    val status =
      if (expiresAtMs != null && System.currentTimeMillis() >= expiresAtMs - 5 * 60 * 1000) {
        UgotTokenStatus.EXPIRED
      } else {
        UgotTokenStatus.NOT_EXPIRED
      }

    return UgotTokenStatusAndData(
      status = status,
      data = UgotTokenData(accessToken, refreshToken, expiresAtMs),
    )
  }

  fun getValidAccessTokenOrNull(dataStoreRepository: DataStoreRepository): String? {
    val statusAndData = getTokenStatusAndData(dataStoreRepository)
    return if (statusAndData.status == UgotTokenStatus.NOT_EXPIRED) {
      statusAndData.data?.accessToken
    } else {
      null
    }
  }
}
