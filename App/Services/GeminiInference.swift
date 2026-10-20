import Foundation

// Native Gemini API transport for CharaTalk.
//
// This file is deliberately self-contained (Foundation only) so it can be
// compiled and exercised by the standalone harness in
// `Tests/GeminiInferenceTests.swift` without the app or a test target.
//
// Design notes:
// - The API key is only ever placed in the `x-goog-api-key` header. It is never
//   put in a URL or query string, never logged, and never copied into an error.
// - `generateContent` is non-streaming. A success requires `finishReason` to be
//   exactly `STOP` and at least one non-thought text part.
// - Error messages are Japanese and actionable. Raw response bodies, server
//   messages, and `blockReasonMessage`/`finishMessage` are never surfaced.

/// Thinking effort exposed by the Gemini model picker.
///
/// `.automatic` means "omit `thinkingConfig` and let the model decide". The
/// remaining cases are only sent when the selected model supports them; see
/// ``supported(for:)``.
public enum GeminiThinkingEffort: String, CaseIterable, Identifiable, Sendable {
    case automatic = ""
    case minimal = "minimal"
    case low = "low"
    case medium = "medium"
    case high = "high"

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
        case .minimal:
            return "minimal（最小）"
        case .low:
            return "low（低）"
        case .medium:
            return "medium（中）"
        case .high:
            return "high（高）"
        }
    }

    /// Efforts the selected model is known to accept.
    ///
    /// Model families differ:
    /// - Gemini 2.5 uses `thinkingBudget` and accepts low/medium/high.
    /// - Gemini 3 and newer use `thinkingLevel`. `gemini-3-pro-preview` has no
    ///   medium level, `gemini-3.1-pro` has no minimal level, and
    ///   `gemini-3-flash-preview`/`3.6-flash`/`3.5-flash-lite` add minimal.
    /// - Gemini 2.0 and older only support automatic.
    /// - Unknown names opt into the common automatic/low/medium/high set; if the
    ///   server rejects one of those, the surfaced error asks the user to pick
    ///   another level.
    public static func supported(for model: String) -> [Self] {
        let slug = GeminiInference.normalizedModelName(model)

        guard let version = GeminiInference.modelVersion(slug) else {
            return [.automatic, .low, .medium, .high]
        }

        if version.major == 2 {
            if version.minor >= 5 {
                return [.automatic, .low, .medium, .high]
            }
            return [.automatic]
        }

        if version.major < 2 {
            return [.automatic]
        }

        // Gemini 3 and newer (`3.8-flash`, `4-argon`, and future families).
        if slug.contains("gemini-3-pro-preview") {
            return [.automatic, .low, .high]
        }
        if slug.contains("gemini-3.1-pro") {
            return [.automatic, .low, .medium, .high]
        }
        if slug.contains("gemini-3-flash-preview")
            || slug.contains("gemini-3.6-flash")
            || slug.contains("gemini-3.5-flash-lite") {
            return [.automatic, .minimal, .low, .medium, .high]
        }
        return [.automatic, .low, .medium, .high]
    }
}

