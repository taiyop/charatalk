import Foundation

/// Reasoning effort accepted by the Responses API for reasoning models.
///
/// `.automatic` means "do not send a `reasoning` object at all"; the remaining
/// cases are sent verbatim. Not every model supports every level.
public enum ChatGPTReasoningEffort: String, CaseIterable, Identifiable, Sendable {
    case automatic = ""
    case none = "none"
    case minimal = "minimal"
    case low = "low"
    case medium = "medium"
    case high = "high"
    case xhigh = "xhigh"
    case max = "max"

    /// Stable identifier for pickers. `.automatic` cannot use its empty raw
    /// value as an identity, so it gets a readable sentinel.
    public var id: String {
        rawValue.isEmpty ? "automatic" : rawValue
    }

    /// Japanese label that still makes the underlying API value recognizable.
    public var displayName: String {
        switch self {
        case .automatic:
            return "自動（モデルに任せる）"
        case .none:
            return "none（なし）"
        case .minimal:
            return "minimal（最小）"
        case .low:
            return "low（低）"
        case .medium:
            return "medium（中）"
        case .high:
            return "high（高）"
        case .xhigh:
            return "xhigh（最高）"
        case .max:
            return "max（最大）"
        }
    }
}

/// A failure from the ChatGPT plan inference transport.
///
/// Metadata copied from an HTTP response or a streamed error event is kept only
/// when it looks like a short ASCII identifier. Raw response bodies, `message`
/// and `detail` strings are never retained, so they cannot leak into the UI or
/// logs.
public struct ChatGPTInferenceError: Error, LocalizedError, Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        /// The request never produced a usable HTTP response, or the stream was
        /// cut off by a transport failure.
        case transport
        /// A non-2xx HTTP status rejected the request before streaming started.
        case http
        /// A terminal stream event reported failure or the stream ended without
        /// `response.completed`.
        case stream
        /// A response envelope could not be decoded.
        case invalidResponse
    }

    public let kind: Kind
    /// Original HTTP status, when the failure came from an HTTP response.
    public let statusCode: Int?
    /// Sanitized `x-request-id` / body request ID.
    public let requestID: String?
    /// Sanitized machine-readable `error.code`.
    public let code: String?
    /// Sanitized `error.param`.
    public let param: String?

    public init(
        kind: Kind,
        statusCode: Int? = nil,
        requestID: String? = nil,
        code: String? = nil,
        param: String? = nil
    ) {
        self.kind = kind
        self.statusCode = statusCode
        self.requestID = ChatGPTInferenceError.sanitize(requestID, maxLength: 128)
        self.code = ChatGPTInferenceError.sanitize(code, maxLength: 128)
        self.param = ChatGPTInferenceError.sanitize(param, maxLength: 128)
    }

    public var errorDescription: String? {
        let message: String
        switch kind {
        case .transport:
            message = "ChatGPT に接続できませんでした。ネットワーク接続を確認して、もう一度お試しください。"
        case .invalidResponse:
            message = "ChatGPT の応答を読み取れませんでした。時間をおいてもう一度お試しください。"
        case .stream:
            message = streamMessage
        case .http:
            message = httpMessage
        }
        var details: [String] = []
        if let statusCode { details.append("HTTP \(statusCode)") }
        if let code { details.append("code: \(code)") }
        if let param { details.append("param: \(param)") }
        if let requestID { details.append("request ID: \(requestID)") }
        return details.isEmpty ? message : message + "\n" + details.joined(separator: " / ")
    }

    /// Parses a non-2xx response body. Only `error.code`, `error.param` and a
    /// request ID are copied; standard `{ "error": ... }`, nonstandard
    /// `{ "detail": ... }` and non-JSON bodies all stay private.
    public static func httpError(
        data: Data,
        statusCode: Int,
        requestID: String? = nil
    ) -> ChatGPTInferenceError {
        var bodyCode: String?
        var bodyParam: String?
        var bodyRequestID: String?

        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let error = object["error"] as? [String: Any]
            bodyCode = (error?["code"] as? String) ?? (object["code"] as? String)
            bodyParam = (error?["param"] as? String) ?? (object["param"] as? String)
            bodyRequestID = (object["request_id"] as? String)
                ?? (object["requestId"] as? String)
                ?? (error?["request_id"] as? String)
        }

        return ChatGPTInferenceError(
            kind: .http,
            statusCode: statusCode,
            requestID: requestID ?? bodyRequestID,
            code: bodyCode,
            param: bodyParam
        )
    }

    // MARK: - Messages

    private static let usageSettingsURL = "https://chatgpt.com/settings/usage"

    private static let effortMessage =
        "このモデルは選択中の推論強度に対応していません。推論強度を「自動」に戻すか、別の強度に変更してください。"

    private var paramLooksLikeEffort: Bool {
        guard let param = param?.lowercased() else { return false }
        return param.contains("effort") || param.contains("reasoning")
    }

    private var isEffortProblem: Bool {
        statusCode == 400 && paramLooksLikeEffort
    }

    private var streamMessage: String {
        if let code {
            switch code {
            case "subscription_sharing_usage_limit_exceeded":
                return "ChatGPT プランの利用上限に達しました。ChatGPT の設定 → 使用状況（\(Self.usageSettingsURL)）を確認してください。"
            case "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable":
                return "ChatGPT プランの利用状況を確認できませんでした。認証情報は保持したまま、時間をおいて再試行してください。"
            case "subscription_sharing_user_not_eligible", "subscription_sharing_route_not_supported",
                 "chatpass_v2_scope_not_authorized", "chatpass_v2_invalid_authorization_context":
                return "このアカウントでは ChatGPT プランでの推論が許可されていません。アカウントと権限を確認してください。"
            case "subscription_sharing_unsupported_capability":
                return paramLooksLikeEffort
                    ? Self.effortMessage
                    : "このリクエストには ChatGPT プランで未対応の指定が含まれています。モデルやパラメータを変更してください。"
            case "subscription_sharing_invalid_user":
                return "サインインしているユーザーを確認できませんでした。設定画面からサインインし直してください。"
            case "max_output_tokens", "max_tokens":
                return "応答が長すぎて途中で終了しました。もう一度お試しください。"
            case "stream_interrupted", "stream_error", "response_failed", "response_incomplete":
                return "ChatGPT の応答が途中で終了しました。もう一度お試しください。"
            default:
                break
            }
        }
        return "ChatGPT の応答を完了できませんでした。もう一度お試しください。"
    }

    private var httpMessage: String {
        if isEffortProblem {
            return Self.effortMessage
        }

        if let code {
            switch code {
            case "subscription_sharing_usage_limit_exceeded":
                return "ChatGPT プランの利用上限に達しました。ChatGPT の設定 → 使用状況（\(Self.usageSettingsURL)）を確認してください。"
            case "subscription_sharing_user_not_eligible":
                return "このユーザー、ワークスペース、またはポリシーでは ChatGPT プランでの利用ができません。アカウントの権限を確認してください。"
            case "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable":
                return "ChatGPT プランの利用状況を一時的に確認できませんでした。認証情報は保持したまま、時間をおいて再試行してください。"
            case "subscription_sharing_unsupported_capability":
                return "このリクエストには ChatGPT プランで未対応の指定が含まれています。モデルやパラメータを変更してください。"
            case "subscription_sharing_route_not_supported":
                return "このエンドポイントまたは HTTP メソッドは ChatGPT プランでは利用できません。POST /v1/responses を使用してください。"
            case "subscription_sharing_invalid_user":
                return "サインインしているユーザーを確認できませんでした。設定画面からサインインし直してください。"
            case "chatpass_v2_scope_not_authorized", "chatpass_v2_invalid_authorization_context":
                return "このサインインには ChatGPT プランでの推論に必要な権限がありません。設定からサインインし直してください。"
            default:
                break
            }
        }

        if let statusCode {
            switch statusCode {
            case 401:
                return "設定の「利用権限を再認証」から ChatGPT にサインインし直し、プラン利用を許可してください（chatgpt.tokens.use.direct）。"
            case 403:
                return "このアカウントまたは地域では ChatGPT プランでの推論が許可されていません。設定とアカウントの権限を確認してください。"
            case 429:
                return "ChatGPT プランの利用上限に達しました。ChatGPT の設定 → 使用状況（\(Self.usageSettingsURL)）を確認してください。"
            case 400:
                return "リクエストが受け付けられませんでした。モデルと設定を確認してください。"
            case 500...599:
                return "ChatGPT のサーバーで一時的なエラーが発生しました。時間をおいてもう一度お試しください。"
            default:
                return "ChatGPT の推論に失敗しました。時間をおいてもう一度お試しください。"
            }
        }

        return "ChatGPT の推論に失敗しました。時間をおいてもう一度お試しください。"
    }

    // MARK: - Sanitization

    /// Keeps a value only when the whole value is a short ASCII identifier.
    /// Partial filtering is deliberately not used: a malformed value is dropped
    /// entirely rather than risking a fragment of a response body leaking.
    private static func sanitize(_ value: String?, maxLength: Int) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxLength else { return nil }
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-.:"
        )
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return trimmed
    }
}

