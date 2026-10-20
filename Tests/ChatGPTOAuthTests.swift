import Foundation

// Standalone regression harness for App/Services/ChatGPTOAuth.swift.
//
// This file is compiled together with the helper source and produces a plain
// executable; no XCTest, no test target, no network access. Checks throw on
// failure instead of relying on `assert`, so they stay active in release builds.

struct TestFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

enum CallbackCase: String {
    case invalidCallback
    case authorizationDenied
    case missingCode
    case missingClientId
    case clientIdMismatch
}

@main
struct ChatGPTOAuthTests {
    // MARK: - Fixtures

    static let redirectURI = "http://127.0.0.1:1455/auth/callback"
    static let state = "state-123"
    static let verifier = "verifier-456"
    static let clientId = "client-abc"

    static func attempt(
        clientId: String = clientId,
        redirectURI: String = redirectURI,
        state: String = state,
        verifier: String = verifier
    ) -> ChatGPTOAuth.AuthorizationAttempt {
        ChatGPTOAuth.AuthorizationAttempt(
            clientId: clientId,
            redirectURI: redirectURI,
            state: state,
            verifier: verifier
        )
    }

    static func callback(_ query: String, base: String = redirectURI) -> URL {
        URL(string: "\(base)?\(query)")!
    }

    /// Emulates a server-side form decoder: '+' means space, then percent-decode.
    static func formDecode(_ raw: String) -> String? {
        let plusExpanded = raw.replacingOccurrences(of: "+", with: " ")
        return plusExpanded.removingPercentEncoding
    }

    static func formDecode(_ body: Data) -> [String: String]? {
        guard let text = String(data: body, encoding: .utf8) else { return nil }
        var result: [String: String] = [:]
        for pair in text.split(separator: "&", omittingEmptySubsequences: false) {
            guard let separator = pair.firstIndex(of: "=") else { return nil }
            let rawKey = String(pair[pair.startIndex..<separator])
            let rawValue = String(pair[pair.index(after: separator)...])
            guard let key = formDecode(rawKey), let value = formDecode(rawValue) else { return nil }
            guard result[key] == nil else { return nil }
            result[key] = value
        }
        return result
    }

    // MARK: - Assertions

    static func expectTrue(_ label: String, _ condition: Bool) throws {
        guard condition else { throw TestFailure(message: "\(label): condition was false") }
    }

    static func expectFalse(_ label: String, _ condition: Bool) throws {
        guard !condition else { throw TestFailure(message: "\(label): condition was true") }
    }

    static func expectEqual<T: Equatable>(_ label: String, _ actual: T, _ expected: T) throws {
        guard actual == expected else {
            throw TestFailure(
                message: "\(label): expected \(String(reflecting: expected)), got \(String(reflecting: actual))"
            )
        }
    }

    static func expectContains(_ label: String, _ haystack: String, _ needle: String) throws {
        guard haystack.contains(needle) else {
            throw TestFailure(message: "\(label): expected message to contain \(String(reflecting: needle)), got \(String(reflecting: haystack))")
        }
    }

    static func expectCallbackCase(_ error: Error) -> CallbackCase? {
        guard let callbackError = error as? ChatGPTOAuth.CallbackError else { return nil }
        switch callbackError {
        case .invalidCallback: return .invalidCallback
        case .authorizationDenied: return .authorizationDenied
        case .missingCode: return .missingCode
        case .missingClientId: return .missingClientId
        case .clientIdMismatch: return .clientIdMismatch
        }
    }

    static func expectThrows(
        _ label: String,
        expected: CallbackCase,
        _ body: () throws -> [String: String]
    ) throws {
        do {
            let params = try body()
            throw TestFailure(
                message: "\(label): expected \(expected.rawValue), but call succeeded with \(params.keys.sorted())"
            )
        } catch let failure as TestFailure {
            throw failure
        } catch {
            let actual = expectCallbackCase(error)
            guard actual == expected else {
                throw TestFailure(
                    message: "\(label): expected \(expected.rawValue), got \(actual?.rawValue ?? "non-callback error \(error)")"
                )
            }
        }
    }

    static func tokenError(_ body: String, status: Int = 400) -> NSError {
        ChatGPTOAuth.tokenExchangeError(data: Data(body.utf8), statusCode: status)
    }

    // MARK: - Form encoding

