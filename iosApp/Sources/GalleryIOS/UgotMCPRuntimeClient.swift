import Foundation

final class UgotMCPRuntimeClient {
  private enum Backend {
    case http(UgotMCPClient)
    case embeddedMail(UgotEmbeddedMailMCPClient)
  }

  let connectorId: String
  let endpoint: URL
  private let backend: Backend

  private init(connectorId: String, endpoint: URL, backend: Backend) {
    self.connectorId = connectorId
    self.endpoint = endpoint
    self.backend = backend
  }

  static func make(connectorId: String, endpoint: URL, accessToken: String) -> UgotMCPRuntimeClient {
    if endpoint.scheme == "embedded", connectorId == GalleryConnector.mailMcpId {
      return UgotMCPRuntimeClient(
        connectorId: connectorId,
        endpoint: endpoint,
        backend: .embeddedMail(UgotEmbeddedMailMCPClient(
          connectorId: connectorId,
          endpoint: endpoint,
          ugotAccessToken: accessToken
        ))
      )
    }
    let bearerToken: String?
    if let connector = GalleryConnector.connector(for: connectorId) {
      bearerToken = connector.bearerTokenForRequest(ugotAccessToken: accessToken)
    } else {
      bearerToken = accessToken
    }
    return UgotMCPRuntimeClient(
      connectorId: connectorId,
      endpoint: endpoint,
      backend: .http(UgotMCPClient(connectorId: connectorId, endpoint: endpoint, bearerToken: bearerToken))
    )
  }

  func initialize() async throws {
    switch backend {
    case .http(let client): try await client.initialize()
    case .embeddedMail(let client): try await client.initialize()
    }
  }

  func request(method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
    switch backend {
    case .http(let client): return try await client.request(method: method, params: params)
    case .embeddedMail(let client): return try await client.request(method: method, params: params)
    }
  }

  func listTools() async throws -> [[String: Any]] {
    switch backend {
    case .http(let client): return try await client.listTools()
    case .embeddedMail(let client): return try await client.listTools()
    }
  }

  func listPrompts() async throws -> [[String: Any]] {
    switch backend {
    case .http(let client): return try await client.listPrompts()
    case .embeddedMail(let client): return try await client.listPrompts()
    }
  }

  func getPrompt(name: String, arguments: [String: Any] = [:]) async throws -> [String: Any] {
    switch backend {
    case .http(let client): return try await client.getPrompt(name: name, arguments: arguments)
    case .embeddedMail(let client): return try await client.getPrompt(name: name, arguments: arguments)
    }
  }

  func completePromptArgument(
    promptName: String,
    argumentName: String,
    partialValue: String = "",
    arguments: [String: String] = [:]
  ) async throws -> UgotMCPPromptCompletionResult {
    switch backend {
    case .http(let client):
      return try await client.completePromptArgument(
        promptName: promptName,
        argumentName: argumentName,
        partialValue: partialValue,
        arguments: arguments
      )
    case .embeddedMail(let client):
      return try await client.completePromptArgument(
        promptName: promptName,
        argumentName: argumentName,
        partialValue: partialValue,
        arguments: arguments
      )
    }
  }

  func listResources() async throws -> [[String: Any]] {
    switch backend {
    case .http(let client): return try await client.listResources()
    case .embeddedMail(let client): return try await client.listResources()
    }
  }

  func callTool(name: String, arguments: [String: Any]) async throws -> [String: Any] {
    switch backend {
    case .http(let client): return try await client.callTool(name: name, arguments: arguments)
    case .embeddedMail(let client): return try await client.callTool(name: name, arguments: arguments)
    }
  }

  func readResource(uri: String) async throws -> [String: Any]? {
    switch backend {
    case .http(let client): return try await client.readResource(uri: uri)
    case .embeddedMail(let client): return try await client.readResource(uri: uri)
    }
  }