/// A Gemini model returned by the `models.list` endpoint.
///
/// `id` is the slug sent as the model path component (the optional `models/`
/// prefix is removed); `displayName` is the server-provided label.
public struct GeminiModel: Identifiable, Sendable, Equatable {
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

/// A failure from the Gemini transport.
///
/// Only sanitized metadata (`statusCode`, an ASCII `code`) is retained. Raw
/// response bodies and server messages are never stored, so they cannot reach
/// the UI or logs.
public struct GeminiInferenceError: Error, LocalizedError, Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        /// Local validation failed before any request was made.
        case invalidRequest
        /// The request never produced a usable HTTP response.
        case transport
        /// A non-2xx HTTP status rejected the request.
        case http
        /// Gemini blocked the prompt or the candidate (`finishReason`).
        case blocked
        /// Generation stopped before producing a complete answer.
        case incomplete
        /// A response envelope could not be decoded or contained no text.
        case invalidResponse
    }

    public let kind: Kind
    /// Original HTTP status, when the failure came from an HTTP response.
    public let statusCode: Int?
    /// Sanitized machine-readable status/reason (for example `API_KEY_INVALID`).
    public let code: String?

    /// Locally generated, sanitized Japanese explanation.
    private let message: String

    init(kind: Kind, statusCode: Int = 0, code: String? = nil, message: String) {
        self.kind = kind
        self.statusCode = statusCode == 0 ? nil : statusCode
        self.code = GeminiInferenceError.sanitizeCode(code)
        self.message = message
    }

    public var errorDescription: String? {
        var details: [String] = []
        if let statusCode { details.append("HTTP \(statusCode)") }
        if let code { details.append("code: \(code)") }
        return details.isEmpty ? message : message + "\n" + details.joined(separator: " / ")
    }

    /// Parses a non-2xx response body. Only a sanitized `error.status` or
    /// `error.details[].reason` is copied; message bodies stay private.
    public static func httpError(data: Data, statusCode: Int) -> GeminiInferenceError {
        GeminiInference.httpError(data: data, statusCode: statusCode)
    }

    /// Keeps a value only when the whole value is a short ASCII identifier.
    /// Partial filtering is deliberately not used: malformed values are dropped
    /// entirely rather than risking a fragment of a response body leaking.
    static func sanitizeCode(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 64 else { return nil }
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"
        )
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return trimmed
    }
}

/// Native Gemini `generateContent` transport and model catalog fetch.
public enum GeminiInference {
    public static let defaultModel = "gemini-3.8-flash"

    private static let baseURL = "https://generativelanguage.googleapis.com/v1beta"
    private static let modelsEndpoint = "\(baseURL)/models"
    private static let maxPages = 100
    private static let pageSize = 1000
    private static let maxSlugLength = 200
    private static let maxKeyLength = 1024

    // MARK: - Sending

    /// Sends a non-streaming `generateContent` request and returns the first
    /// candidate's visible text.
    ///
    /// System-role history items are merged into `systemInstruction`; assistant
    /// items become `model` messages. Gemini 3+ models omit `temperature` (the
    /// documented default is 1) and use `thinkingLevel`; Gemini 2.5 uses
    /// `thinkingBudget`.
    public static func send(
        apiKey: String,
        model: String,
        systemPrompt: String,
        messages: [[String: String]],
        temperature: Double,
        effort: GeminiThinkingEffort,
        session: URLSession = .shared
    ) async throws -> String {
        let key = try validatedKey(apiKey)
        let slug = try validatedModelSlug(model)
        let body = try requestBody(
            model: slug,
            systemPrompt: systemPrompt,
            messages: messages,
            temperature: temperature,
            effort: effort
        )

        try Task.checkCancellation()

        guard let url = URL(string: "\(modelsEndpoint)/\(slug):generateContent") else {
            throw GeminiInferenceError(
                kind: .invalidRequest,
                message: "モデル名が正しくありません。設定画面でモデルを選び直してください。"
            )
        }

        var request = URLRequest(url: url)
        // Higher thinking levels can take longer than URLSession's 60s default.
        request.timeoutInterval = 180
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // The key is only ever sent as a header, never as a query parameter.
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw GeminiInferenceError(
                kind: .transport,
                message: "Gemini に接続できませんでした。ネットワーク接続を確認して、もう一度お試しください。"
            )
        }

        try Task.checkCancellation()

        guard let http = response as? HTTPURLResponse else {
            throw invalidResponseError()
        }

        guard (200...299).contains(http.statusCode) else {
            throw httpError(data: data, statusCode: http.statusCode)
        }

