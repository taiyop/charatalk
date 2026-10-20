import Foundation
import SwiftUI
import CryptoKit
import Network
import SafariServices
import AuthenticationServices

@MainActor
public final class ChatGPTAuthManager: NSObject, ObservableObject, @preconcurrency SFSafariViewControllerDelegate {
    public static let shared = ChatGPTAuthManager()

    // MARK: - Published State
    @Published public private(set) var isSignedIn: Bool = false
    @Published public private(set) var userEmail: String = ""
    @Published public private(set) var userName: String = ""
    @Published public private(set) var isAuthenticating: Bool = false
    @Published public var authErrorMessage: String?
    @Published public private(set) var availableModels: [ChatGPTModel] = []
    @Published public private(set) var isLoadingModels: Bool = false
    @Published public private(set) var modelsErrorMessage: String?
    @Published public private(set) var isChatGPTPlanEnabled: Bool = true
    @Published public private(set) var modelCatalogSession = UUID()
    @Published public var customClientId: String = ""

    // MARK: - Endpoints
    public static let issuer = "https://auth.openai.com"
    public static let authorizationEndpoint = "https://auth.openai.com/api/accounts/authorize"
    public static let tokenEndpoint = "https://auth.openai.com/api/accounts/oauth/token"
    public static let revocationEndpoint = "https://auth.openai.com/api/accounts/oauth/revoke"
    public static let defaultScope = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    public static let defaultResource = ChatGPTOAuth.resource

    // MARK: - Local Loopback Server & PKCE State
    private var loopbackListener: NWListener?
    private var pendingAuthorization: ChatGPTOAuth.AuthorizationAttempt?
    private var safariVC: SFSafariViewController?
    private var modelCatalogTask: Task<[ChatGPTModel], Error>?
    private var hasLoadedModels = false
    private var tokenRefreshTask: Task<String, Error>?
    private var tokenRefreshRejectedToken: String?
    private var tokenRefreshID = UUID()

    // MARK: - Keys
    private let kAccessToken = "chatgpt_access_token"
    private let kRefreshToken = "chatgpt_refresh_token"
    private let kTokenExpiry = "chatgpt_token_expiry"
    private let kUserEmail = "chatgpt_user_email"
    private let kUserName = "chatgpt_user_name"
    private let kIssuedClientId = "chatgpt_issued_client_id"
    private let kAgentHostId = "chatgpt_agent_host_id"
    private let kCustomClientId = "chatgpt_custom_client_id"
    private let kTokenClientId = "chatgpt_token_client_id"
    private let kGrantedScopes = "chatgpt_granted_scopes"

    private override init() {
        super.init()
        loadPersistedState()
    }

    // MARK: - State Persistence
    private func loadPersistedState() {
        let defaults = UserDefaults.standard
        let token = defaults.string(forKey: kAccessToken) ?? ""
        let email = defaults.string(forKey: kUserEmail) ?? ""
        let name = defaults.string(forKey: kUserName) ?? ""
        self.customClientId = defaults.string(forKey: kCustomClientId) ?? ""
        // Legacy sessions have no saved scopes; let the server validate them.
        if let scope = defaults.string(forKey: kGrantedScopes) {
            isChatGPTPlanEnabled = ChatGPTOAuth.permitsChatGPTPlan(scope: scope)
        }

        if !token.isEmpty {
            self.isSignedIn = true
            self.userEmail = email
            self.userName = name
        } else {
            self.isSignedIn = false
        }
    }