/// Streaming ChatGPT plan inference over `POST https://api.openai.com/v1/responses`.
///
/// The transport intentionally has no Chat Completions fallback and no model or
/// auth storage of its own. A success is reported only after a
/// `response.completed` event (status must be completed when present); a stream that merely
/// ends, reports `[DONE]`, fails, or is incomplete never returns partial text.
public enum ChatGPTInference {
    private static let responsesEndpoint = URL(string: "https://api.openai.com/v1/responses")!
    private static let errorBodyLimit = 64 * 1024

    public static func send(
        accessToken: String,
        model: String,
        systemPrompt: String,
        messages: [[String: String]],
        effort: ChatGPTReasoningEffort = .automatic,
        session: URLSession = .shared,
        refreshAccessToken: (@Sendable (String) async throws -> String)? = nil
    ) async throws -> String {
        let body = try requestBody(
            model: model,
            systemPrompt: systemPrompt,
            messages: messages,
            effort: effort
        )

        var token = accessToken
        var didRefresh = false

        while true {
            try Task.checkCancellation()
            var request = URLRequest(url: responsesEndpoint)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let bytes: URLSession.AsyncBytes
            let response: URLResponse
            do {
                (bytes, response) = try await session.bytes(for: request)
            } catch {
                throw ChatGPTInferenceError(kind: .transport)
            }

            guard let http = response as? HTTPURLResponse else {
                throw ChatGPTInferenceError(kind: .invalidResponse)
            }

            guard (200...299).contains(http.statusCode) else {
                let data = await readErrorBody(bytes)

                // Only a 401 that arrives before the SSE stream starts may use
                // the refresh hook, and only once. Every other failure is final.
                if http.statusCode == 401, !didRefresh, let refreshAccessToken {
                    didRefresh = true
                    token = try await refreshAccessToken(token)
                    guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw ChatGPTInferenceError(kind: .invalidResponse)
                    }
                    continue
                }

                throw ChatGPTInferenceError.httpError(
                    data: data,
                    statusCode: http.statusCode,
                    requestID: http.value(forHTTPHeaderField: "x-request-id")
                )
            }

            do {
                return try await consumeStream(bytes)
            } catch let error as ChatGPTInferenceError {
                throw ChatGPTInferenceError(
                    kind: error.kind, statusCode: error.statusCode,
                    requestID: error.requestID ?? http.value(forHTTPHeaderField: "x-request-id"),
                    code: error.code, param: error.param
                )
            }
        }
    }

    // MARK: - Request

    private static func requestBody(
        model: String,
        systemPrompt: String,
        messages: [[String: String]],
        effort: ChatGPTReasoningEffort
    ) throws -> Data {
        let selectedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selectedModel.isEmpty else { throw ChatGPTInferenceError(kind: .invalidResponse) }
        var payload: [String: Any] = [
            "model": selectedModel,
            "input": messages.map { message in
                // This route accepts instructions/developer messages, not system items.
                var item = message
                if item["role"] == "system" { item["role"] = "developer" }
                return item
            },
            "store": false,
            "stream": true
        ]

        let instructions = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !instructions.isEmpty {
            payload["instructions"] = instructions
        }

        // `temperature` is not sent at all: reasoning models reject it.
        if !effort.rawValue.isEmpty {
            payload["reasoning"] = ["effort": effort.rawValue]
        }

        do {
            return try JSONSerialization.data(withJSONObject: payload)
        } catch {
            throw ChatGPTInferenceError(kind: .invalidResponse)
        }
    }

    private static func readErrorBody(_ bytes: URLSession.AsyncBytes) async -> Data {
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= errorBodyLimit { break }
            }
        } catch {
            // The status code alone is enough to build the error; a truncated or
            // broken error body must not mask it.
        }
        return data
    }

    // MARK: - SSE

    private static func consumeStream(_ bytes: URLSession.AsyncBytes) async throws -> String {
        var parser = SSEParser()
        var accumulatedText = ""
        var lineBytes: [UInt8] = []
        var previousWasCR = false

        do {
            // Preserve empty lines: AsyncBytes.lines can discard SSE event
            // boundaries. Decode UTF-8 only once a complete line has arrived.
            for try await byte in bytes {
                if byte == 10 && previousWasCR {
                    previousWasCR = false
                    continue
                }
                previousWasCR = byte == 13
                if byte == 10 || byte == 13 {
                    let line = String(decoding: lineBytes, as: UTF8.self)
                    lineBytes.removeAll(keepingCapacity: true)
                    if let message = parser.consume(line: line),
                       let text = try handle(message, accumulatedText: &accumulatedText) {
                        return text
                    }
                } else {
                    lineBytes.append(byte)
                }
            }

            if !lineBytes.isEmpty,
               let message = parser.consume(line: String(decoding: lineBytes, as: UTF8.self)),
               let text = try handle(message, accumulatedText: &accumulatedText) {
                return text
            }

            // A final event is valid SSE even without the trailing blank line.
            if let message = parser.finish(),
               let text = try handle(message, accumulatedText: &accumulatedText) {
                return text
            }
        } catch let error as ChatGPTInferenceError {
            throw error
        } catch {
            throw ChatGPTInferenceError(kind: .transport)
        }

        throw ChatGPTInferenceError(kind: .stream, code: "stream_interrupted")
    }

    /// Handles one dispatched SSE event. Returns final text only for a valid
    /// `response.completed`; all other terminal conditions throw.
    private static func handle(
        _ message: SSEMessage,
        accumulatedText: inout String
    ) throws -> String? {
        let data = message.data.trimmingCharacters(in: .whitespacesAndNewlines)

        if data == "[DONE]" {
            // A bare [DONE] is not success: response.completed is required.
            throw ChatGPTInferenceError(kind: .stream, code: "stream_interrupted")
        }

        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any] else {
            if let event = message.event, terminalEvents.contains(event) {
                throw ChatGPTInferenceError(kind: .invalidResponse)
            }
            return nil
        }

        let type = (object["type"] as? String) ?? message.event ?? ""
        switch type {
        case "response.output_text.delta":
            if let delta = object["delta"] as? String {
                accumulatedText += delta
            }
            return nil

        case "response.completed":
            let response = object["response"] as? [String: Any]
            if let status = (response?["status"] as? String) ?? (object["status"] as? String),
               status != "completed" {
                throw ChatGPTInferenceError(
                    kind: .stream,
                    requestID: object["request_id"] as? String,
                    code: status
                )
            }

            let terminalText = outputText(from: response)
            let text = (terminalText.isEmpty ? accumulatedText : terminalText)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw ChatGPTInferenceError(kind: .invalidResponse)
            }
            return text

        case "response.failed":
            throw streamError(from: object, fallbackCode: "response_failed")

        case "response.incomplete":
            throw streamError(from: object, fallbackCode: "response_incomplete")

        case "error":
            throw streamError(from: object, fallbackCode: "stream_error")

        default:
            // Comments and unknown events (including reasoning deltas) are
            // ignored so reasoning text can never reach the user's reply.
            return nil
        }
    }

    private static let terminalEvents: Set<String> = [
        "response.completed",
        "response.failed",
        "response.incomplete",
        "error"
    ]

    private static func outputText(from response: [String: Any]?) -> String {
        guard let response else { return "" }

        if let text = response["output_text"] as? String, !text.isEmpty {
            return text
        }

        guard let output = response["output"] as? [[String: Any]] else { return "" }
        var parts: [String] = []
        for item in output {
            if let type = item["type"] as? String, type != "message" { continue }
            guard let content = item["content"] as? [[String: Any]] else { continue }
            for part in content {
                guard (part["type"] as? String) == "output_text",
                      let text = part["text"] as? String else { continue }
                parts.append(text)
            }
        }
        return parts.joined()
    }

    private static func streamError(
        from object: [String: Any],
        fallbackCode: String
    ) -> ChatGPTInferenceError {
        let response = object["response"] as? [String: Any]
        let error = (response?["error"] as? [String: Any]) ?? (object["error"] as? [String: Any])

        var code = (error?["code"] as? String) ?? (object["code"] as? String)
        if code == nil, fallbackCode == "response_incomplete",
           let details = response?["incomplete_details"] as? [String: Any],
           let reason = details["reason"] as? String {
            code = reason
        }

        return ChatGPTInferenceError(
            kind: .stream,
            requestID: (error?["request_id"] as? String) ?? (object["request_id"] as? String),
            code: code ?? fallbackCode,
            param: (error?["param"] as? String) ?? (object["param"] as? String)
        )
    }
}

