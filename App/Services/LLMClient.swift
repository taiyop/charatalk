import Foundation

public enum LLMError: LocalizedError {
    case invalidEndpoint
    case missingAPIKey
    case notSignedInToChatGPT
    case missingChatGPTModel
    case chatGPTSessionChanged
    case requestFailed(statusCode: Int, message: String)
    case invalidResponse
    case decodingError(Error)
    
    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "APIエンドポイントのURLが無効です。設定を確認してください。"
        case .missingAPIKey:
            return "APIキーが設定されていません。設定画面でAPI Keyを入力してください。"
        case .notSignedInToChatGPT:
            return "ChatGPTにサインインしていません。設定画面の「Sign in with ChatGPT」からサインインしてください。"
        case .missingChatGPTModel:
            return "利用可能なChatGPTモデルがありません。設定画面でモデル一覧を更新してください。"
        case .chatGPTSessionChanged:
            return "ChatGPTの認証状態が変更されました。もう一度送信してください。"
        case .requestFailed(let code, let msg):
            return "APIエラー (HTTP \(code)): \(msg)"
        case .invalidResponse:
            return "サーバーから有効な応答を受信できませんでした。"
        case .decodingError(let err):
            return "レスポンスの解析に失敗しました: \(err.localizedDescription)"
        }
    }
}

public actor LLMClient {
    public init() {}
    
    /// 選択されているLLMプロバイダーに応じて対話を生成
    public func generateReply(
        systemPrompt: String,
        messages: [ChatMessage],
        temperature: Double = 0.7
    ) async throws -> String {
        let provider = await AppSettings.shared.llmProviderType
        
        switch provider {
        case .localLFM:
            #if os(iOS) && canImport(LlamaCpp)
            return try await LocalLLMManager.shared.generate(
                systemPrompt: systemPrompt,
                messages: messages,
                temperature: 0.3 // LFM2.5推奨
            )
            #else
            throw LocalLLMError.simulatorNotSupported
            #endif
            
        case .chatGPTSignIn:
            let authManager = await ChatGPTAuthManager.shared
            guard await authManager.isSignedIn else {
                throw LLMError.notSignedInToChatGPT
            }
            let configuration = try await authManager.inferenceConfiguration()
            let effort = await AppSettings.shared.chatGPTReasoningEffort
            return try await ChatGPTInference.send(
                accessToken: configuration.accessToken,
                model: configuration.model,
                systemPrompt: systemPrompt,
                messages: messages.map { ["role": $0.role.rawValue, "content": $0.content] },
                effort: effort,
                refreshAccessToken: { rejectedToken in
                    try await authManager.refreshAfterUnauthorized(rejectedToken: rejectedToken, session: configuration.session)
                }
            )
            
        case .gemini:
            let configuration = await MainActor.run {
                let settings = AppSettings.shared
                let model = settings.geminiModelName.trimmingCharacters(in: .whitespacesAndNewlines)
                let savedEffort = settings.geminiThinkingEffort
                let effort: GeminiThinkingEffort = GeminiThinkingEffort.supported(for: model).contains(savedEffort)
                    ? savedEffort : .automatic
                return (key: settings.geminiAPIKey, model: model, effort: effort)
            }
            return try await GeminiInference.send(
                apiKey: configuration.key,
                model: configuration.model,
                systemPrompt: systemPrompt,
                messages: messages.map { ["role": $0.role.rawValue, "content": $0.content] },
                temperature: temperature,
                effort: configuration.effort
            )

        case .openAICompatible:
            guard let endpointURL = await AppSettings.shared.effectiveEndpointURL else {
                throw LLMError.invalidEndpoint
            }
            let key = await AppSettings.shared.openAIKey
            guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LLMError.missingAPIKey
            }
            let model = await AppSettings.shared.modelName
            return try await sendChat(
                endpoint: endpointURL,
                apiKey: key,
                model: model,
                systemPrompt: systemPrompt,
                messages: messages,
                temperature: temperature
            )
        }
    }
    
    // MARK: - Sign in with ChatGPT (OpenAI Responses API: /v1/responses)
    public func sendChatGPTResponsesAPI(
        accessToken: String,
        model: String,
        systemPrompt: String,
        messages: [ChatMessage],
        temperature: Double = 0.7,
        reasoningEffort: ChatGPTReasoningEffort = .automatic,
        refreshAccessToken: (@Sendable (String) async throws -> String)? = nil
    ) async throws -> String {
        // `temperature` is intentionally omitted for ChatGPT reasoning models.
        // OAuth credentials are never forwarded to Chat Completions.
        return try await ChatGPTInference.send(
            accessToken: accessToken, model: model, systemPrompt: systemPrompt,
            messages: messages.map { ["role": $0.role.rawValue, "content": $0.content] },
            effort: reasoningEffort, refreshAccessToken: refreshAccessToken
        )
    }
    
    // MARK: - OpenAI Compatible Chat Completions API (/v1/chat/completions)
    public func sendChat(
        endpoint: URL,
        apiKey: String,
        model: String,
        systemPrompt: String,
        messages: [ChatMessage],
        temperature: Double = 0.7
    ) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        }
        
        var apiMessages: [[String: String]] = []
        if !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            apiMessages.append([
                "role": "system",
                "content": systemPrompt
            ])
        }
        
        for msg in messages {
            apiMessages.append([
                "role": msg.role.rawValue,
                "content": msg.content
            ])
        }
        
        let payload: [String: Any] = [
            "model": model,
            "messages": apiMessages,
            "temperature": temperature
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorMsg: String
            switch httpResponse.statusCode {
            case 401: errorMsg = "APIキーが無効または期限切れです。APIキーと接続先を確認してください。"
            case 403: errorMsg = "このAPIへのアクセスが許可されていません。権限と接続先を確認してください。"
            case 429: errorMsg = "利用上限に達したか、リクエストが集中しています。時間をおいて再試行してください。"
            default: errorMsg = "リクエストに失敗しました。接続先とモデル設定を確認してください。"
            }
            throw LLMError.requestFailed(statusCode: httpResponse.statusCode, message: errorMsg)
        }
        
        struct ChatCompletionResponse: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable {
                    let role: String?
                    let content: String?
                }
                let message: Message
            }
            let choices: [Choice]
        }
        
        do {
            let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
            guard let reply = decoded.choices.first?.message.content else {
                throw LLMError.invalidResponse
            }
            return reply.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw LLMError.decodingError(error)
        }
    }
}