    static func testFormEncodingSortsKeysAndEncodesSpaces() throws {
        let body = ChatGPTOAuth.formEncodedBody(["b": "two words", "a": "1"])
        try expectEqual("sorted pairs", String(data: body, encoding: .utf8), "a=1&b=two%20words")
        try expectFalse("no raw space", String(data: body, encoding: .utf8)!.contains(" "))
    }

    static func testFormEncodingRoundTripsReservedCharacters() throws {
        let parameters = [
            "code": "a+b c&d=e%f#g?h/i",
            "redirect_uri": "http://127.0.0.1:1455/auth/callback?x=1&y=2",
            "verifier": "abc+/=?#%",
            "slash/key": "value/with/slashes"
        ]
        let body = ChatGPTOAuth.formEncodedBody(parameters)
        let raw = try unwrap(String(data: body, encoding: .utf8), "utf8 body")
        try expectEqual("decoded form", formDecode(body), parameters)
        try expectEqual("pair count", raw.split(separator: "&").count, parameters.count)
        try expectFalse("literal plus escaped", raw.contains("+"))
        try expectFalse("literal space escaped", raw.contains(" "))
        try expectFalse("literal hash escaped", raw.contains("#"))
        try expectFalse("literal question escaped", raw.contains("?"))
        try expectEqual("literal ampersand appears only as separator", raw.filter { $0 == "&" }.count, parameters.count - 1)
        try expectEqual("literal equals appears only as separator", raw.filter { $0 == "=" }.count, parameters.count)
    }

    static func testFormEncodingRoundTripsUnicodeKeysAndValues() throws {
        let parameters = [
            "名前": "値 & テスト + 1",
            "emoji": "😀+#%?=/ スペース",
            "quote": "\"quoted\" 'single'",
            "newline": "line1\nline2\ttab"
        ]
        let body = ChatGPTOAuth.formEncodedBody(parameters)
        try expectEqual("unicode roundtrip", formDecode(body), parameters)
    }

    static func testFormEncodingKeepsPlusAsPlus() throws {
        let body = ChatGPTOAuth.formEncodedBody(["v": "a+b"])
        let raw = String(data: body, encoding: .utf8)!
        try expectTrue("plus encoded as %2B", raw.hasSuffix("a%2Bb"))
        // The server emulator turns '+' into space, so a literal plus must survive.
        try expectEqual("decoded value", formDecode(body)?["v"], "a+b")
    }

    // MARK: - Authorization code request

    static func testTokenRequestIncludesRequiredFields() throws {
        let params = try attempt().tokenParameters(
            callback: callback("code=the-code&state=\(state)")
        )
        try expectEqual("field count", params.count, 6)
        try expectEqual("grant type", params["grant_type"], "authorization_code")
        try expectEqual("resource", params["resource"], ChatGPTOAuth.resource)
        try expectEqual("exact redirect uri", params["redirect_uri"], redirectURI)
        try expectEqual("original client id", params["client_id"], clientId)
        try expectEqual("original verifier", params["code_verifier"], verifier)
        try expectEqual("code", params["code"], "the-code")
    }

    static func testTokenRequestKeepsOriginalVerifierAndRedirect() throws {
        let custom = attempt(
            clientId: "custom-client",
            redirectURI: "http://127.0.0.1:8080/oauth/cb",
            verifier: "verifier with spaces+symbols&=%"
        )
        let url = URL(string: "http://127.0.0.1:8080/oauth/cb?code=c&state=\(state)")!
        let params = try custom.tokenParameters(callback: url)
        try expectEqual("client id retained", params["client_id"], "custom-client")
        try expectEqual("verifier retained", params["code_verifier"], "verifier with spaces+symbols&=%")
        try expectEqual("redirect retained", params["redirect_uri"], "http://127.0.0.1:8080/oauth/cb")
        try expectEqual("resource retained", params["resource"], "https://api.openai.com/v1")
    }

    // MARK: - Dynamic registration client id handling

    static func testBootstrapClientRequiresIssuedClientId() throws {
        let bootstrap = attempt(clientId: ChatGPTOAuth.registrationClientId)
        try expectThrows(
            "bootstrap without issued id",
            expected: .missingClientId
        ) { try bootstrap.tokenParameters(callback: callback("code=abc&state=\(state)")) }
    }