/// Incremental `text/event-stream` decoder.
///
/// Handles `event:`/`data:` fields, multi-line data, blank-line dispatch, CRLF
/// and LF, comments, unknown fields, and a final event with no trailing blank
/// line.
///
private struct SSEParser {
    private var eventName: String?
    private var dataLines: [String] = []

    mutating func consume(line rawLine: String) -> SSEMessage? {
        var line = rawLine
        if line.hasSuffix("\r") {
            line.removeLast()
        }

        if line.isEmpty {
            return takePending()
        }

        if line.hasPrefix(":") {
            return nil
        }

        let field: String
        let value: String
        if let separator = line.firstIndex(of: ":") {
            field = String(line[line.startIndex..<separator])
            var remainder = String(line[line.index(after: separator)...])
            if remainder.hasPrefix(" ") {
                remainder.removeFirst()
            }
            value = remainder
        } else {
            field = line
            value = ""
        }

        switch field {
        case "event":
            eventName = value
            return nil
        case "data":
            dataLines.append(value)
            return nil
        default:
            // `id`, `retry`, comments, and unknown fields are ignored.
            return nil
        }
    }

    /// Dispatches a trailing event at end of stream.
    mutating func finish() -> SSEMessage? {
        takePending()
    }

    private mutating func takePending() -> SSEMessage? {
        guard !dataLines.isEmpty else {
            eventName = nil
            return nil
        }
        let message = SSEMessage(event: eventName, data: dataLines.joined(separator: "\n"))
        eventName = nil
        dataLines.removeAll(keepingCapacity: true)
        return message
    }
}

private struct SSEMessage {
    let event: String?
    let data: String
}