    /// ホスト環境の一意な永続識別子 (URN UUID)
    public var agentHostId: String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: kAgentHostId), !existing.isEmpty {
            return existing
        }
        let generated = "urn:uuid:\(UUID().uuidString.lowercased())"
        defaults.set(generated, forKey: kAgentHostId)
        return generated
    }

    /// 有効なOAuth Client ID (カスタム入力 > 動的登録で発行されたID > "dynamic_agent_client")
    public var effectiveClientId: String {
        let trimmedCustom = customClientId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCustom.isEmpty {
            return trimmedCustom
        }
        let issued = UserDefaults.standard.string(forKey: kIssuedClientId) ?? ""
        if !issued.isEmpty {
            return issued
        }
        return ChatGPTOAuth.registrationClientId
    }

    public func setCustomClientId(_ id: String) {
        customClientId = id.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(customClientId, forKey: kCustomClientId)
    }

    // MARK: - Account-specific Model Catalog
    public func loadModels(forceRefresh: Bool = false) async throws -> [ChatGPTModel] {
        guard isSignedIn else {
            throw LLMError.notSignedInToChatGPT
        }
        let session = modelCatalogSession
        // Share a request between the picker and inference. Check it before the
        // cache so a manual refresh cannot race a request using an old model.
        if let task = modelCatalogTask {
            let models = try await task.value
            guard session == modelCatalogSession, isSignedIn else { throw CancellationError() }
            return models
        }
        if hasLoadedModels && !forceRefresh { return availableModels }

        isLoadingModels = true
        modelsErrorMessage = nil
        let task = Task {
            let token = try await self.validAccessToken()
            try Task.checkCancellation()
            do {
                return try await ChatGPTModelCatalog.fetch(accessToken: token)
            } catch ChatGPTModelCatalogError.unauthorized {
                let replacement = try await self.refreshAfterUnauthorized(rejectedToken: token, session: session)
                return try await ChatGPTModelCatalog.fetch(accessToken: replacement)
            }
        }
        modelCatalogTask = task
        defer {
            if session == modelCatalogSession {
                modelCatalogTask = nil
                isLoadingModels = false
            }
        }
        do {
            let models = try await task.value
            guard session == modelCatalogSession, isSignedIn else { throw CancellationError() }
            availableModels = models
            // Do not make a transient empty catalog sticky for inference.
            hasLoadedModels = !models.isEmpty
            return models
        } catch {
            if session == modelCatalogSession && !(error is CancellationError) {
                modelsErrorMessage = error.localizedDescription
            }
            throw error
        }
    }

    public func inferenceConfiguration() async throws -> (accessToken: String, model: String, session: UUID) {
        let session = modelCatalogSession
        do {
            try requireChatGPTPlanPermission()
            let models = try await loadModels()
            let token = try await validAccessToken()
            try requireSession(session)
            try requireChatGPTPlanPermission()
            guard let slug = ChatGPTModelCatalog.selectedSlug(preferred: AppSettings.shared.chatGPTModelName, models: models) else {
                throw LLMError.missingChatGPTModel
            }
            // Only an explicit picker selection changes the saved preference.
            return (accessToken: token, model: slug, session: session)
        } catch {
            try requireSession(session)
            throw error
        }
    }

    private func requireSession(_ session: UUID) throws {
        guard isSignedIn else { throw LLMError.notSignedInToChatGPT }
        guard session == modelCatalogSession else { throw LLMError.chatGPTSessionChanged }
    }

    private func requireChatGPTPlanPermission() throws {
        guard isChatGPTPlanEnabled else {
            throw NSError(domain: "ChatGPTAuth", code: 401, userInfo: [NSLocalizedDescriptionKey: "ChatGPTプランの利用権限がありません。設定の「利用権限を再認証」からプラン利用を許可してください。"])
        }
    }

    private func resetModelCatalog() {
        modelCatalogSession = UUID()
        tokenRefreshTask?.cancel()
        tokenRefreshTask = nil
        tokenRefreshRejectedToken = nil
        tokenRefreshID = UUID()
        modelCatalogTask?.cancel()
        modelCatalogTask = nil
        availableModels = []
        hasLoadedModels = false
        isLoadingModels = false
        modelsErrorMessage = nil
    }

    // MARK: - Start Sign in with ChatGPT Flow
    public func startSignIn(requestPlanConsent: Bool = false) {
        guard !isAuthenticating else { return }
        authErrorMessage = nil
        isAuthenticating = true

        // 1. PKCE パラメータ生成
        let verifier = Self.generateCodeVerifier()
        let state = Self.generateRandomString(length: 32)
        let nonce = Self.generateRandomString(length: 32)
        let clientId = effectiveClientId

        // 2. ローカルループバックサーバー (127.0.0.1:1455) 起動
        startLoopbackListener(port: 1455) { [weak self] callbackURL in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.handleCallback(url: callbackURL)
            }
        } failure: { [weak self] errorMsg in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.pendingAuthorization = nil
                self.stopLoopbackListener()
                self.isAuthenticating = false
                self.authErrorMessage = "ローカル待機サーバーの起動に失敗しました: \(errorMsg)"
            }
        } ready: { [weak self] actualPort in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let redirectURI = "http://127.0.0.1:\(actualPort)/auth/callback"
                let attempt = ChatGPTOAuth.AuthorizationAttempt(clientId: clientId, redirectURI: redirectURI, state: state, verifier: verifier)
                self.pendingAuthorization = attempt
                self.launchBrowserAuth(attempt: attempt, nonce: nonce, requestPlanConsent: requestPlanConsent)
            }
        }
    }

    private func launchBrowserAuth(attempt: ChatGPTOAuth.AuthorizationAttempt, nonce: String, requestPlanConsent: Bool) {
        var components = URLComponents(string: Self.authorizationEndpoint)!
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: attempt.clientId),
            URLQueryItem(name: "redirect_uri", value: attempt.redirectURI),
            URLQueryItem(name: "scope", value: Self.defaultScope),
            URLQueryItem(name: "resource", value: Self.defaultResource),
            URLQueryItem(name: "state", value: attempt.state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "code_challenge", value: Self.generateCodeChallenge(from: attempt.verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "ext_agent_host_id", value: agentHostId)
        ]

        if attempt.clientId == ChatGPTOAuth.registrationClientId {
            queryItems.append(URLQueryItem(name: "agent_name_hint", value: "CharaTalk"))
        }
        if requestPlanConsent {
            // Re-consent only after the user's explicit recovery action.
            queryItems.append(URLQueryItem(name: "prompt", value: "consent"))
        }

        components.queryItems = queryItems
        guard let authURL = components.url else {
            pendingAuthorization = nil
            isAuthenticating = false
            authErrorMessage = "認証URLの構築に失敗しました。"
            stopLoopbackListener()
            return
        }

        // アプリ内 SafariViewController を表示 (アプリがフォアグラウンドに維持されるため 127.0.0.1 へのリダイレクトが即座に捕捉可能)
        if let rootVC = Self.topViewController() {
            let safari = SFSafariViewController(url: authURL)
            safari.delegate = self
            safari.dismissButtonStyle = .close
            safari.preferredControlTintColor = UIColor(AppTheme.puppyPink)
            self.safariVC = safari
            rootVC.present(safari, animated: true)
        } else {
            // フォールバック: システムブラウザ起動
            UIApplication.shared.open(authURL)
        }
    }

    public func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        guard safariVC === controller else { return }
        safariVC = nil
        pendingAuthorization = nil
        stopLoopbackListener()
        isAuthenticating = false
    }

    // MARK: - Loopback HTTP Server
    private func startLoopbackListener(
        port: UInt16,
        handler: @escaping @Sendable (URL) -> Void,
        failure: @escaping @Sendable (String) -> Void,
        ready: @escaping @Sendable (UInt16) -> Void
    ) {
        stopLoopbackListener()

        do {
            let tcpOptions = NWProtocolTCP.Options()
            let params = NWParameters(tls: nil, tcp: tcpOptions)
            params.allowLocalEndpointReuse = true

            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port) ?? .any)
            self.loopbackListener = listener

            listener.newConnectionHandler = { [weak self, weak listener] connection in
                connection.start(queue: .main)
                let boundPort = listener?.port?.rawValue ?? port
                Task { @MainActor [weak self] in
                    self?.receiveHTTP(on: connection, port: boundPort, handler: handler)
                }
            }

            listener.stateUpdateHandler = { [weak listener] state in
                switch state {
                case .ready:
                    let boundPort = listener?.port?.rawValue ?? port
                    ready(boundPort)
                case .failed(let err):
                    failure(err.localizedDescription)
                default:
                    break
                }
            }

            listener.start(queue: .main)
        } catch {
            failure(error.localizedDescription)
        }
    }

    private func receiveHTTP(on connection: NWConnection, port: UInt16, handler: @escaping @Sendable (URL) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { content, _, _, _ in
            guard let content = content, let reqString = String(data: content, encoding: .utf8) else {
                connection.cancel()
                return
            }

            // HTTPリクエストの1行目 (GET /auth/callback?... HTTP/1.1) を抽出
            let lines = reqString.components(separatedBy: "\r\n")
            if let firstLine = lines.first, firstLine.hasPrefix("GET ") {
                let parts = firstLine.split(separator: " ")
                if parts.count >= 2 {
                    let pathAndQuery = String(parts[1])
                    if let fullURL = URL(string: "http://127.0.0.1:\(port)" + pathAndQuery),
                       fullURL.path == "/auth/callback" {
                        // コールバック受信はトークン交換成功を意味しない。
                        let html = """
                        HTTP/1.1 200 OK\r
                        Content-Type: text/html; charset=utf-8\r
                        Connection: close\r
                        \r
                        <!DOCTYPE html>
                        <html>
                        <head><meta charset="utf-8"><title>CharaTalk - 認証処理中</title></head>
                        <body style="font-family: -apple-system, sans-serif; text-align: center; padding: 40px; background: #fff5f8;">
                            <h2 style="color: #ff5e98;">Sign in with ChatGPT 認証処理中</h2>
                            <p style="color: #444;">アプリに戻って認証結果を確認してください。</p>
                            <script>setTimeout(function(){ window.close(); }, 1200);</script>
                        </body>
                        </html>
                        """
                        let respData = html.data(using: .utf8) ?? Data()
                        connection.send(content: respData, completion: .contentProcessed({ _ in
                            connection.cancel()
                        }))

                        handler(fullURL)
                        return
                    }
                }
            }
            connection.cancel()
        }
    }

    private func stopLoopbackListener() {
        loopbackListener?.newConnectionHandler = nil
        loopbackListener?.stateUpdateHandler = nil
        loopbackListener?.cancel()
        loopbackListener = nil
    }

    // MARK: - Callback Handling & Token Exchange
    public func handleCallback(url: URL) {
        // Ignore unrelated, stale, or replayed callbacks without interrupting
        // the current attempt. Consume a matching attempt before any await.
        guard let attempt = pendingAuthorization, attempt.matchesCallback(url) else { return }
        pendingAuthorization = nil
        stopLoopbackListener()

        // SFSafariViewController を閉じる
        if let svc = self.safariVC {
            svc.dismiss(animated: true)
            self.safariVC = nil
        }

        let parameters: [String: String]
        do {
            parameters = try attempt.tokenParameters(callback: url)
        } catch {
            isAuthenticating = false
            authErrorMessage = error.localizedDescription
            return
        }

        // Retain the issued ID even if the code is rejected, so the next
        // explicit sign-in reauthorizes instead of registering again.
        if attempt.clientId == ChatGPTOAuth.registrationClientId {
            UserDefaults.standard.set(parameters["client_id"], forKey: kIssuedClientId)
        }

        Task {
            await exchangeCodeForTokens(parameters: parameters)
        }
    }

    private func exchangeCodeForTokens(parameters: [String: String]) async {
        do {
            var request = URLRequest(url: URL(string: Self.tokenEndpoint)!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

            request.httpBody = ChatGPTOAuth.formEncodedBody(parameters)

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResp = response as? HTTPURLResponse else {
                throw NSError(domain: "ChatGPTAuth", code: 1, userInfo: [NSLocalizedDescriptionKey: "有効なレスポンスを受信できませんでした。"])
            }

            guard (200...299).contains(httpResp.statusCode) else {
                throw ChatGPTOAuth.tokenExchangeError(data: data, statusCode: httpResp.statusCode)
            }

            let tokenResp = try JSONDecoder().decode(ChatGPTOAuth.TokenResponse.self, from: data)
            guard !tokenResp.access_token.isEmpty else { throw LLMError.invalidResponse }

            // トークン保存
            let defaults = UserDefaults.standard
            defaults.set(tokenResp.access_token, forKey: kAccessToken)
            defaults.set(parameters["client_id"], forKey: kTokenClientId)
            // OAuth omits `scope` when it is identical to the requested set.
            let scope = tokenResp.scope ?? Self.defaultScope
            defaults.set(scope, forKey: kGrantedScopes)
            isChatGPTPlanEnabled = ChatGPTOAuth.permitsChatGPTPlan(scope: scope)
            if let rt = tokenResp.refresh_token {
                defaults.set(rt, forKey: kRefreshToken)
            } else {
                defaults.removeObject(forKey: kRefreshToken)
            }
            if let exp = tokenResp.expires_in {
                let expiryDate = Date().addingTimeInterval(TimeInterval(exp))
                defaults.set(expiryDate.timeIntervalSince1970, forKey: kTokenExpiry)
            } else {
                defaults.removeObject(forKey: kTokenExpiry)
            }

            // IDトークンからユーザー情報 (email / name) を抽出
            var email = ""
            var name = ""
            if let idTok = tokenResp.id_token {
                let claims = Self.decodeJWTPayload(idTok)
                email = claims["email"] as? String ?? ""
                name = claims["name"] as? String ?? (claims["preferred_username"] as? String ?? "")
            }

            defaults.set(email, forKey: kUserEmail)
            defaults.set(name, forKey: kUserName)

            self.userEmail = email
            self.userName = name
            resetModelCatalog()
            self.isSignedIn = true
            self.isAuthenticating = false
            self.authErrorMessage = nil
        } catch {
            self.isAuthenticating = false
            self.authErrorMessage = error.localizedDescription
        }
    }

    // MARK: - Valid Access Token (with Auto-Refresh)
    public func validAccessToken() async throws -> String {
        let defaults = UserDefaults.standard
        let currentToken = defaults.string(forKey: kAccessToken) ?? ""
        let expiryTimestamp = defaults.double(forKey: kTokenExpiry)

        guard !currentToken.isEmpty else {
            throw NSError(domain: "ChatGPTAuth", code: 401, userInfo: [NSLocalizedDescriptionKey: "ChatGPTにサインインしてください。"])
        }

        // 有効期限が残り60秒以内であればリフレッシュ
        let now = Date().timeIntervalSince1970
        if expiryTimestamp > 0 && now >= (expiryTimestamp - 60) {
            return try await refreshAfterUnauthorized(rejectedToken: currentToken, session: modelCatalogSession)
        }

        return currentToken
    }

    /// A 401 can arrive before the advertised expiry. Refresh once, sharing the
    /// rotating refresh token with any concurrent catalog/inference request.
    public func refreshAfterUnauthorized(rejectedToken: String, session: UUID) async throws -> String {
        try requireSession(session)
        try requireChatGPTPlanPermission()
        let defaults = UserDefaults.standard
        let current = defaults.string(forKey: kAccessToken) ?? ""
        if !current.isEmpty && current != rejectedToken { return current }
        while let task = tokenRefreshTask {
            let joinedRefreshID = tokenRefreshID
            let tokenBeingReplaced = tokenRefreshRejectedToken
            let token = try await task.value
            try requireSession(session)
            try requireChatGPTPlanPermission()
            // A 401 for a newly rotated token must not join a completed refresh
            // that replaced its predecessor and return the same rejected token.
            if token != rejectedToken || tokenBeingReplaced == rejectedToken { return token }
            if tokenRefreshID == joinedRefreshID {
                tokenRefreshTask = nil
                tokenRefreshRejectedToken = nil
            }
        }
        let refreshToken = defaults.string(forKey: kRefreshToken) ?? ""
        guard !refreshToken.isEmpty else {
            throw NSError(domain: "ChatGPTAuth", code: 401, userInfo: [NSLocalizedDescriptionKey: "ChatGPTの認証を更新できません。設定の「利用権限を再認証」からサインインし直してください。"])
        }
        let clientId = defaults.string(forKey: kTokenClientId) ?? effectiveClientId
        let task = Task {
            try await self.refreshAccessToken(refreshToken: refreshToken, clientId: clientId, session: session)
        }
        let refreshID = UUID()
        tokenRefreshID = refreshID
        tokenRefreshRejectedToken = rejectedToken
        tokenRefreshTask = task
        defer {
            if session == modelCatalogSession && tokenRefreshID == refreshID {
                tokenRefreshTask = nil
                tokenRefreshRejectedToken = nil
            }
        }
        let token = try await task.value
        try requireSession(session)
        return token
    }

    private func refreshAccessToken(refreshToken: String, clientId: String, session: UUID) async throws -> String {
        try Task.checkCancellation()
        try requireSession(session)
        var request = URLRequest(url: URL(string: Self.tokenEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let params: [String: String] = [
            "grant_type": "refresh_token",
            "client_id": clientId,
            "refresh_token": refreshToken,
            "resource": Self.defaultResource
        ]

        request.httpBody = ChatGPTOAuth.formEncodedBody(params)

        let (data, response) = try await URLSession.shared.data(for: request)
        try requireSession(session)
        guard let httpResp = response as? HTTPURLResponse else { throw LLMError.invalidResponse }
        guard (200...299).contains(httpResp.statusCode) else {
            let error = ChatGPTOAuth.refreshError(data: data, statusCode: httpResp.statusCode)
            if ChatGPTOAuth.isTerminalRefreshError(data: data) {
                signOut()
                authErrorMessage = error.localizedDescription
            }
            throw error
        }

        let resp = try JSONDecoder().decode(ChatGPTOAuth.TokenResponse.self, from: data)
        guard !resp.access_token.isEmpty else { throw LLMError.invalidResponse }
        let defaults = UserDefaults.standard
        defaults.set(resp.access_token, forKey: kAccessToken)
        defaults.set(clientId, forKey: kTokenClientId)
        if let scope = resp.scope {
            defaults.set(scope, forKey: kGrantedScopes)
            isChatGPTPlanEnabled = ChatGPTOAuth.permitsChatGPTPlan(scope: scope)
        }
        if let newRt = resp.refresh_token {
            defaults.set(newRt, forKey: kRefreshToken)
        }
        if let exp = resp.expires_in {
            defaults.set(Date().addingTimeInterval(TimeInterval(exp)).timeIntervalSince1970, forKey: kTokenExpiry)
        } else {
            defaults.removeObject(forKey: kTokenExpiry)
        }

        try requireChatGPTPlanPermission()
        return resp.access_token
    }

    // MARK: - Sign Out
    public func signOut() {
        resetModelCatalog()
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: kAccessToken)
        defaults.removeObject(forKey: kRefreshToken)
        defaults.removeObject(forKey: kTokenExpiry)
        defaults.removeObject(forKey: kUserEmail)
        defaults.removeObject(forKey: kUserName)
        defaults.removeObject(forKey: kTokenClientId)
        defaults.removeObject(forKey: kGrantedScopes)

        self.isSignedIn = false
        self.isChatGPTPlanEnabled = true
        self.userEmail = ""
        self.userName = ""
        self.isAuthenticating = false
        self.authErrorMessage = nil
    }

    // MARK: - Helpers
    private static func generateCodeVerifier() -> String {
        var buffer = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer)
        return Data(buffer).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func generateCodeChallenge(from verifier: String) -> String {
        let data = Data(verifier.utf8)
        let hash = SHA256.hash(data: data)
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func generateRandomString(length: Int) -> String {
        var buffer = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer)
        return Data(buffer).map { String(format: "%02x", $0) }.joined()
    }

    private static func decodeJWTPayload(_ jwt: String) -> [String: Any] {
        let segments = jwt.split(separator: ".")
        guard segments.count >= 2 else { return [:] }
        var base64 = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 {
            base64.append("=")
        }
        guard let data = Data(base64Encoded: base64),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return [:]
        }
        return json
    }

    private static func topViewController() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.windows.first(where: { $0.isKeyWindow }),
              var top = window.rootViewController else {
            return nil
        }
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }
}