    static func testBootstrapRejectsEmptyIssuedClientId() throws {
        let bootstrap = attempt(clientId: ChatGPTOAuth.registrationClientId)
        try expectThrows(
            "bootstrap with empty issued id",
            expected: .missingClientId
        ) { try bootstrap.tokenParameters(callback: callback("code=abc&client_id=&state=\(state)")) }
    }

    static func testBootstrapRejectsBootstrapIdEchoedBack() throws {
        let bootstrap = attempt(clientId: ChatGPTOAuth.registrationClientId)
        try expectThrows(
            "bootstrap id echoed",
            expected: .missingClientId
        ) {
            try bootstrap.tokenParameters(
                callback: callback("code=abc&client_id=\(ChatGPTOAuth.registrationClientId)&state=\(state)")
            )
        }
    }

    static func testBootstrapUsesIssuedClientId() throws {
        let bootstrap = attempt(clientId: ChatGPTOAuth.registrationClientId)
        let params = try bootstrap.tokenParameters(
            callback: callback("code=abc&client_id=issued-xyz&state=\(state)")
        )
        try expectEqual("issued id used", params["client_id"], "issued-xyz")
        try expectFalse("bootstrap id not used", params["client_id"] == ChatGPTOAuth.registrationClientId)
    }

    static func testIssuedClientIdOmittedIsAccepted() throws {
        let params = try attempt().tokenParameters(callback: callback("code=abc&state=\(state)"))
        try expectEqual("original id retained", params["client_id"], clientId)
    }

    static func testIssuedClientIdMatchingIsAccepted() throws {
        let params = try attempt().tokenParameters(
            callback: callback("code=abc&client_id=\(clientId)&state=\(state)")
        )
        try expectEqual("matching id retained", params["client_id"], clientId)
    }

    static func testIssuedClientIdMismatchIsRejected() throws {
        try expectThrows(
            "issued id mismatch",
            expected: .clientIdMismatch
        ) { try attempt().tokenParameters(callback: callback("code=abc&client_id=other-client&state=\(state)")) }
    }

    // MARK: - State validation

    static func testCallbackStateMustMatchExactly() throws {
        for badState in ["state-124", "State-123", "state-123 ", "state", "state-1234"] {
            let url = callback("code=abc&state=\(badState.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? badState)")
            try expectThrows(
                "state \(badState)",
                expected: .invalidCallback
            ) { try attempt().tokenParameters(callback: url) }
        }
    }

    static func testDuplicateStateIsRejected() throws {
        try expectThrows(
            "duplicate state",
            expected: .invalidCallback
        ) {
            try attempt().tokenParameters(
                callback: callback("code=abc&state=\(state)&state=\(state)")
            )
        }
    }

    static func testDuplicateStateOnErrorCallbackIsRejectedBeforeDenial() throws {
        try expectThrows(
            "duplicate state with error",
            expected: .invalidCallback
        ) {
            try attempt().tokenParameters(
                callback: callback("error=access_denied&state=\(state)&state=\(state)")
            )
        }
    }

    // MARK: - Callback origin validation

    static func testWrongHostIsRejected() throws {
        try expectThrows(
            "wrong host",
            expected: .invalidCallback
        ) {
            try attempt().tokenParameters(
                callback: callback("code=abc&state=\(state)", base: "http://localhost:1455/auth/callback")
            )
        }
    }

    static func testWrongPathIsRejected() throws {
        try expectThrows(
            "wrong path",
            expected: .invalidCallback
        ) {
            try attempt().tokenParameters(
                callback: callback("code=abc&state=\(state)", base: "http://127.0.0.1:1455/auth/other")
            )
        }
    }

    static func testWrongPortIsRejected() throws {
        try expectThrows(
            "wrong port",
            expected: .invalidCallback
        ) {
            try attempt().tokenParameters(
                callback: callback("code=abc&state=\(state)", base: "http://127.0.0.1:1456/auth/callback")
            )
        }
    }

    static func testMissingPortIsRejected() throws {
        try expectThrows(
            "missing port",
            expected: .invalidCallback
        ) {
            try attempt().tokenParameters(
                callback: callback("code=abc&state=\(state)", base: "http://127.0.0.1/auth/callback")
            )
        }
    }

    // MARK: - Code and duplicate query validation

    static func testMissingCodeIsRejected() throws {
        try expectThrows(
            "missing code",
            expected: .missingCode
        ) { try attempt().tokenParameters(callback: callback("state=\(state)")) }
    }