  func resolveWidgetResource(
    tools: [[String: Any]],
    toolName: String,
    result: [String: Any]
  ) async throws -> UgotMCPWidgetResource? {
    switch backend {
    case .http(let client): return try await client.resolveWidgetResource(tools: tools, toolName: toolName, result: result)
    case .embeddedMail(let client): return try await client.resolveWidgetResource(tools: tools, toolName: toolName, result: result)
    }
  }

  func widgetBaseURL(for uri: String) -> String {
    switch backend {
    case .http(let client): return client.widgetBaseURL(for: uri)
    case .embeddedMail(let client): return client.widgetBaseURL(for: uri)
    }
  }
}

private extension String {
  var trimmedNonEmpty: String? {
    let value = trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }
}

final class UgotEmbeddedMailMCPClient {
  let connectorId: String
  let endpoint: URL
  private let ugotAccessToken: String
  private var didInitialize = false

  init(connectorId: String, endpoint: URL, ugotAccessToken: String = "") {
    self.connectorId = connectorId
    self.endpoint = endpoint
    self.ugotAccessToken = ugotAccessToken
  }

  func initialize() async throws {
    guard !didInitialize else { return }
    let dbPath = try Self.embeddedDatabasePath()
    let response = try Self.invokeRust({ ptr in mail_mcp_rs_embedded_init(ptr) }, stringArg: dbPath)
    guard (response["ok"] as? Bool) != false else {
      throw EmbeddedMailError.rust(response["error"] as? String ?? "Failed to initialize embedded mail-mcp-rs")
    }
    didInitialize = true
  }

  func request(method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
    try await initialize()
    switch method {
    case "tools/list":
      return try await listToolsResult()
    case "tools/call":
      guard let name = params["name"] as? String else {
        throw EmbeddedMailError.invalidRequest("tools/call requires name")
      }
      let arguments = params["arguments"] as? [String: Any] ?? [:]
      return try await callTool(name: name, arguments: arguments)
    case "resources/list":
      return ["resources": []]
    case "prompts/list":
      return try await listPromptsResult(locale: Self.locale(from: params))
    case "prompts/get":
      guard let name = params["name"] as? String else {
        throw EmbeddedMailError.invalidRequest("prompts/get requires name")
      }
      return try await getPromptResult(name: name, locale: Self.locale(from: params))
    case "completion/complete":
      return ["completion": ["values": [], "total": 0, "hasMore": false]]
    default:
      throw EmbeddedMailError.invalidRequest("Unsupported embedded mail MCP method: \(method)")
    }
  }

  func listTools() async throws -> [[String: Any]] {
    let result = try await listToolsResult()
    return result["tools"] as? [[String: Any]] ?? []
  }

  func listPrompts() async throws -> [[String: Any]] {
    let result = try await listPromptsResult()
    return result["prompts"] as? [[String: Any]] ?? []
  }

  func getPrompt(name: String, arguments: [String: Any] = [:]) async throws -> [String: Any] {
    try await getPromptResult(name: name)
  }

  func completePromptArgument(
    promptName: String,
    argumentName: String,
    partialValue: String = "",
    arguments: [String: String] = [:]
  ) async throws -> UgotMCPPromptCompletionResult {
    .empty
  }

  func listResources() async throws -> [[String: Any]] { [] }

  func callTool(name: String, arguments: [String: Any]) async throws -> [String: Any] {
    try await initialize()
    if name == "get_oauth_url",
       let result = try await embeddedOAuthURLResult(arguments: arguments) {
      return result
    }
    let resolvedArguments = try await resolvedEmbeddedToolArguments(name: name, arguments: arguments)
    return try callRustTool(name: name, arguments: resolvedArguments)
  }

  func readResource(uri: String) async throws -> [String: Any]? { nil }

  func resolveWidgetResource(
    tools: [[String: Any]],
    toolName: String,
    result: [String: Any]
  ) async throws -> UgotMCPWidgetResource? {
    Self.mailWidgetResource(toolName: toolName, result: result)
  }

  func widgetBaseURL(for uri: String) -> String {
    endpoint.absoluteString
  }

