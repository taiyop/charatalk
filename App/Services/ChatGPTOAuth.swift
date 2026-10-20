import Foundation

/// OAuth request construction, kept independent of the browser and token storage.
enum ChatGPTOAuth {
    static let resource = "https://api.openai.com/v1"
    static let registrationClientId = "dynamic_agent_client"

    static func formEncodedBody(_ parameters: [String: String]) -> Data {
        // Query encoding is not form encoding: in particular, a literal '+' must
        // be escaped so the token endpoint does not decode it as a space.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let body = parameters.keys.sorted().map { key in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed)!
            let encodedValue = parameters[key]!.addingPercentEncoding(withAllowedCharacters: allowed)!
            return "\(encodedKey)=\(encodedValue)"
        }.joined(separator: "&")
        return Data(body.utf8)
    }

    struct AuthorizationAttempt: Sendable {
        let clientId: String
        let redirectURI: String
        let state: String
        let verifier: String

        func matchesCallback(_ url: URL) -> Bool {
            guard let expected = URLComponents(string: redirectURI),
                  let actual = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  actual.scheme == expected.scheme,
                  actual.host == expected.host,
                  actual.port == expected.port,
                  actual.path == expected.path,
                  actual.user == nil, actual.password == nil, actual.fragment == nil else {
                return false
            }
            let states = (actual.queryItems ?? []).filter { $0.name == "state" }
            return states.count == 1 && states.first?.value == state
        }

        func tokenParameters(callback url: URL) throws -> [String: String] {
            guard matchesCallback(url) else {
                throw CallbackError.invalidCallback
            }
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            for key in ["code", "client_id", "error", "error_description"] {
                guard items.filter({ $0.name == key }).count <= 1 else {
                    throw CallbackError.invalidCallback
                }
            }
            if items.contains(where: { $0.name == "error" }) {
                // Do not display raw callback values (which may contain secrets).
                throw CallbackError.authorizationDenied
            }
            guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
                throw CallbackError.missingCode
            }
            let returnedClientId = items.first(where: { $0.name == "client_id" })?.value
            let exchangeClientId: String
            if clientId == ChatGPTOAuth.registrationClientId {
                guard let issued = returnedClientId, !issued.isEmpty,
                      issued != ChatGPTOAuth.registrationClientId else {
                    throw CallbackError.missingClientId
                }
                exchangeClientId = issued
            } else {
                guard returnedClientId == nil || returnedClientId == clientId else {
                    throw CallbackError.clientIdMismatch
                }
                exchangeClientId = clientId
            }
            return [
                "grant_type": "authorization_code",
                "client_id": exchangeClientId,
                "code": code,
                "redirect_uri": redirectURI,
                "code_verifier": verifier,
                "resource": ChatGPTOAuth.resource
            ]
        }
    }

    enum CallbackError: LocalizedError {
        case invalidCallback, authorizationDenied, missingCode, missingClientId, clientIdMismatch

        var errorDescription: String? {
            switch self {
            case .invalidCallback:
                return "認証コールバックの検証に失敗しました。もう一度サインインしてください。"
            case .authorizationDenied:
                return "認証が拒否またはキャンセルされました。もう一度サインインしてください。"
            case .missingCode:
                return "コールバックに必要な認証コードが見つかりませんでした。"
            case .missingClientId:
                return "登録済み Client ID が返されませんでした。もう一度サインインしてください。"
            case .clientIdMismatch:
                return "認証開始時と異なる Client ID が返されました。もう一度サインインしてください。"
            }
        }
    }

    struct TokenResponse: Decodable, Sendable {
        let access_token: String
        let refresh_token: String?
        let id_token: String?
        let expires_in: Int?
        let scope: String?
    }

    static func permitsChatGPTPlan(scope: String) -> Bool {
        scope.split(whereSeparator: \.isWhitespace).contains { String($0) == "chatgpt.tokens.use.direct" }
    }

    private static let terminalRefreshErrorCodes: Set<String> = [
        "invalid_grant",
        "invalid_refresh_token",
        "token_expired",
        "refresh_token_expired",
        "refresh_token_invalidated",
        "refresh_token_reused"
    ]

    /// Extracts only a top-level `error` string or a nested `error.code` string.
    /// Never returns messages, descriptions, or any other server-provided text.
    private static func errorCode(from data: Data) -> String? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        if let code = json["error"] as? String {
            return code
        }
        if let nested = json["error"] as? [String: Any], let code = nested["code"] as? String {
            return code
        }
        return nil
    }

    static func isTerminalRefreshError(data: Data) -> Bool {
        guard let code = errorCode(from: data) else { return false }
        return terminalRefreshErrorCodes.contains(code)
    }

    static func refreshError(data: Data, statusCode: Int) -> NSError {
        let code = errorCode(from: data)
        let message: String
        if let code, terminalRefreshErrorCodes.contains(code) {
            message = "セッションの有効期限が切れました。もう一度サインインしてください。"
        } else if code == "invalid_client" {
            message = "トークン更新失敗 (invalid_client): サインアウト後、高度な設定の OAuth Client ID を確認してサインインし直してください。認証情報は保持しています。"
        } else if statusCode == 429 || (500...599).contains(statusCode) {
            // Transient upstream trouble: keep credentials and let the user retry.
            message = "トークン更新に一時的に失敗しました (HTTP \(statusCode))。時間をおいて再試行してください。認証情報は保持しています。"
        } else {
            message = "トークン更新に失敗しました (HTTP \(statusCode))。もう一度サインインしてください。"
        }
        return NSError(domain: "ChatGPTAuth", code: statusCode, userInfo: [NSLocalizedDescriptionKey: message])
    }

    static func tokenExchangeError(data: Data, statusCode: Int) -> NSError {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let nested = json?["error"] as? [String: Any]
        let code = (json?["error"] as? String) ?? (nested?["code"] as? String)
        let message: String
        switch code {
        case "invalid_grant":
            message = "トークン取得失敗 (invalid_grant): 認証コードが無効または期限切れです。登録済み Client ID は保持しています。もう一度サインインしてください。"
        case "invalid_client":
            message = "トークン取得失敗 (invalid_client): 高度な設定の OAuth Client ID を確認してください。"
        default:
            // Avoid putting raw token-endpoint responses into the UI or logs.
            message = "トークン取得失敗 (HTTP \(statusCode))。時間をおいて再度サインインしてください。"
        }
        return NSError(domain: "ChatGPTAuth", code: statusCode, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
