import Foundation
import GoogleSignIn
import Security
import UIKit

struct UgotAuthConfig {
  static let mobileClientId = "ugot-mobile"
  static let authServerBaseURL = URL(string: "https://auth.ugot.uk")!
  static let mobileScopes = "profile email offline_access api.read mcp.read mcp.write"
  static let googleServerClientId = "133048024494-v9q4qimam6cl70set38o8tdbj3mcr0ss.apps.googleusercontent.com"

  static var googleIOSClientId: String {
    (Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
      .nilIfBlank ?? googleServerClientId
  }
}

struct UgotTokenData: Codable {
  let accessToken: String
  let refreshToken: String?
  let expiresAtMs: Int64?

  var isExpired: Bool {
    guard let expiresAtMs else { return false }
    return Int64(Date().timeIntervalSince1970 * 1000) >= expiresAtMs - 60_000
  }
}

enum UgotAuthError: LocalizedError {
  case missingPresenter
  case missingGoogleIdToken
  case tokenExchangeFailed(String)

  var errorDescription: String? {
    switch self {
    case .missingPresenter:
      return "Could not open Google Sign-In. Please try again."
    case .missingGoogleIdToken:
      return "Google Sign-In returned no ID token."
    case .tokenExchangeFailed(let message):
      return message
    }
  }
}

@MainActor
final class UgotAuthViewModel: ObservableObject {
  @Published private(set) var isAuthenticated = false
  @Published private(set) var isLoading = false
  @Published var errorMessage: String?

  init() {
    reload()
  }

  func reload() {
    isAuthenticated = UgotAuthStore.hasRestorableSession()
  }

  func restoreSession() async {
    guard UgotAuthStore.hasRestorableSession() else {
      isAuthenticated = false
      return
    }

    do {
      isLoading = true
      defer { isLoading = false }
      isAuthenticated = try await UgotAuthStore.validAccessToken() != nil
    } catch {
      UgotAuthStore.clear()
      errorMessage = error.localizedDescription
      isAuthenticated = false
      isLoading = false
    }
  }

  func signIn() async {
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }

    do {
      guard let presenter = UIApplication.shared.topMostViewController() else {
        throw UgotAuthError.missingPresenter
      }
      GIDSignIn.sharedInstance.configuration = GIDConfiguration(
        clientID: UgotAuthConfig.googleIOSClientId,
        serverClientID: UgotAuthConfig.googleServerClientId
      )
      let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
      guard let idToken = result.user.idToken?.tokenString, !idToken.isEmpty else {
        throw UgotAuthError.missingGoogleIdToken
      }
      let tokenData = try await UgotAuthService.exchangeGoogleIdTokenForUgotTokens(idToken: idToken)
      try UgotAuthStore.save(tokenData)
      isAuthenticated = true
    } catch {
      errorMessage = error.localizedDescription
      isAuthenticated = false
    }
  }

  func signOut() {
    GIDSignIn.sharedInstance.signOut()
    UgotAuthStore.clear()
    isAuthenticated = false
  }
}

enum UgotAuthService {
  static func exchangeGoogleIdTokenForUgotTokens(idToken: String) async throws -> UgotTokenData {
    try await requestToken(
      bodyItems: [
        ("grant_type", "urn:ietf:params:oauth:grant-type:token-exchange"),
        ("subject_token_type", "urn:ietf:params:oauth:token-type:id_token"),
        ("subject_token", idToken),
        ("client_id", UgotAuthConfig.mobileClientId),
        ("scope", UgotAuthConfig.mobileScopes),
      ],
      fallbackRefreshToken: nil,
      failureLabel: "Token exchange"
    )
  }

  static func refreshTokens(refreshToken: String) async throws -> UgotTokenData {
    try await requestToken(
      bodyItems: [
        ("grant_type", "refresh_token"),
        ("refresh_token", refreshToken),
        ("client_id", UgotAuthConfig.mobileClientId),
        ("scope", UgotAuthConfig.mobileScopes),
      ],
      fallbackRefreshToken: refreshToken,
      failureLabel: "Token refresh"
    )
  }