  private func callRustTool(name: String, arguments: [String: Any]) throws -> [String: Any] {
    let argsJson = try Self.jsonString(arguments)
    return try Self.invokeRust({ namePtr in
      argsJson.withCString { argsPtr in
        mail_mcp_rs_embedded_call_tool(namePtr, argsPtr)
      }
    }, stringArg: name)
  }

  private func resolvedEmbeddedToolArguments(
    name: String,
    arguments: [String: Any]
  ) async throws -> [String: Any] {
    let action = (arguments["action"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard name == "sync_oauth_account" || (name == "mail_account_ops" && action == "sync") else {
      return arguments
    }
    return try await hydratedGoogleOAuthArguments(arguments)
  }

  private func hydratedGoogleOAuthArguments(_ arguments: [String: Any]) async throws -> [String: Any] {
    let provider = ((arguments["provider"] as? String)?.trimmedNonEmpty ?? "google").lowercased()
    guard provider == "google",
          (arguments["email"] as? String)?.trimmedNonEmpty == nil ||
          (arguments["access_token"] as? String)?.trimmedNonEmpty == nil else {
      return arguments
    }

    guard let token = try await resolvedUgotAccessToken() else {
      return arguments
    }

    let url = UgotAuthConfig.authServerBaseURL
      .appendingPathComponent("api")
      .appendingPathComponent("users")
      .appendingPathComponent("tokens")
      .appendingPathComponent("external")
      .appendingPathComponent(provider)
    var request = URLRequest(url: url)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

    let (data, response) = try await URLSession.shared.data(for: request)
    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
    guard (200..<300).contains(statusCode),
          let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return arguments
    }

    var resolved = arguments
    resolved["provider"] = provider
    if resolved["email"] == nil,
       let email = (payload["email"] as? String)?.trimmedNonEmpty {
      resolved["email"] = email
    }
    if resolved["access_token"] == nil,
       let accessToken =
        (payload["accessToken"] as? String)?.trimmedNonEmpty ??
        (payload["access_token"] as? String)?.trimmedNonEmpty {
      resolved["access_token"] = accessToken
    }
    if resolved["refresh_token"] == nil,
       let refreshToken =
        (payload["refreshToken"] as? String)?.trimmedNonEmpty ??
        (payload["refresh_token"] as? String)?.trimmedNonEmpty {
      resolved["refresh_token"] = refreshToken
    }
    return resolved
  }

  private func resolvedUgotAccessToken() async throws -> String? {
    if let token = ugotAccessToken.trimmedNonEmpty {
      return token
    }
    return try await UgotAuthStore.validAccessToken()
  }

  private func embeddedOAuthURLResult(arguments: [String: Any]) async throws -> [String: Any]? {
    let provider = ((arguments["provider"] as? String)?.trimmedNonEmpty ?? "google").lowercased()
    guard provider == "google" else { return nil }

    let redirectURI = (arguments["redirect_uri"] as? String)?.trimmedNonEmpty ?? "https://ugot.uk"
    var authURL: String?
    var state: String?

    if let token = try await resolvedUgotAccessToken() {
      let url = UgotAuthConfig.authServerBaseURL
        .appendingPathComponent("api")
        .appendingPathComponent("connect")
        .appendingPathComponent(provider)
        .appendingPathComponent("initiate")
      var request = URLRequest(url: url)
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      request.httpBody = try JSONSerialization.data(withJSONObject: ["redirectUri": redirectURI])

      let (data, response) = try await URLSession.shared.data(for: request)
      let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
      if (200..<300).contains(statusCode),
         let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
        authURL =
          (payload["auth_url"] as? String)?.trimmedNonEmpty ??
          (payload["url"] as? String)?.trimmedNonEmpty
        state = (payload["state"] as? String)?.trimmedNonEmpty
      }
    }

    if authURL == nil {
      var components = URLComponents(
        url: UgotAuthConfig.authServerBaseURL
          .appendingPathComponent("api")
          .appendingPathComponent("connect")
          .appendingPathComponent(provider),
        resolvingAgainstBaseURL: false
      )
      components?.queryItems = [URLQueryItem(name: "redirect_uri", value: redirectURI)]
      authURL = components?.url?.absoluteString
    }

    let structured: [String: Any] = [
      "viewMode": "auth",
      "provider": provider,
      "url": authURL ?? "",
      "state": state ?? "",
      "needsOAuth": true,
      "notice": "Google 계정 연결 링크가 준비됐어요. 연결을 완료한 뒤 sync_oauth_account로 동기화할 수 있어요.",
    ]
    return [
      "isError": false,
      "content": [
        [
          "type": "text",
          "text": "OAuth URL generated: \(authURL ?? "")",
        ],
      ],
      "structuredContent": structured,
    ]
  }