        return try decodeResponse(data)
    }

    // MARK: - Model catalog

    /// Fetches every Gemini text generation model visible to the API key.
    ///
    /// Follows `nextPageToken` (stopping on a repeated token), keeps only models
    /// whose `supportedGenerationMethods` contains `generateContent`, and skips
    /// obvious image/audio/TTS/live/robotics/embedding variants. Server order is
    /// preserved and duplicate slugs are removed.
    public static func fetchModels(
        apiKey: String,
        session: URLSession = .shared
    ) async throws -> [GeminiModel] {
        let key = try validatedKey(apiKey)

        var models: [GeminiModel] = []
        var seenSlugs = Set<String>()
        var seenTokens = Set<String>()
        var pageToken: String?
        var pageCount = 0

        while true {
            try Task.checkCancellation()

            if let token = pageToken {
                // Defensive: never loop forever on a token cycle (A → B → A).
                guard seenTokens.insert(token).inserted else { break }
            }

            pageCount += 1
            guard pageCount <= maxPages else { break }

            var components = URLComponents(string: modelsEndpoint)!
            var query = [URLQueryItem(name: "pageSize", value: String(pageSize))]
            if let pageToken {
                query.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            components.queryItems = query
            guard let url = components.url else { throw invalidResponseError() }

            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                throw GeminiInferenceError(
                    kind: .transport,
                    message: "Gemini のモデル一覧に接続できませんでした。ネットワーク接続を確認して、もう一度お試しください。"
                )
            }

            try Task.checkCancellation()

            guard let http = response as? HTTPURLResponse else {
                throw invalidResponseError()
            }
            guard (200...299).contains(http.statusCode) else {
                let code = httpErrorCode(from: data)
                throw GeminiInferenceError(
                    kind: .http,
                    statusCode: http.statusCode,
                    code: code,
                    message: modelListMessage(statusCode: http.statusCode, code: code)
                )
            }

            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw GeminiInferenceError(
                    kind: .invalidResponse,
                    message: "Gemini のモデル一覧を読み取れませんでした。時間をおいてもう一度お試しください。"
                )
            }

            let entries: [[String: Any]]
            if let rawModels = object["models"] {
                guard let parsed = rawModels as? [[String: Any]] else {
                    throw GeminiInferenceError(
                        kind: .invalidResponse,
                        message: "Gemini のモデル一覧を読み取れませんでした。時間をおいてもう一度お試しください。"
                    )
                }
                entries = parsed
            } else {
                entries = []
            }

            for entry in entries {
                guard let rawName = entry["name"] as? String else { continue }
                let slug = normalizedModelName(rawName)
                guard isValidSlug(slug) else { continue }

                guard let methods = entry["supportedGenerationMethods"] as? [String],
                      methods.contains("generateContent") else { continue }
                guard !isExcludedModel(slug) else { continue }
                guard seenSlugs.insert(slug).inserted else { continue }

                let rawDisplayName = (entry["displayName"] as? String) ?? ""
                let displayName = rawDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
                models.append(
                    GeminiModel(id: slug, displayName: displayName.isEmpty ? slug : displayName)
                )
            }

            guard let rawNext = object["nextPageToken"] as? String else { break }
            let next = rawNext.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !next.isEmpty else { break }
            pageToken = next
        }

        return models
    }

    // MARK: - Request construction

    private static func requestBody(
        model: String,
        systemPrompt: String,
        messages: [[String: String]],
        temperature: Double,
        effort: GeminiThinkingEffort
    ) throws -> Data {
        guard temperature.isFinite else {
            throw GeminiInferenceError(
                kind: .invalidRequest,
                message: "温度（temperature）の値が正しくありません。0〜2 の範囲で指定してください。"
            )
        }

        var systemPieces: [String] = []
        let baseSystem = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !baseSystem.isEmpty { systemPieces.append(baseSystem) }

        var contents: [[String: Any]] = []
        for message in messages {
            let role = (message["role"] ?? "user")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let content = message["content"] ?? ""
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)

            switch role {
            case "system", "developer":
                if !trimmed.isEmpty { systemPieces.append(trimmed) }
            case "assistant", "model":
                guard !trimmed.isEmpty else { continue }
                contents.append(["role": "model", "parts": [["text": content]]])
            default:
                guard !trimmed.isEmpty else { continue }
                contents.append(["role": "user", "parts": [["text": content]]])
            }
        }

        guard !contents.isEmpty else {
            throw GeminiInferenceError(
                kind: .invalidRequest,
                message: "送信するメッセージがありません。メッセージを入力してから、もう一度お試しください。"
            )
        }

        var payload: [String: Any] = ["contents": contents]

        if !systemPieces.isEmpty {
            payload["systemInstruction"] = ["parts": [["text": systemPieces.joined(separator: "\n\n")]]]
        }

        var generationConfig: [String: Any] = ["responseMimeType": "text/plain"]
        // Gemini 3+ recommends the default temperature (1); omitting it avoids
        // sending an unsupported or surprising value.
        if sendsTemperature(model) {
            generationConfig["temperature"] = min(max(temperature, 0), 2)
        }
        if let thinking = try thinkingConfig(model: model, effort: effort) {
            generationConfig["thinkingConfig"] = thinking
        }
        payload["generationConfig"] = generationConfig

        do {
            return try JSONSerialization.data(withJSONObject: payload)
        } catch {
            throw GeminiInferenceError(
                kind: .invalidRequest,
                message: "リクエストを作成できませんでした。入力内容を確認して、もう一度お試しください。"
            )
        }
    }

    private static func thinkingConfig(
        model: String,
        effort: GeminiThinkingEffort
    ) throws -> [String: Any]? {
        guard effort != .automatic else { return nil }

        let supported = GeminiThinkingEffort.supported(for: model)
        guard supported.contains(effort) else {
            let levels = supported
                .filter { $0 != .automatic }
                .map(\.rawValue)
                .joined(separator: " / ")
            throw GeminiInferenceError(
                kind: .invalidRequest,
                message: "このモデル（\(model)）は推論強度「\(effort.rawValue)」に対応していません。"
                    + "対応している強度（\(levels)）を選ぶか、「自動」に戻してください。"
            )
        }

        if isGemini25(model) {
            let budget: Int
            switch effort {
            case .low:
                budget = 1024
            case .medium:
                budget = 8192
            case .high:
                budget = 24576
            case .automatic, .minimal:
                // `minimal` is not part of the supported set above; this branch
                // is unreachable but keeps the switch exhaustive.
                throw GeminiInferenceError(
                    kind: .invalidRequest,
                    message: "このモデルは推論強度「\(effort.rawValue)」に対応していません。「自動」に戻してください。"
                )
            }
            return ["thinkingBudget": budget]
        }

        // Gemini 3+ (and unknown/newer names) use a string thinking level.
        return ["thinkingLevel": effort.rawValue]
    }

    // MARK: - Response parsing

    private static func decodeResponse(_ data: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw invalidResponseError()
        }

        if let feedback = object["promptFeedback"] as? [String: Any],
           let rawReason = feedback["blockReason"] as? String {
            let reason = rawReason.trimmingCharacters(in: .whitespacesAndNewlines)
            if !reason.isEmpty {
                throw GeminiInferenceError(
                    kind: .blocked,
                    code: reason,
                    message: blockedMessage
                )
            }
        }

        // An error envelope with a 2xx status is still a failure, but there is no
        // HTTP status to report and no safe server text to surface.
        if object["error"] is [String: Any], object["candidates"] == nil {
            throw invalidResponseError()
        }

        guard let candidates = object["candidates"] as? [[String: Any]],
              let candidate = candidates.first else {
            throw invalidResponseError()
        }

        guard let rawFinishReason = candidate["finishReason"] as? String else {
            throw invalidResponseError()
        }
        let finishReason = rawFinishReason
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard finishReason == "STOP" else {
            throw finishError(finishReason)
        }

        guard let content = candidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            throw emptyTextError()
        }

        var text = ""
        for part in parts {
            // Thinking parts are not part of the user-visible answer.
            if (part["thought"] as? Bool) == true { continue }
            if let partText = part["text"] as? String { text += partText }
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw emptyTextError()
        }
        return trimmed
    }

    private static func finishError(_ finishReason: String) -> GeminiInferenceError {
        switch finishReason {
        case "SAFETY", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII", "RECITATION", "IMAGE_SAFETY":
            return GeminiInferenceError(kind: .blocked, code: finishReason, message: blockedMessage)
        case "MAX_TOKENS":
            return GeminiInferenceError(
                kind: .incomplete,
                code: finishReason,
                message: "応答が長すぎて途中で終了しました。もう一度お試しください。"
            )
        default:
            return GeminiInferenceError(
                kind: .incomplete,
                code: finishReason,
                message: "Gemini の応答が途中で終了しました。もう一度お試しください。"
            )
        }
    }

    // MARK: - Model naming and filtering

    /// Trims surrounding whitespace and removes one optional `models/` prefix.
    static func normalizedModelName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasPrefix("models/") {
            name.removeFirst("models/".count)
        }
        return name
    }

    static func isValidSlug(_ slug: String) -> Bool {
        guard !slug.isEmpty, slug.count <= maxSlugLength else { return false }
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"
        )
        return slug.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Parses `gemini-<major>[.<minor>]` into a comparable version.
    static func modelVersion(_ slug: String) -> (major: Int, minor: Int)? {
        guard let range = slug.range(of: "gemini-") else { return nil }
        let rest = slug[range.upperBound...]
        guard !rest.isEmpty else { return nil }

        var index = rest.startIndex
        var majorDigits = ""
        while index < rest.endIndex, rest[index].isASCII, rest[index].isNumber {
            majorDigits.append(rest[index])
            index = rest.index(after: index)
        }
        guard !majorDigits.isEmpty, let major = Int(majorDigits) else { return nil }

        var minor = 0
        if index < rest.endIndex, rest[index] == "." {
            index = rest.index(after: index)
            var minorDigits = ""
            while index < rest.endIndex, rest[index].isASCII, rest[index].isNumber {
                minorDigits.append(rest[index])
                index = rest.index(after: index)
            }
            if !minorDigits.isEmpty { minor = Int(minorDigits) ?? 0 }
        }
        return (major, minor)
    }

    private static func isGemini25(_ slug: String) -> Bool {
        guard let version = modelVersion(slug) else { return false }
        return version.major == 2 && version.minor >= 5
    }

    private static func sendsTemperature(_ slug: String) -> Bool {
        // Gemini 3+ docs recommend the default (1); unknown names follow that
        // safer path as well.
        guard let version = modelVersion(slug) else { return false }
        return version.major < 3
    }

    private static let excludedMarkers = [
        "image", "audio", "tts", "live", "robotics", "embedding", "imagen", "veo"
    ]

    private static func isExcludedModel(_ slug: String) -> Bool {
        let lowered = slug.lowercased()
        return excludedMarkers.contains { lowered.contains($0) }
    }

    // MARK: - Validation

    private static func validatedKey(_ raw: String) throws -> String {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw GeminiInferenceError(
                kind: .invalidRequest,
                message: "Gemini の API キーが設定されていません。設定画面で API キーを入力してください。"
            )
        }
        guard key.count <= maxKeyLength,
              key.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7E }) else {
            throw GeminiInferenceError(
                kind: .invalidRequest,
                message: "Gemini の API キーの形式が正しくありません。設定画面で API キーを確認してください。"
            )
        }
        return key
    }

    private static func validatedModelSlug(_ raw: String) throws -> String {
        let slug = normalizedModelName(raw)
        guard isValidSlug(slug) else {
            throw GeminiInferenceError(
                kind: .invalidRequest,
                message: "モデル名が正しくありません。英数字と「.」「_」「-」のみを使用し、設定画面でモデルを選び直してください。"
            )
        }
        return slug
    }

    // MARK: - HTTP errors

    static func httpError(data: Data, statusCode: Int) -> GeminiInferenceError {
        let code = httpErrorCode(from: data)
        return GeminiInferenceError(
            kind: .http,
            statusCode: statusCode,
            code: code,
            message: httpMessage(statusCode: statusCode, code: code)
        )
    }

    static func httpErrorCode(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any] else { return nil }

        if let details = error["details"] as? [[String: Any]],
           let reason = details.compactMap({ $0["reason"] as? String })
               .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return reason
        }
        if let status = error["status"] as? String, !status.isEmpty {
            return status
        }
        return nil
    }

    private static let keyMessage =
        "Gemini の API キーが無効、またはこの API の利用が許可されていません。"
        + "設定画面で API キーを確認し、Google AI Studio で利用権限を確認してください。"

    private static let permissionMessage =
        "この API キーでは Gemini の推論が許可されていません。"
        + "Google AI Studio で API キーの制限と利用権限を確認してください。"

    private static let modelNotFoundMessage =
        "指定した Gemini モデルが見つかりません。設定画面でモデルを選び直してください。"

    private static let quotaMessage =
        "Gemini API の利用上限に達しました。しばらく待つか、Google AI Studio で利用状況を確認してください。"

    private static let transientMessage =
        "Gemini のサーバーで一時的なエラーが発生しました。時間をおいてもう一度お試しください。"

    private static let blockedMessage =
        "Gemini がこの内容の生成をブロックしました。表現を変えて、もう一度お試しください。"

    private static func httpMessage(statusCode: Int, code: String?) -> String {
        if let code {
            switch code {
            case "API_KEY_INVALID", "API_KEY_MISSING", "UNAUTHENTICATED":
                return keyMessage
            case "PERMISSION_DENIED":
                return permissionMessage
            case "MODEL_NOT_FOUND", "NOT_FOUND":
                return modelNotFoundMessage
            case "RESOURCE_EXHAUSTED", "QUOTA_EXCEEDED":
                return quotaMessage
            case "SAFETY", "BLOCKED", "PROHIBITED_CONTENT", "SPII":
                return blockedMessage
            case "UNAVAILABLE", "INTERNAL", "DEADLINE_EXCEEDED":
                return transientMessage
            default:
                break
            }
        }

        switch statusCode {
        case 401, 403:
            return keyMessage
        case 404:
            return modelNotFoundMessage
        case 429:
            return quotaMessage
        case 400:
            return "Gemini のリクエストが受け付けられませんでした。設定画面で API キーとモデル名を確認し、推論 Effort を「自動」に戻してお試しください。"
        case 500...599:
            return transientMessage
        default:
            return "Gemini の推論に失敗しました。時間をおいてもう一度お試しください。"
        }
    }

    private static func modelListMessage(statusCode: Int, code: String?) -> String {
        if let code {
            switch code {
            case "API_KEY_INVALID", "API_KEY_MISSING", "UNAUTHENTICATED":
                return "Gemini の API キーが無効です。設定画面で API キーを確認してください。"
            case "PERMISSION_DENIED":
                return "この API キーでは Gemini のモデル一覧を取得できません。"
                    + "Google AI Studio で API キーの制限を確認してください。"
            case "RESOURCE_EXHAUSTED", "QUOTA_EXCEEDED":
                return "モデル一覧の取得が集中しています。しばらく待ってからもう一度お試しください。"
            case "UNAVAILABLE", "INTERNAL":
                return "Gemini のサーバーで一時的なエラーが発生しました。時間をおいてモデル一覧を更新してください。"
            default:
                break
            }
        }

        switch statusCode {
        case 401, 403:
            return "Gemini のモデル一覧を取得できません。API キーと利用権限を確認してください。"
        case 429:
            return "モデル一覧の取得が集中しています。しばらく待ってからもう一度お試しください。"
        case 500...599:
            return "Gemini のサーバーで一時的なエラーが発生しました。時間をおいてモデル一覧を更新してください。"
        default:
            return "Gemini のモデル一覧を取得できませんでした (HTTP \(statusCode))。"
                + "時間をおいてもう一度お試しください。"
        }
    }

    // MARK: - Shared errors

    private static func invalidResponseError() -> GeminiInferenceError {
        GeminiInferenceError(
            kind: .invalidResponse,
            message: "Gemini の応答を読み取れませんでした。時間をおいてもう一度お試しください。"
        )
    }

    private static func emptyTextError() -> GeminiInferenceError {
        GeminiInferenceError(
            kind: .invalidResponse,
            message: "Gemini からテキストが返りませんでした。プロンプトを変えて、もう一度お試しください。"
        )
    }
}