    static func testEmptyCodeIsRejected() throws {
        try expectThrows(
            "empty code",
            expected: .missingCode
        ) { try attempt().tokenParameters(callback: callback("code=&state=\(state)")) }
    }

    static func testDuplicateCriticalQueryItemsAreRejected() throws {
        let queries = [
            "code=abc&code=abc&state=\(state)",
            "code=abc&client_id=\(clientId)&client_id=\(clientId)&state=\(state)",
            "code=abc&error=access_denied&error=access_denied&state=\(state)",
            "code=abc&error_description=one&error_description=two&state=\(state)"
        ]
        for query in queries {
            try expectThrows(
                "duplicate item in \(query)",
                expected: .invalidCallback
            ) { try attempt().tokenParameters(callback: callback(query)) }
        }
    }

    // MARK: - Denial handling

    static func testErrorCallbackNeverYieldsTokenParameters() throws {
        let secret = "SECRET-denial-description"
        let url = callback("error=access_denied&error_description=\(secret)&state=\(state)")
        try expectThrows(
            "error callback",
            expected: .authorizationDenied
        ) { try attempt().tokenParameters(callback: url) }

        // The denied callback must not leak the raw description into the surfaced error text.
        do {
            _ = try attempt().tokenParameters(callback: url)
            throw TestFailure(message: "error callback unexpectedly succeeded")
        } catch let failure as TestFailure {
            throw failure
        } catch let callbackError as ChatGPTOAuth.CallbackError {
            let description = callbackError.localizedDescription
            try expectFalse("denial description has no secret", description.contains(secret))
            try expectFalse("denial description has no raw error value", description.contains("access_denied"))
        } catch {
            throw TestFailure(message: "unexpected error type: \(error)")
        }
    }

    // MARK: - Token exchange error mapping

    static func testInvalidGrantIsActionable() throws {
        let secret = "SECRET-raw-token-body"
        let error = tokenError(
            #"{"error":"invalid_grant","error_description":"\#(secret)","body":"\#(secret)"}"#
        )
        let message = error.localizedDescription
        try expectEqual("domain", error.domain, "ChatGPTAuth")
        try expectEqual("code", error.code, 400)
        try expectContains("invalid_grant code", message, "invalid_grant")
        try expectContains("expiry hint", message, "期限切れ")
        try expectContains("retained client hint", message, "Client ID")
        try expectContains("retry hint", message, "もう一度サインイン")
        try expectFalse("no raw body leak", message.contains(secret))
        try expectFalse("no error_description leak", message.contains("SECRET-raw-token-body"))
    }