  private static func mailWidgetResource(toolName: String, result: [String: Any]) -> UgotMCPWidgetResource? {
    guard var structured = result["structuredContent"] as? [String: Any] ?? result["structured_content"] as? [String: Any] else {
      return nil
    }
    let viewMode = (structured["viewMode"] as? String)?.lowercased()
      ?? inferredMailWidgetMode(toolName: toolName, structured: structured)
    guard ["list", "search", "accounts", "mailboxes", "detail", "sync", "auth", "account"].contains(viewMode) else {
      return nil
    }
    structured["viewMode"] = viewMode
    guard JSONSerialization.isValidJSONObject(structured),
          let data = try? JSONSerialization.data(withJSONObject: structured, options: [.sortedKeys]),
          var json = String(data: data, encoding: .utf8) else {
      return nil
    }
    json = json
      .replacingOccurrences(of: "</", with: "<\\/")
      .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
      .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    let title = mailWidgetTitle(toolName: toolName, viewMode: viewMode)
    let html = """
    <!doctype html>
    <html>
    <head>
      <meta charset=\"utf-8\">
      <meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">
      <style>
        :root { color-scheme: light dark; --bg:#fff; --fg:#111827; --muted:#6b7280; --card:#f9fafb; --border:#e5e7eb; --accent:#2563eb; }
        @media (prefers-color-scheme: dark) { :root { --bg:#111827; --fg:#f9fafb; --muted:#9ca3af; --card:#1f2937; --border:#374151; --accent:#60a5fa; } }
        * { box-sizing: border-box; }
        html, body { margin:0; padding:0; background:transparent; color:var(--fg); font-family:-apple-system,BlinkMacSystemFont,\"Segoe UI\",sans-serif; }
        .wrap { padding:14px; border:1px solid var(--border); border-radius:18px; background:var(--bg); }
        .head { display:flex; align-items:flex-start; justify-content:space-between; gap:10px; margin-bottom:12px; }
        .title { font-weight:700; font-size:16px; letter-spacing:-0.01em; }
        .badge { color:var(--accent); background:color-mix(in srgb, var(--accent) 12%, transparent); padding:4px 8px; border-radius:999px; font-size:12px; font-weight:700; white-space:nowrap; }
        .notice { color:var(--muted); font-size:13px; line-height:1.45; padding:10px 12px; border:1px dashed var(--border); border-radius:12px; background:var(--card); margin-bottom:10px; }
        .status { display:flex; align-items:center; gap:8px; font-size:13px; font-weight:700; margin:0 0 10px; }
        .dot { width:9px; height:9px; border-radius:999px; background:#9ca3af; flex:0 0 auto; }
        .ok .dot { background:#10b981; }
        .warn .dot { background:#f59e0b; }
        .bad .dot { background:#ef4444; }
        .list { display:grid; gap:8px; }
        .item { padding:11px 12px; border:1px solid var(--border); border-radius:14px; background:var(--card); }
        .item-title { font-weight:650; font-size:14px; line-height:1.35; overflow-wrap:anywhere; }
        .meta { color:var(--muted); font-size:12px; margin-top:4px; line-height:1.35; overflow-wrap:anywhere; }
        .snippet { color:var(--fg); opacity:.86; font-size:13px; line-height:1.42; margin-top:7px; overflow-wrap:anywhere; }
        .empty { color:var(--muted); font-size:14px; padding:20px 8px; text-align:center; }
        .kv { display:grid; grid-template-columns:72px 1fr; gap:5px 10px; font-size:13px; }
        .k { color:var(--muted); }
        .v { overflow-wrap:anywhere; }
        .actions { display:grid; gap:8px; margin-top:10px; }
        .primary { appearance:none; border:0; border-radius:12px; padding:11px 12px; background:var(--accent); color:white; font-weight:750; font-size:14px; width:100%; text-align:center; }
        .primary:active { opacity:.78; }
        .url-copy { font-size:11px; user-select:text; word-break:break-all; }
      </style>
    </head>
    <body>
      <div class=\"wrap\">
        <div class=\"head\"><div class=\"title\">\(escapeHTML(title))</div><div class=\"badge\">UGOT Mail</div></div>
        <div id=\"root\"></div>
      </div>
      <script id=\"mail-data\" type=\"application/json\">\(json)</script>
      <script>
        const data = JSON.parse(document.getElementById('mail-data').textContent || '{}');
        const root = document.getElementById('root');
        const text = (v) => v == null ? '' : String(v);
        const esc = (v) => text(v).replace(/[&<>\"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','\"':'&quot;',"'":'&#39;'}[c]));
        const first = (obj, keys) => keys.map(k => obj && obj[k]).find(v => v !== undefined && v !== null && String(v).trim() !== '') || '';
        const arr = (...keys) => keys.flatMap(k => Array.isArray(data[k]) ? data[k] : []);
        function isHttpUrl(v) {
          try {
            const url = new URL(text(v));
            return url.protocol === 'http:' || url.protocol === 'https:';
          } catch (_) {
            return false;
          }
        }
        function openExternal(url) {
          if (!isHttpUrl(url)) return;
          try {
            window.webkit?.messageHandlers?.mcpWidget?.postMessage({ type: 'openExternal', url });
            return;
          } catch (_) {}
          try {
            window.open(url, '_blank', 'noopener,noreferrer');
          } catch (_) {
            window.location.href = url;
          }
        }
        function renderExternalAction(url, label) {
          if (!isHttpUrl(url)) return '';
          return `<div class=\"actions\"><button type=\"button\" class=\"primary\" data-open-url=\"${esc(url)}\">${esc(label || '계정 연결 열기')}</button><div class=\"meta url-copy\">${esc(url)}</div></div>`;
        }
        function userNotice() {
          const raw = text(data.notice);
          if (!raw) return '';
          const technical = /embedded|rust|mcp|bridge|oauth[/]imap|native step|mac lan/i.test(raw);
          return technical ? '' : `<div class=\"notice\">${esc(raw)}</div>`;
        }
        function emptyMailText() {
          return data.needsAccount ? '메일을 보려면 계정 연결이 필요해요.' : '표시할 메일이 아직 없어요.';
        }
        function renderMessages(items) {
          if (!items.length) return userNotice() + `<div class=\"empty\">${emptyMailText()}</div>`;
          return userNotice() + `<div class=\"list\">${items.map(m => {
            const subject = first(m, ['subject','title']) || '(제목 없음)';
            const from = first(m, ['from','sender','fromEmail','email']);
            const date = first(m, ['date','receivedAt','timestamp','time']);
            const snippet = first(m, ['snippet','preview','bodyPreview','summary','text']);
            return `<div class=\"item\"><div class=\"item-title\">${esc(subject)}</div><div class=\"meta\">${esc([from,date].filter(Boolean).join(' · '))}</div>${snippet ? `<div class=\"snippet\">${esc(snippet)}</div>` : ''}</div>`;
          }).join('')}</div>`;
        }
        function renderAccounts(items) {
          if (!items.length) return userNotice() + '<div class=\"empty\">연결된 메일 계정이 없어요.</div>';
          return userNotice() + `<div class=\"list\">${items.map(a => {
            const provider = first(a,['provider','host','status']);
            const access = a.hasAccessToken === true ? 'access token 있음' : '';
            const refresh = a.hasRefreshToken === true ? 'refresh token 있음' : '';
            const meta = [provider, access, refresh].filter(Boolean).join(' · ');
            return `<div class=\"item\"><div class=\"item-title\">${esc(first(a,['email','address','name']) || 'Mail account')}</div><div class=\"meta\">${esc(meta)}</div></div>`;
          }).join('')}</div>`;
        }
        function renderSync() {
          const ok = data.success === true || data.ok === true || data.status === 'success' || data.synced === true;
          const failed = data.success === false || data.ok === false || data.isError === true || data.status === 'error' || data.status === 'failed';
          const stateClass = ok ? 'ok' : (failed ? 'bad' : 'warn');
          const stateText = ok ? '계정 동기화 완료' : (failed ? '계정 동기화 실패' : '계정 확인 필요');
          const account = data.account || {};
          const email = first(data, ['email','address','name']) || first(account, ['email','address','name']);
          const provider = first(data, ['provider','host']) || first(account, ['provider','host']);
          const hasAccess = data.hasAccessToken === true || data.accessToken === true || data.access_token === true || !!data.accessTokenPresent || account.hasAccessToken === true;
          const hasRefresh = data.hasRefreshToken === true || data.refreshToken === true || data.refresh_token === true || !!data.refreshTokenPresent || account.hasRefreshToken === true;
          const rows = [
            ['Email', email],
            ['Provider', provider],
            ['Access', hasAccess ? '저장됨' : '확인 필요'],
            ['Refresh', hasRefresh ? '저장됨' : '확인 필요'],
          ].filter(([,v]) => text(v).trim() !== '');
          const url = first(data, ['url','authUrl','auth_url','authorizationUrl','authorization_url']);
          const providerName = provider || first(data, ['provider']) || '계정';
          return userNotice() + `<div class=\"status ${stateClass}\"><span class=\"dot\"></span><span>${esc(stateText)}</span></div><div class=\"item\"><div class=\"kv\">${rows.map(([k,v]) => `<div class=\"k\">${esc(k)}</div><div class=\"v\">${esc(v)}</div>`).join('')}</div>${renderExternalAction(url, `${providerName} 연결 열기`)}</div>`;
        }
        function renderMailboxes(items) {
          if (!items.length) return userNotice() + '<div class=\"empty\">표시할 메일함이 없어요.</div>';
          return userNotice() + `<div class=\"list\">${items.map(f => `<div class=\"item\"><div class=\"item-title\">${esc(first(f,['name','folder','mailbox']) || 'Mailbox')}</div><div class=\"meta\">${esc(first(f,['count','unread','total']))}</div></div>`).join('')}</div>`;
        }
        function renderDetail(email) {
          if (!email) return userNotice() + '<div class=\"empty\">메일 상세가 없어요.</div>';
          const rows = [['From', first(email,['from','sender'])], ['To', first(email,['to','recipient'])], ['Date', first(email,['date','receivedAt'])], ['Subject', first(email,['subject','title'])]];
          return userNotice() + `<div class=\"item\"><div class=\"kv\">${rows.map(([k,v]) => `<div class=\"k\">${esc(k)}</div><div class=\"v\">${esc(v)}</div>`).join('')}</div><div class=\"snippet\">${esc(first(email,['body','text','snippet','summary']))}</div></div>`;
        }
        const mode = data.viewMode || 'list';
        if (mode === 'accounts' || mode === 'account') root.innerHTML = renderAccounts(arr('accounts','identities'));
        else if (mode === 'sync' || mode === 'auth') root.innerHTML = renderSync();
        else if (mode === 'mailboxes') root.innerHTML = renderMailboxes(arr('mailboxes','folders'));
        else if (mode === 'detail') root.innerHTML = renderDetail(data.email || data.message);
        else root.innerHTML = renderMessages(arr('emails','messages'));
        root.querySelectorAll('[data-open-url]').forEach((element) => {
          element.addEventListener('click', () => openExternal(element.getAttribute('data-open-url') || ''));
        });
      </script>
    </body>
    </html>
    """
    return UgotMCPWidgetResource(
      uri: "inline://ugot-mail/\(toolName)",
      mimeType: UgotMCPClient.resourceMimeType,
      html: html,
      csp: nil,
      permissions: nil
    )
  }