  private static func requestToken(
    bodyItems: [(String, String)],
    fallbackRefreshToken: String?,
    failureLabel: String
  ) async throws -> UgotTokenData {
    let url = UgotAuthConfig.authServerBaseURL.appendingPathComponent("oauth2/token")
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = bodyItems
      .map { "\($0.0.formEncoded)=\($0.1.formEncoded)" }
      .joined(separator: "&")
      .data(using: .utf8)

    let (data, response) = try await URLSession.shared.data(for: request)
    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
    guard (200..<300).contains(statusCode) else {
      let raw = String(data: data, encoding: .utf8) ?? ""
      throw UgotAuthError.tokenExchangeFailed("\(failureLabel) failed (\(statusCode)): \(raw)")
    }

    let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    guard let accessToken = payload?["access_token"] as? String, !accessToken.isEmpty else {
      throw UgotAuthError.tokenExchangeFailed("\(failureLabel) returned no access token")
    }
    let refreshToken = (payload?["refresh_token"] as? String)?.nilIfBlank ?? fallbackRefreshToken
    let expiresAtMs = (payload?["expires_in"] as? NSNumber).map {
      Int64(Date().timeIntervalSince1970 * 1000) + $0.int64Value * 1000
    }
    return UgotTokenData(accessToken: accessToken, refreshToken: refreshToken, expiresAtMs: expiresAtMs)
  }
}

enum UgotAuthStore {
  private static let service = "uk.ugot.galleryios"
  private static let account = "ugot_tokens"

  static func save(_ tokenData: UgotTokenData) throws {
    let data = try JSONEncoder().encode(tokenData)
    clear()
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    let status = SecItemAdd(query as CFDictionary, nil)
    if status != errSecSuccess {
      throw UgotAuthError.tokenExchangeFailed("Could not save session in Keychain (\(status))")
    }
  }

  static func load() -> UgotTokenData? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess, let data = item as? Data else { return nil }
    return try? JSONDecoder().decode(UgotTokenData.self, from: data)
  }

  static func hasRestorableSession() -> Bool {
    guard let tokenData = load() else { return false }
    if !tokenData.isExpired { return true }
    return tokenData.refreshToken?.nilIfBlank != nil
  }

  static func accessToken() -> String? {
    guard let tokenData = load(), !tokenData.isExpired else { return nil }
    return tokenData.accessToken
  }

  static func validAccessToken() async throws -> String? {
    guard let tokenData = load() else { return nil }
    if !tokenData.isExpired {
      return tokenData.accessToken
    }
    guard let refreshToken = tokenData.refreshToken?.nilIfBlank else {
      clear()
      return nil
    }
    let refreshed = try await UgotAuthService.refreshTokens(refreshToken: refreshToken)
    try save(refreshed)
    return refreshed.accessToken
  }

  static func clear() {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    SecItemDelete(query as CFDictionary)
  }
}

private extension UIApplication {
  func topMostViewController() -> UIViewController? {
    connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
      .first { $0.isKeyWindow }?
      .rootViewController?
      .topMostPresentedViewController()
  }
}

private extension UIViewController {
  func topMostPresentedViewController() -> UIViewController {
    if let presentedViewController {
      return presentedViewController.topMostPresentedViewController()
    }
    if let navigationController = self as? UINavigationController,
       let visibleViewController = navigationController.visibleViewController {
      return visibleViewController.topMostPresentedViewController()
    }
    if let tabBarController = self as? UITabBarController,
       let selectedViewController = tabBarController.selectedViewController {
      return selectedViewController.topMostPresentedViewController()
    }
    return self
  }
}

private extension String {
  var nilIfBlank: String? {
    isEmpty ? nil : self
  }

  var formEncoded: String {
    addingPercentEncoding(withAllowedCharacters: .urlFormAllowed) ?? self
  }
}

private extension CharacterSet {
  static let urlFormAllowed: CharacterSet = {
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "+&=")
    return allowed
  }()
}