    static func testInvalidClientProvidesGuidance() throws {
        let error = tokenError(#"{"error":"invalid_client"}"#)
        let message = error.localizedDescription
        try expectContains("invalid_client code", message, "invalid_client")
        try expectContains("advanced settings guidance", message, "高度な設定")
        try expectContains("oauth client guidance", message, "OAuth Client ID")
    }

    static func testNestedErrorObjectIsSupported() throws {
        let secret = "SECRET-nested-description"
        let grant = tokenError(
            #"{"error":{"code":"invalid_grant","error_description":"\#(secret)"}}"#
        )
        try expectContains("nested invalid_grant", grant.localizedDescription, "invalid_grant")
        try expectFalse("nested invalid_grant secret leak", grant.localizedDescription.contains(secret))

        let client = tokenError(
            #"{"error":{"code":"invalid_client","message":"\#(secret)"}}"#
        )
        let message = client.localizedDescription
        try expectContains("nested invalid_client", message, "invalid_client")
        try expectContains("nested invalid_client guidance", message, "高度な設定")
        try expectFalse("nested invalid_client secret leak", message.contains(secret))
    }

    static func testUnknownErrorIsGenericAndLeakFree() throws {
        let secret = "SECRET-unknown-error"
        let error = tokenError(
            #"{"error":"server_error","error_description":"\#(secret)","echo":"\#(secret)"}"#,
            status: 503
        )
        let message = error.localizedDescription
        try expectEqual("status retained", error.code, 503)
        try expectContains("http status in message", message, "HTTP 503")
        try expectFalse("unknown code not echoed", message.contains("server_error"))
        try expectFalse("unknown secret not leaked", message.contains(secret))
        try expectFalse("userInfo secret leak", String(describing: error.userInfo).contains(secret))
    }

    static func testNonJSONBodyIsGenericAndLeakFree() throws {
        let secret = "SECRET-not-json"
        let error = tokenError("upstream failure \(secret)", status: 500)
        let message = error.localizedDescription
        try expectContains("http status", message, "HTTP 500")
        try expectFalse("non-json secret not leaked", message.contains(secret))
        try expectFalse("non-json body not leaked", message.contains("upstream failure"))
    }

    static func testMissingErrorCodeUsesStatusCode() throws {
        let error = tokenError(#"{"message":"nope"}"#, status: 429)
        try expectEqual("status retained", error.code, 429)
        try expectContains("status in message", error.localizedDescription, "HTTP 429")
    }

    // MARK: - Token response decoding

    static func testTokenResponseDecodesFullPayload() throws {
        let data = Data(
            #"{"access_token":"access-1","refresh_token":"refresh-1","id_token":"id-1","expires_in":3600,"scope":"openid chatgpt.tokens.use.direct offline_access"}"#.utf8
        )
        let response = try JSONDecoder().decode(ChatGPTOAuth.TokenResponse.self, from: data)
        try expectEqual("access token", response.access_token, "access-1")
        try expectEqual("refresh token", response.refresh_token, "refresh-1")
        try expectEqual("id token", response.id_token, "id-1")
        try expectEqual("expires in", response.expires_in, 3600)
        try expectEqual("scope", response.scope, "openid chatgpt.tokens.use.direct offline_access")
        try expectTrue("scope permits plan", ChatGPTOAuth.permitsChatGPTPlan(scope: response.scope ?? ""))
    }

    static func testTokenResponseDecodesRefreshRotationAndOptionalExpiry() throws {
        let first = try JSONDecoder().decode(
            ChatGPTOAuth.TokenResponse.self,
            from: Data(
                #"{"access_token":"access-1","refresh_token":"refresh-1","id_token":"id-1","expires_in":3600}"#.utf8
            )
        )
        let refreshed = try JSONDecoder().decode(
            ChatGPTOAuth.TokenResponse.self,
            from: Data(
                #"{"access_token":"access-2","refresh_token":"refresh-2"}"#.utf8
            )
        )
        try expectFalse("refresh token rotated", refreshed.refresh_token == first.refresh_token)
        try expectEqual("rotated refresh token", refreshed.refresh_token, "refresh-2")
        try expectEqual("rotated access token", refreshed.access_token, "access-2")
        try expectEqual("optional expires_in absent", refreshed.expires_in, nil)
        try expectEqual("optional id_token absent", refreshed.id_token, nil)
        try expectEqual("optional scope absent", refreshed.scope, nil)
    }

    // MARK: - Plan scope matching

    static func testPermitsChatGPTPlanRequiresExactWhitespaceToken() throws {
        try expectTrue("single token", ChatGPTOAuth.permitsChatGPTPlan(scope: "chatgpt.tokens.use.direct"))
        try expectTrue("space separated", ChatGPTOAuth.permitsChatGPTPlan(scope: "openid chatgpt.tokens.use.direct profile"))
        try expectTrue("tab and newline separated", ChatGPTOAuth.permitsChatGPTPlan(scope: "openid\tchatgpt.tokens.use.direct\nprofile"))
        try expectTrue("repeated whitespace", ChatGPTOAuth.permitsChatGPTPlan(scope: "  chatgpt.tokens.use.direct  "))
        try expectFalse("substring suffix", ChatGPTOAuth.permitsChatGPTPlan(scope: "xchatgpt.tokens.use.direct"))
        try expectFalse("substring prefix", ChatGPTOAuth.permitsChatGPTPlan(scope: "chatgpt.tokens.use.directx"))
        try expectFalse("comma is not a delimiter", ChatGPTOAuth.permitsChatGPTPlan(scope: "openid,chatgpt.tokens.use.direct"))
        try expectFalse("case sensitive", ChatGPTOAuth.permitsChatGPTPlan(scope: "CHATGPT.TOKENS.USE.DIRECT"))
        try expectFalse("missing", ChatGPTOAuth.permitsChatGPTPlan(scope: "openid profile"))
        try expectFalse("empty", ChatGPTOAuth.permitsChatGPTPlan(scope: ""))
    }

    // MARK: - Refresh error classification

    static func testTerminalRefreshErrorsAreRecognizedSafely() throws {
        let topLevelCodes = [
            "invalid_grant",
            "invalid_refresh_token",
            "token_expired",
            "refresh_token_expired",
            "refresh_token_invalidated",
            "refresh_token_reused"
        ]
        for code in topLevelCodes {
            let data = Data(#"{"error":"\#(code)","error_description":"SECRET-should-not-matter"}"#.utf8)
            try expectTrue("terminal top-level \(code)", ChatGPTOAuth.isTerminalRefreshError(data: data))
        }

        let nested = Data(#"{"error":{"code":"refresh_token_reused","message":"SECRET-should-not-matter"}}"#.utf8)
        try expectTrue("terminal nested code", ChatGPTOAuth.isTerminalRefreshError(data: nested))

        try expectFalse("invalid_client not terminal", ChatGPTOAuth.isTerminalRefreshError(data: Data(#"{"error":"invalid_client"}"#.utf8)))
        try expectFalse("5xx body not terminal", ChatGPTOAuth.isTerminalRefreshError(data: Data(#"{"error":"server_error"}"#.utf8)))
        try expectFalse("malformed not terminal", ChatGPTOAuth.isTerminalRefreshError(data: Data("not json SECRET".utf8)))
        try expectFalse("empty not terminal", ChatGPTOAuth.isTerminalRefreshError(data: Data()))
        try expectFalse("unknown not terminal", ChatGPTOAuth.isTerminalRefreshError(data: Data(#"{"error":"invalid_request"}"#.utf8)))
        try expectFalse(
            "nested message is not a code",
            ChatGPTOAuth.isTerminalRefreshError(
                data: Data(#"{"error":{"message":"refresh_token_expired"}}"#.utf8)
            )
        )
    }

    static func testRefreshErrorTerminalIsSafeAndActionable() throws {
        let secret = "SECRET-terminal-refresh-body"
        let error = ChatGPTOAuth.refreshError(
            data: Data(#"{"error":"refresh_token_expired","error_description":"\#(secret)","body":"\#(secret)"}"#.utf8),
            statusCode: 400
        )
        let message = error.localizedDescription
        try expectEqual("domain", error.domain, "ChatGPTAuth")
        try expectEqual("status retained", error.code, 400)
        try expectContains("session expiry", message, "セッション")
        try expectContains("re-signin guidance", message, "サインイン")
        try expectFalse("terminal body not leaked", message.contains(secret))
        try expectFalse("terminal userInfo leak", String(describing: error.userInfo).contains(secret))
    }

    static func testRefreshErrorClientAndTransientAreSafeAndActionable() throws {
        let secret = "SECRET-transient-refresh-body"
        let client = ChatGPTOAuth.refreshError(
            data: Data(#"{"error":"invalid_client","error_description":"\#(secret)"}"#.utf8),
            statusCode: 401
        )
        try expectContains("client id guidance", client.localizedDescription, "Client ID")
        try expectContains("advanced settings guidance", client.localizedDescription, "高度な設定")
        try expectFalse("invalid_client body not leaked", client.localizedDescription.contains(secret))

        for status in [429, 500, 503] {
            let error = ChatGPTOAuth.refreshError(
                data: Data(#"{"error":"server_error","error_description":"\#(secret)","body":"\#(secret)"}"#.utf8),
                statusCode: status
            )
            let message = error.localizedDescription
            try expectEqual("status retained \(status)", error.code, status)
            try expectContains("http status \(status)", message, "HTTP \(status)")
            try expectContains("retry guidance \(status)", message, "再試行")
            try expectContains("credentials retained \(status)", message, "保持")
            try expectFalse("transient body not leaked \(status)", message.contains(secret))
            try expectFalse("transient userInfo leak \(status)", String(describing: error.userInfo).contains(secret))
        }

        let other = ChatGPTOAuth.refreshError(
            data: Data(#"{"error":"invalid_request","error_description":"\#(secret)"}"#.utf8),
            statusCode: 400
        )
        try expectContains("other auth failure guidance", other.localizedDescription, "サインイン")
        try expectFalse("other body not leaked", other.localizedDescription.contains(secret))
    }

    // MARK: - Utilities

    static func unwrap<T>(_ value: T?, _ label: String) throws -> T {
        guard let value else { throw TestFailure(message: "\(label): expected a value, got nil") }
        return value
    }

    // MARK: - Runner

    static func main() {
        let tests: [(name: String, body: () throws -> Void)] = [
            ("formEncodingSortsKeysAndEncodesSpaces", testFormEncodingSortsKeysAndEncodesSpaces),
            ("formEncodingRoundTripsReservedCharacters", testFormEncodingRoundTripsReservedCharacters),
            ("formEncodingRoundTripsUnicodeKeysAndValues", testFormEncodingRoundTripsUnicodeKeysAndValues),
            ("formEncodingKeepsPlusAsPlus", testFormEncodingKeepsPlusAsPlus),
            ("tokenRequestIncludesRequiredFields", testTokenRequestIncludesRequiredFields),
            ("tokenRequestKeepsOriginalVerifierAndRedirect", testTokenRequestKeepsOriginalVerifierAndRedirect),
            ("bootstrapClientRequiresIssuedClientId", testBootstrapClientRequiresIssuedClientId),
            ("bootstrapRejectsEmptyIssuedClientId", testBootstrapRejectsEmptyIssuedClientId),
            ("bootstrapRejectsBootstrapIdEchoedBack", testBootstrapRejectsBootstrapIdEchoedBack),
            ("bootstrapUsesIssuedClientId", testBootstrapUsesIssuedClientId),
            ("issuedClientIdOmittedIsAccepted", testIssuedClientIdOmittedIsAccepted),
            ("issuedClientIdMatchingIsAccepted", testIssuedClientIdMatchingIsAccepted),
            ("issuedClientIdMismatchIsRejected", testIssuedClientIdMismatchIsRejected),
            ("callbackStateMustMatchExactly", testCallbackStateMustMatchExactly),
            ("duplicateStateIsRejected", testDuplicateStateIsRejected),
            ("duplicateStateOnErrorCallbackIsRejectedBeforeDenial", testDuplicateStateOnErrorCallbackIsRejectedBeforeDenial),
            ("wrongHostIsRejected", testWrongHostIsRejected),
            ("wrongPathIsRejected", testWrongPathIsRejected),
            ("wrongPortIsRejected", testWrongPortIsRejected),
            ("missingPortIsRejected", testMissingPortIsRejected),
            ("missingCodeIsRejected", testMissingCodeIsRejected),
            ("emptyCodeIsRejected", testEmptyCodeIsRejected),
            ("duplicateCriticalQueryItemsAreRejected", testDuplicateCriticalQueryItemsAreRejected),
            ("errorCallbackNeverYieldsTokenParameters", testErrorCallbackNeverYieldsTokenParameters),
            ("invalidGrantIsActionable", testInvalidGrantIsActionable),
            ("invalidClientProvidesGuidance", testInvalidClientProvidesGuidance),
            ("nestedErrorObjectIsSupported", testNestedErrorObjectIsSupported),
            ("unknownErrorIsGenericAndLeakFree", testUnknownErrorIsGenericAndLeakFree),
            ("nonJSONBodyIsGenericAndLeakFree", testNonJSONBodyIsGenericAndLeakFree),
            ("missingErrorCodeUsesStatusCode", testMissingErrorCodeUsesStatusCode),
            ("tokenResponseDecodesFullPayload", testTokenResponseDecodesFullPayload),
            ("tokenResponseDecodesRefreshRotationAndOptionalExpiry", testTokenResponseDecodesRefreshRotationAndOptionalExpiry),
            ("permitsChatGPTPlanRequiresExactWhitespaceToken", testPermitsChatGPTPlanRequiresExactWhitespaceToken),
            ("terminalRefreshErrorsAreRecognizedSafely", testTerminalRefreshErrorsAreRecognizedSafely),
            ("refreshErrorTerminalIsSafeAndActionable", testRefreshErrorTerminalIsSafeAndActionable),
            ("refreshErrorClientAndTransientAreSafeAndActionable", testRefreshErrorClientAndTransientAreSafeAndActionable)
        ]

        var failures: [String] = []
        for test in tests {
            do {
                try test.body()
                print("PASS \(test.name)")
            } catch {
                let message = (error as? TestFailure)?.message ?? "unexpected error: \(error)"
                failures.append("\(test.name): \(message)")
                print("FAIL \(test.name): \(message)")
            }
        }

        print("")
        if failures.isEmpty {
            print("\(tests.count) tests passed")
            exit(0)
        }
        print("\(tests.count - failures.count) passed, \(failures.count) failed")
        for failure in failures {
            print("  - \(failure)")
        }
        exit(1)
    }
}