  private static func mailWidgetTitle(toolName: String, viewMode: String) -> String {
    switch viewMode {
    case "accounts", "account": return "메일 계정"
    case "sync", "auth": return "메일 계정 동기화"
    case "mailboxes": return "메일함"
    case "detail": return "메일 상세"
    case "search": return "메일 검색 결과"
    default:
      return toolName == "summarize_recent_mail" ? "최근 메일 요약" : "메일 목록"
    }
  }

  private static func inferredMailWidgetMode(toolName: String, structured: [String: Any]) -> String {
    let keys = structured.keys.joined(separator: " ")
    let compact = [toolName, keys].joined(separator: " ")
      .lowercased()
      .replacingOccurrences(of: "[^a-z0-9가-힣]+", with: "", options: .regularExpression)
    if compact.contains("sync") ||
      compact.contains("oauth") ||
      compact.contains("auth") ||
      compact.contains("동기화") ||
      compact.contains("연동") {
      return "sync"
    }
    if compact.contains("account") ||
      compact.contains("identity") ||
      compact.contains("계정") {
      return "accounts"
    }
    if compact.contains("mailbox") ||
      compact.contains("folder") ||
      compact.contains("메일함") {
      return "mailboxes"
    }
    if compact.contains("read") ||
      compact.contains("detail") ||
      compact.contains("상세") {
      return "detail"
    }
    if compact.contains("search") ||
      compact.contains("검색") {
      return "search"
    }
    return "list"
  }

  private static func escapeHTML(_ value: String) -> String {
    value
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "'", with: "&#39;")
  }

  private func listToolsResult() async throws -> [String: Any] {
    try await initialize()
    return try Self.invokeRust { mail_mcp_rs_embedded_list_tools() }
  }

  private func listPromptsResult(locale: String = UgotMCPLocale.preferredLanguageTag) async throws -> [String: Any] {
    try await initialize()
    return try Self.invokeRust({ localePtr in
      mail_mcp_rs_embedded_list_prompts(localePtr)
    }, stringArg: locale)
  }

  private func getPromptResult(
    name: String,
    locale: String = UgotMCPLocale.preferredLanguageTag
  ) async throws -> [String: Any] {
    try await initialize()
    return try Self.invokeRust {
      name.withCString { namePtr in
        locale.withCString { localePtr in
          mail_mcp_rs_embedded_get_prompt(namePtr, localePtr)
        }
      }
    }
  }

  private static func locale(from params: [String: Any]) -> String {
    guard let meta = params["_meta"] as? [String: Any] else {
      return UgotMCPLocale.preferredLanguageTag
    }
    return (meta["locale"] as? String) ??
      (meta["openai/locale"] as? String) ??
      UgotMCPLocale.preferredLanguageTag
  }

  private static func embeddedDatabasePath() throws -> String {
    let appSupport = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let dir = appSupport.appendingPathComponent("MailMCPRS", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("mail_mcp_rs.sqlite").path
  }

  private static func jsonString(_ value: Any) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    return String(data: data, encoding: .utf8) ?? "{}"
  }

  private static func invokeRust(_ call: () -> UnsafeMutablePointer<CChar>?) throws -> [String: Any] {
    guard let ptr = call() else {
      throw EmbeddedMailError.rust("Rust returned null")
    }
    defer { mail_mcp_rs_embedded_free_string(ptr) }
    let text = String(cString: ptr)
    guard let data = text.data(using: .utf8),
          let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw EmbeddedMailError.rust("Invalid Rust JSON response: \(text)")
    }
    return decoded
  }

  private static func invokeRust(
    _ call: (UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?,
    stringArg: String
  ) throws -> [String: Any] {
    try stringArg.withCString { ptr in
      try invokeRust { call(ptr) }
    }
  }

  enum EmbeddedMailError: LocalizedError {
    case rust(String)
    case invalidRequest(String)

    var errorDescription: String? {
      switch self {
      case .rust(let message): return message
      case .invalidRequest(let message): return message
      }
    }
  }
}
