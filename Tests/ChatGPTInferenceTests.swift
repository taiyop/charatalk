import Foundation

// Standalone regression harness for App/Services/ChatGPTInference.swift.
//
// Compiled together with the transport into a plain executable: no XCTest, no
// test target, and no real network access. `MockURLProtocol` serves every byte
// of every request, including the SSE streams.

struct TestFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

struct RefreshFailure: Error, Sendable {}

/// URLProtocol stub for both regular HTTP errors and SSE streams.
final class MockURLProtocol: URLProtocol {
    struct Stub {
        var statusCode: Int
        var headers: [String: String]
        var chunks: [Data]
        var failure: URLError?
        var failureBeforeResponse: Bool

        init(
            statusCode: Int = 200,
            headers: [String: String] = ["Content-Type": "text/event-stream"],
            chunks: [Data] = [],
            failure: URLError? = nil,
            failureBeforeResponse: Bool = false
        ) {
            self.statusCode = statusCode
            self.headers = headers
            self.chunks = chunks
            self.failure = failure
            self.failureBeforeResponse = failureBeforeResponse
        }
    }

    struct Recorded {
        let request: URLRequest
        let body: Data?
    }

    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var stubs: [Stub] = []
        private var recorded: [Recorded] = []

        func reset(_ newStubs: [Stub]) {
            lock.lock()
            defer { lock.unlock() }
            stubs = newStubs
            recorded.removeAll()
        }

        func next() -> Stub {
            lock.lock()
            defer { lock.unlock() }
            if stubs.count > 1 {
                return stubs.removeFirst()
            }
            return stubs.first ?? Stub()
        }

        func record(_ request: URLRequest, body: Data?) {
            lock.lock()
            defer { lock.unlock() }
            recorded.append(Recorded(request: request, body: body))
        }

        func recordings() -> [Recorded] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }
    }

    static let state = State()

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let stub = Self.state.next()
        Self.state.record(request, body: Self.extractBody(from: request))

        if stub.failureBeforeResponse {
            client?.urlProtocol(self, didFailWithError: stub.failure ?? URLError(.unknown))
            return
        }

        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        guard let response = HTTPURLResponse(
            url: url,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in stub.chunks {
            client?.urlProtocol(self, didLoad: chunk)
        }

        if let failure = stub.failure {
            client?.urlProtocol(self, didFailWithError: failure)
        } else {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    /// URLProtocol often receives a body stream instead of `httpBody`; read it
    /// once so tests can assert on the exact JSON payload.
    private static func extractBody(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { return nil }

        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBufferPointer { pointer in
                stream.read(pointer.baseAddress!, maxLength: pointer.count)
            }
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

final class RefreshRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedTokens: [String] = []

    func record(_ token: String) {
        lock.lock()
        defer { lock.unlock() }
        recordedTokens.append(token)
    }

    func tokens() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedTokens
    }

    var callCount: Int {
        tokens().count
    }
}

@main
struct ChatGPTInferenceTests {
    // MARK: - Fixtures

    static let token = "oauth-token-123"
    static let model = "gpt-6.1-sol"
    static let systemPrompt = "あなたは簡潔に答えるアシスタントです。"
    static let messages: [[String: String]] = [
        ["role": "user", "content": "こんにちは。今日の天気は？🌤️"]
    ]

    static let mockSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }()

    // MARK: - Mock helpers

    static func reset(_ stubs: [MockURLProtocol.Stub]) {
        MockURLProtocol.state.reset(stubs)
    }

    static func streamStub(_ body: String, status: Int = 200) -> MockURLProtocol.Stub {
        MockURLProtocol.Stub(
            statusCode: status,
            headers: ["Content-Type": "text/event-stream"],
            chunks: [Data(body.utf8)]
        )
    }

    static func jsonStub(status: Int, body: String, requestID: String? = nil) -> MockURLProtocol.Stub {
        var headers = ["Content-Type": "application/json"]
        if let requestID {
            headers["X-Request-ID"] = requestID
        }
        return MockURLProtocol.Stub(
            statusCode: status,
            headers: headers,
            chunks: [Data(body.utf8)]
        )
    }

    static func recordings() -> [MockURLProtocol.Recorded] {
        MockURLProtocol.state.recordings()
    }

    static func recordedBody(_ recording: MockURLProtocol.Recorded, _ label: String) throws -> [String: Any] {
        guard let data = recording.body,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TestFailure(message: "\(label): request body was missing or not a JSON object")
        }
        return object
    }

    static func bodyJSON(_ recording: MockURLProtocol.Recorded) throws -> [String: Any] {
        try recordedBody(recording, "recorded body")
    }

    static func jsonString(_ object: Any) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    static func event(_ name: String, _ object: [String: Any]) -> String {
        "event: \(name)\ndata: \(jsonString(object))\n\n"
    }

    static func deltaEvent(_ text: String) -> String {
        event("response.output_text.delta", [
            "type": "response.output_text.delta",
            "delta": text
        ])
    }

    static func completedEvent(
        status: String? = "completed",
        outputText: String? = nil,
        output: [[String: Any]]? = nil
    ) -> String {
        var response: [String: Any] = ["id": "resp_test"]
        if let status {
            response["status"] = status
        }
        if let outputText {
            response["output_text"] = outputText
        }
        if let output {
            response["output"] = output
        }
        return event("response.completed", [
            "type": "response.completed",
            "response": response
        ])
    }

    static func outputItem(_ text: String) -> [String: Any] {
        [
            "type": "message",
            "role": "assistant",
            "content": [["type": "output_text", "text": text]]
        ]
    }

    static func failedEvent(code: String?, param: String? = nil, message: String = "SECRET-RAW") -> String {
        var error: [String: Any] = ["message": message]
        if let code {
            error["code"] = code
        }
        if let param {
            error["param"] = param
        }
        return event("response.failed", [
            "type": "response.failed",
            "response": ["id": "resp_test", "status": "failed", "error": error]
        ])
    }

    static func incompleteEvent(reason: String? = nil, code: String? = nil) -> String {
        var response: [String: Any] = ["id": "resp_test", "status": "incomplete"]
        if let reason {
            response["incomplete_details"] = ["reason": reason]
        }
        if let code {
            response["error"] = ["code": code, "message": "SECRET-INCOMPLETE"]
        }
        return event("response.incomplete", [
            "type": "response.incomplete",
            "response": response
        ])
    }

    static func successStream(_ text: String) -> String {
        deltaEvent(text) + completedEvent(outputText: text)
    }

    // MARK: - Assertions

    static func expectTrue(_ label: String, _ condition: Bool) throws {
        guard condition else { throw TestFailure(message: "\(label): condition was false") }
    }

    static func expectEqual<T: Equatable>(_ label: String, _ actual: T, _ expected: T) throws {
        guard actual == expected else {
            throw TestFailure(
                message: "\(label): expected \(String(reflecting: expected)), got \(String(reflecting: actual))"
            )
        }
    }

    static func expectNil<T>(_ label: String, _ actual: T?) throws {
        guard actual == nil else {
            throw TestFailure(message: "\(label): expected nil, got \(String(reflecting: actual!))")
        }
    }

    static func expectContains(_ label: String, _ haystack: String, _ needle: String) throws {
        guard haystack.contains(needle) else {
            throw TestFailure(
                message: "\(label): expected message to contain \(String(reflecting: needle)), got \(String(reflecting: haystack))"
            )
        }
    }

    static func expectDoesNotContain(_ label: String, _ haystack: String, _ needle: String) throws {
        guard !haystack.contains(needle) else {
            throw TestFailure(
                message: "\(label): expected message not to contain \(String(reflecting: needle)), got \(String(reflecting: haystack))"
            )
        }
    }

    static func unwrap<T>(_ value: T?, _ label: String) throws -> T {
        guard let value else { throw TestFailure(message: "\(label): expected a value, got nil") }
        return value
    }

    // MARK: - Send helpers

    @discardableResult
    static func send(
        token: String = token,
        model: String = model,
        systemPrompt: String = systemPrompt,
        messages: [[String: String]] = messages,
        effort: ChatGPTReasoningEffort = .automatic,
        refresh: (@Sendable (String) async throws -> String)? = nil
    ) async throws -> String {
        try await ChatGPTInference.send(
            accessToken: token,
            model: model,
            systemPrompt: systemPrompt,
            messages: messages,
            effort: effort,
            session: mockSession,
            refreshAccessToken: refresh
        )
    }

    static func captureError(
        _ label: String,
        _ operation: () async throws -> String
    ) async throws -> ChatGPTInferenceError {
        do {
            let value = try await operation()
            throw TestFailure(message: "\(label): expected an error, got \(value)")
        } catch let failure as TestFailure {
            throw failure
        } catch let error as ChatGPTInferenceError {
            return error
        } catch {
            throw TestFailure(message: "\(label): unexpected error \(error)")
        }
    }

    static func expectNoPartial(_ label: String, _ error: ChatGPTInferenceError, _ partial: String) throws {
        try expectDoesNotContain(label, error.localizedDescription, partial)
        try expectDoesNotContain(label, String(describing: error), partial)
    }

    // MARK: - Reasoning effort

    static func testEffortEnumExposesRawValuesAndLabels() throws {
        try expectEqual(
            "case order",
            ChatGPTReasoningEffort.allCases.map(\.rawValue),
            ["", "none", "minimal", "low", "medium", "high", "xhigh", "max"]
        )
        try expectEqual("automatic raw value", ChatGPTReasoningEffort.automatic.rawValue, "")
        try expectEqual("automatic id", ChatGPTReasoningEffort.automatic.id, "automatic")
        try expectEqual("none id", ChatGPTReasoningEffort.none.id, "none")
        try expectEqual("max id", ChatGPTReasoningEffort.max.id, "max")

        let ids = ChatGPTReasoningEffort.allCases.map(\.id)
        try expectEqual("unique ids", Set(ids).count, ids.count)
        try expectTrue("ids non-empty", ids.allSatisfy { !$0.isEmpty })

        try expectContains("automatic label", ChatGPTReasoningEffort.automatic.displayName, "自動")
        for effort in ChatGPTReasoningEffort.allCases where effort != .automatic {
            try expectContains("label contains raw name", effort.displayName, effort.rawValue)
        }
    }

    // MARK: - Request shape

    static func testRequestShapeAndSuccessfulCompletedText() async throws {
        let responseText = "やあ、元気？🌏"
        reset([streamStub(successStream(responseText))])

        let result = try await send()
        try expectEqual("final text", result, responseText)

        let requests = recordings()
        try expectEqual("one request", requests.count, 1)
        let request = try unwrap(requests.first?.request, "recorded request")

        try expectEqual("POST", request.httpMethod, "POST")
        try expectEqual("scheme", request.url?.scheme, "https")
        try expectEqual("host", request.url?.host, "api.openai.com")
        try expectEqual("path", request.url?.path, "/v1/responses")
        try expectNil("no query", request.url?.query)
        try expectEqual(
            "bearer token",
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer \(token)"
        )
        try expectEqual(
            "content type",
            request.value(forHTTPHeaderField: "Content-Type"),
            "application/json"
        )
        try expectEqual(
            "accept stream",
            request.value(forHTTPHeaderField: "Accept"),
            "text/event-stream"
        )

        let json = try bodyJSON(requests[0])
        try expectEqual("model", json["model"] as? String, model)
        try expectEqual("store false", json["store"] as? Bool, false)
        try expectEqual("stream true", json["stream"] as? Bool, true)
        try expectEqual("instructions", json["instructions"] as? String, systemPrompt)
        try expectNil("automatic effort omitted", json["reasoning"])
        try expectNil("temperature omitted", json["temperature"])

        let input = try unwrap(json["input"] as? [[String: Any]], "input")
        try expectEqual("message count", input.count, messages.count)
        try expectEqual("message role", input[0]["role"] as? String, messages[0]["role"])
        try expectEqual("message content", input[0]["content"] as? String, messages[0]["content"])
    }

    static func testEveryEffortLevelIsSentVerbatim() async throws {
        for effort in ChatGPTReasoningEffort.allCases {
            reset([streamStub(successStream("ok"))])
            _ = try await send(effort: effort)

            let requests = recordings()
            let json = try bodyJSON(try unwrap(requests.first, "request for \(effort.id)"))
            try expectNil("temperature omitted for \(effort.id)", json["temperature"])

            if effort == .automatic {
                try expectNil("automatic sends no reasoning object", json["reasoning"])
            } else {
                let reasoning = try unwrap(
                    json["reasoning"] as? [String: Any],
                    "reasoning object for \(effort.id)"
                )
                try expectEqual("effort raw value for \(effort.id)", reasoning["effort"] as? String, effort.rawValue)
            }
        }
    }

    static func testBlankSystemPromptOmitsInstructions() async throws {
        for prompt in ["", "   ", "\n\t  \n"] {
            reset([streamStub(successStream("ok"))])
            _ = try await send(systemPrompt: prompt)

            let requests = recordings()
            let json = try bodyJSON(try unwrap(requests.first, "request for blank prompt"))
            try expectNil("instructions omitted", json["instructions"])
        }
    }

    // MARK: - SSE success

    static func testSSEHandlesCRLFCommentsMultilineUnicodeAndTrailingEventWithoutBlank() async throws {
        let completed = jsonString([
            "type": "response.completed",
            "response": ["id": "resp_test"]
        ])

        let body = """
        : heartbeat\r
        event: response.created\r
        data: \(jsonString(["type": "response.created", "response": ["id": "resp_test"]]))\r
        \r
        event: response.output_text.delta\r
        data: {"type":"response.output_text.delta",\r
        data: "delta":"こんにちは"}\r
        \r
        event: response.reasoning_text.delta\r
        data: \(jsonString(["type": "response.reasoning_text.delta", "delta": "SECRET-REASONING"]))\r
        \r
        event: something.unknown\r
        data: not-json\r
        \r
        event: response.output_text.delta\r
        data: \(jsonString(["type": "response.output_text.delta", "delta": "、世界！🌏"]))\r
        \r
        event: response.completed\r
        data: \(completed)
        """

        reset([streamStub(body)])
        let result = try await send()
        try expectEqual("streamed text", result, "こんにちは、世界！🌏")
        try expectDoesNotContain("reasoning excluded", result, "SECRET-REASONING")
    }

    static func testCompletedOutputIgnoresReasoningContent() async throws {
        let reasoningItem: [String: Any] = [
            "type": "reasoning",
            "content": [["type": "reasoning_text", "text": "SECRET-REASONING"]]
        ]
        reset([
            streamStub(
                completedEvent(output: [reasoningItem, outputItem("最終回答です。")])
            )
        ])

        let result = try await send()
        try expectEqual("only output_text content", result, "最終回答です。")
        try expectDoesNotContain("no reasoning leak", result, "SECRET-REASONING")
    }

    static func testCompletedOutputTextFieldWinsAndEmptyFieldFallsBackToOutput() async throws {
        reset([
            streamStub(
                completedEvent(
                    outputText: "FIELD",
                    output: [outputItem("CONTENT")]
                )
            )
        ])
        try expectEqual("output_text precedence", try await send(), "FIELD")

        reset([
            streamStub(
                completedEvent(
                    outputText: "",
                    output: [outputItem("CONTENT")]
                )
            )
        ])
        try expectEqual("empty output_text fallback", try await send(), "CONTENT")

        reset([streamStub(completedEvent(outputText: "  回答です。\n"))])
        try expectEqual("surrounding whitespace trimmed", try await send(), "回答です。")
    }

    static func testCompletedWithoutTerminalTextUsesAccumulatedDeltas() async throws {
        reset([
            streamStub(
                deltaEvent("累積") + deltaEvent("テキスト") + completedEvent(status: nil)
            )
        ])
        try expectEqual("accumulated deltas", try await send(), "累積テキスト")
    }

    static func testDoneAfterCompletedStillReturnsCompletedText() async throws {
        reset([
            streamStub(completedEvent(outputText: "完了") + "\n\ndata: [DONE]\n\n")
        ])
        try expectEqual("completed wins", try await send(), "完了")
    }

    // MARK: - SSE terminal failures

    static func testFailedAfterDeltaNeverReturnsPartialText() async throws {
        reset([
            streamStub(
                deltaEvent("部分的な回答")
                    + failedEvent(
                        code: "subscription_sharing_usage_limit_exceeded",
                        param: "reasoning.effort"
                    )
            )
        ])

        let error = try await captureError("failed stream") { try await send() }
        try expectEqual("kind", error.kind, .stream)
        try expectNil("no HTTP status", error.statusCode)
        try expectEqual("code", error.code, "subscription_sharing_usage_limit_exceeded")
        try expectEqual("param", error.param, "reasoning.effort")
        try expectContains("usage link", error.localizedDescription, "https://chatgpt.com/settings/usage")
        try expectContains("usage settings", error.localizedDescription, "使用状況")
        try expectDoesNotContain("raw message hidden", error.localizedDescription, "SECRET-RAW")
        try expectNoPartial("partial hidden", error, "部分的な回答")
    }

    static func testFailedWithoutErrorObjectStillThrows() async throws {
        reset([
            streamStub(
                event("response.failed", [
                    "type": "response.failed",
                    "response": ["status": "failed"]
                ])
            )
        ])

        let error = try await captureError("failed without error") { try await send() }
        try expectEqual("kind", error.kind, .stream)
        try expectEqual("fallback code", error.code, "response_failed")
        try expectContains("interrupted message", error.localizedDescription, "途中")
    }

    static func testIncompleteAndErrorEventsThrow() async throws {
        reset([streamStub(incompleteEvent(reason: "max_output_tokens"))])
        let incomplete = try await captureError("incomplete") { try await send() }
        try expectEqual("incomplete kind", incomplete.kind, .stream)
        try expectEqual("incomplete code", incomplete.code, "max_output_tokens")
        try expectContains("incomplete message", incomplete.localizedDescription, "長すぎ")

        reset([streamStub(incompleteEvent(code: "server_error"))])
        let incompleteWithError = try await captureError("incomplete with error") { try await send() }
        try expectEqual("incomplete error code", incompleteWithError.code, "server_error")
        try expectDoesNotContain("incomplete leak", incompleteWithError.localizedDescription, "SECRET-INCOMPLETE")

        reset([
            streamStub(
                event("error", [
                    "type": "error",
                    "code": "rate_limit_exceeded",
                    "param": "model",
                    "message": "SECRET-ERROR"
                ])
            )
        ])
        let explicit = try await captureError("error event") { try await send() }
        try expectEqual("error event kind", explicit.kind, .stream)
        try expectEqual("error event code", explicit.code, "rate_limit_exceeded")
        try expectEqual("error event param", explicit.param, "model")
        try expectDoesNotContain("error event leak", explicit.localizedDescription, "SECRET-ERROR")

        reset([
            streamStub(
                event("error", [
                    "type": "error",
                    "error": ["code": "server_error", "param": "input", "message": "SECRET-NESTED"]
                ])
            )
        ])
        let nested = try await captureError("nested error event") { try await send() }
        try expectEqual("nested code", nested.code, "server_error")
        try expectEqual("nested param", nested.param, "input")
        try expectDoesNotContain("nested leak", nested.localizedDescription, "SECRET-NESTED")
    }

    static func testCompletedWithNonCompletedStatusThrows() async throws {
        reset([streamStub(completedEvent(status: "incomplete", outputText: "PARTIAL"))])
        let incomplete = try await captureError("completed with incomplete status") { try await send() }
        try expectEqual("kind", incomplete.kind, .stream)
        try expectEqual("status code used as code", incomplete.code, "incomplete")
        try expectNoPartial("status partial hidden", incomplete, "PARTIAL")

        reset([streamStub(completedEvent(status: "failed", outputText: "PARTIAL"))])
        let failed = try await captureError("completed with failed status") { try await send() }
        try expectEqual("failed code", failed.code, "failed")
        try expectNoPartial("failed partial hidden", failed, "PARTIAL")
    }

    static func testDoneOnlyAndInterruptedStreamsThrow() async throws {
        reset([streamStub(deltaEvent("未完了の回答"))])
        let truncated = try await captureError("delta then EOF") { try await send() }
        try expectEqual("EOF kind", truncated.kind, .stream)
        try expectEqual("EOF code", truncated.code, "stream_interrupted")
        try expectNoPartial("EOF partial hidden", truncated, "未完了の回答")

        reset([streamStub("data: [DONE]\n\n")])
        let doneOnly = try await captureError("DONE only") { try await send() }
        try expectEqual("DONE kind", doneOnly.kind, .stream)
        try expectEqual("DONE code", doneOnly.code, "stream_interrupted")

        reset([streamStub(": comment only\n\n")])
        let commentsOnly = try await captureError("comments only") { try await send() }
        try expectEqual("comments kind", commentsOnly.kind, .stream)
        try expectEqual("comments code", commentsOnly.code, "stream_interrupted")
    }

    static func testMalformedTerminalEventAndEmptyCompletedThrow() async throws {
        reset([streamStub("event: response.completed\ndata: {not-json\n\n")])
        let malformed = try await captureError("malformed completed") { try await send() }
        try expectEqual("malformed kind", malformed.kind, .invalidResponse)

        reset([streamStub(completedEvent())])
        let empty = try await captureError("completed without text") { try await send() }
        try expectEqual("empty kind", empty.kind, .invalidResponse)
        try expectContains("empty message", empty.localizedDescription, "読み取れません")
    }

    static func testTransportInterruptionThrowsTypedError() async throws {
        reset([
            MockURLProtocol.Stub(
                failure: URLError(.cannotConnectToHost),
                failureBeforeResponse: true
            )
        ])
        let beforeStream = try await captureError("pre-stream transport") { try await send() }
        try expectEqual("pre-stream kind", beforeStream.kind, .transport)
        try expectNil("pre-stream no status", beforeStream.statusCode)

        reset([
            MockURLProtocol.Stub(
                headers: ["Content-Type": "text/event-stream"],
                chunks: [Data(deltaEvent("途中").utf8)],
                failure: URLError(.networkConnectionLost)
            )
        ])
        let midStream = try await captureError("mid-stream transport") { try await send() }
        try expectEqual("mid-stream kind", midStream.kind, .transport)
        try expectNoPartial("mid-stream partial hidden", midStream, "途中")
    }

    // MARK: - HTTP failures

    static func testHTTP401IsFriendlyAndKeepsSanitizedMetadata() async throws {
        reset([
            jsonStub(
                status: 401,
                body: #"{"error":{"code":"invalid_api_key","param":"reasoning.effort","message":"SECRET-AUTH"}}"#,
                requestID: "req_401-abc"
            )
        ])

        let error = try await captureError("HTTP 401") { try await send() }
        try expectEqual("kind", error.kind, .http)
        try expectEqual("status", error.statusCode, 401)
        try expectEqual("request ID", error.requestID, "req_401-abc")
        try expectEqual("code", error.code, "invalid_api_key")
        try expectEqual("param", error.param, "reasoning.effort")
        try expectContains("sign in guidance", error.localizedDescription, "サインイン")
        try expectContains("plan guidance", error.localizedDescription, "プラン")
        try expectContains("scope guidance", error.localizedDescription, "chatgpt.tokens.use.direct")
        try expectDoesNotContain("auth body hidden", error.localizedDescription, "SECRET-AUTH")
        try expectEqual("one attempted request", recordings().count, 1)
    }

    static func testHTTP403DetailBodyDoesNotLeak() async throws {
        reset([
            jsonStub(
                status: 403,
                body: #"{"detail":"SECRET-DETAIL-BODY"}"#,
                requestID: "req_403-detail"
            )
        ])

        let error = try await captureError("HTTP 403 detail") { try await send() }
        try expectEqual("status", error.statusCode, 403)
        try expectNil("nonstandard detail has no code", error.code)
        try expectNil("nonstandard detail has no param", error.param)
        try expectEqual("request ID retained", error.requestID, "req_403-detail")
        try expectContains("policy guidance", error.localizedDescription, "許可")
        try expectDoesNotContain("detail hidden", error.localizedDescription, "SECRET-DETAIL-BODY")
    }

    static func testHTTP429AndServerStatusesAreActionable() async throws {
        reset([
            jsonStub(
                status: 429,
                body: #"{"error":{"code":"subscription_sharing_usage_limit_exceeded","message":"SECRET-429"}}"#
            )
        ])
        let limited = try await captureError("HTTP 429") { try await send() }
        try expectEqual("429 status", limited.statusCode, 429)
        try expectContains("usage link", limited.localizedDescription, "https://chatgpt.com/settings/usage")
        try expectContains("usage setting", limited.localizedDescription, "使用状況")
        try expectDoesNotContain("429 body hidden", limited.localizedDescription, "SECRET-429")

        reset([
            jsonStub(
                status: 503,
                body: #"{"error":{"code":"subscription_sharing_usage_unavailable","message":"SECRET-503"}}"#
            )
        ])
        let unavailable = try await captureError("HTTP 503") { try await send() }
        try expectEqual("503 status", unavailable.statusCode, 503)
        try expectContains("503 retry guidance", unavailable.localizedDescription, "時間をおいて")
        try expectDoesNotContain("503 body hidden", unavailable.localizedDescription, "SECRET-503")

        reset([jsonStub(status: 500, body: "SECRET-500-BODY")])
        let server = try await captureError("HTTP 500") { try await send() }
        try expectEqual("500 status", server.statusCode, 500)
        try expectNil("non-JSON 500 has no code", server.code)
        try expectContains("500 status text", server.localizedDescription, "HTTP 500")
        try expectContains("500 retry guidance", server.localizedDescription, "時間をおいて")
        try expectDoesNotContain("500 body hidden", server.localizedDescription, "SECRET-500-BODY")

        reset([jsonStub(status: 404, body: #"{"error":{"message":"SECRET-404"}}"#)])
        let notFound = try await captureError("HTTP 404") { try await send() }
        try expectEqual("404 status", notFound.statusCode, 404)
        try expectContains("404 status text", notFound.localizedDescription, "HTTP 404")
        try expectDoesNotContain("404 body hidden", notFound.localizedDescription, "SECRET-404")

        for status in [400, 401, 403, 404, 429, 500, 503] {
            let error = ChatGPTInferenceError.httpError(data: Data(), statusCode: status)
            let occurrences = error.localizedDescription.components(separatedBy: "HTTP \(status)").count - 1
            try expectEqual("HTTP \(status) appears once", occurrences, 1)
        }
    }

    static func testHTTP400EffortParameterSuggestsAutomatic() async throws {
        reset([
            jsonStub(
                status: 400,
                body: #"{"error":{"code":"unsupported_parameter","param":"reasoning.effort","message":"SECRET-400"}}"#
            )
        ])

        let error = try await captureError("HTTP 400 effort") { try await send(effort: .max) }
        try expectEqual("status", error.statusCode, 400)
        try expectEqual("code", error.code, "unsupported_parameter")
        try expectEqual("param", error.param, "reasoning.effort")
        try expectContains("automatic guidance", error.localizedDescription, "自動")
        try expectContains("effort guidance", error.localizedDescription, "推論強度")
        try expectDoesNotContain("400 body hidden", error.localizedDescription, "SECRET-400")
    }

    static func testKnownSubscriptionSharingCodesFromDocs() async throws {
        let cases: [(status: Int, code: String, param: String?, expected: String)] = [
            (403, "subscription_sharing_user_not_eligible", nil, "権限"),
            (403, "subscription_sharing_route_not_supported", nil, "POST /v1/responses"),
            (401, "subscription_sharing_invalid_user", nil, "サインイン"),
            (503, "subscription_sharing_user_unavailable", nil, "時間をおいて"),
            (503, "subscription_sharing_usage_unavailable", nil, "時間をおいて"),
            (403, "chatpass_v2_scope_not_authorized", nil, "権限"),
            (403, "chatpass_v2_invalid_authorization_context", nil, "権限"),
            (400, "subscription_sharing_unsupported_capability", "tools", "未対応")
        ]

        for entry in cases {
            var errorBody: [String: Any] = ["code": entry.code, "message": "SECRET-\(entry.code)"]
            if let param = entry.param {
                errorBody["param"] = param
            }
            reset([
                jsonStub(
                    status: entry.status,
                    body: jsonString(["error": errorBody])
                )
            ])

            let error = try await captureError("code \(entry.code)") { try await send() }
            try expectEqual("status for \(entry.code)", error.statusCode, entry.status)
            try expectEqual("code for \(entry.code)", error.code, entry.code)
            try expectContains("message for \(entry.code)", error.localizedDescription, entry.expected)
            try expectDoesNotContain("body hidden for \(entry.code)", error.localizedDescription, "SECRET-\(entry.code)")
        }
    }

    static func testErrorMetadataSanitization() throws {
        let mixed = ChatGPTInferenceError.httpError(
            data: Data(
                #"{"error":{"code":"bad code SECRET","param":"reasoning.effort","message":"SECRET-MESSAGE"}}"#.utf8
            ),
            statusCode: 400,
            requestID: "bad request id SECRET"
        )
        try expectNil("whitespace code dropped", mixed.code)
        try expectEqual("valid param retained", mixed.param, "reasoning.effort")
        try expectNil("invalid request ID dropped", mixed.requestID)
        try expectDoesNotContain("message not leaked", mixed.localizedDescription, "SECRET-MESSAGE")
        try expectDoesNotContain("request ID not leaked", mixed.localizedDescription, "SECRET")

        let longCode = String(repeating: "a", count: 200)
        let longParam = String(repeating: "b", count: 200)
        let long = ChatGPTInferenceError.httpError(
            data: Data(
                jsonString(["error": ["code": longCode, "param": longParam]]).utf8
            ),
            statusCode: 400
        )
        try expectNil("overlong code dropped", long.code)
        try expectNil("overlong param dropped", long.param)

        let nonJSON = ChatGPTInferenceError.httpError(
            data: Data("SECRET-NON-JSON".utf8),
            statusCode: 418
        )
        try expectNil("non-JSON code", nonJSON.code)
        try expectNil("non-JSON param", nonJSON.param)
        try expectNil("non-JSON request ID", nonJSON.requestID)
        try expectEqual("non-JSON status retained", nonJSON.statusCode, 418)
        try expectDoesNotContain("non-JSON hidden", nonJSON.localizedDescription, "SECRET-NON-JSON")

        let bodyRequestID = ChatGPTInferenceError.httpError(
            data: Data(#"{"error":{"code":"some_code"},"request_id":"req_body-123"}"#.utf8),
            statusCode: 500
        )
        try expectEqual("body request ID", bodyRequestID.requestID, "req_body-123")

        let headerWins = ChatGPTInferenceError.httpError(
            data: Data(#"{"request_id":"req_body-123"}"#.utf8),
            statusCode: 500,
            requestID: "req_header-456"
        )
        try expectEqual("header request ID wins", headerWins.requestID, "req_header-456")
    }

    // MARK: - 401 refresh

    static func testPreStream401RefreshesOnceAndPreservesPayload() async throws {
        let recorder = RefreshRecorder()
        let success = successStream("更新後の回答")
        reset([
            jsonStub(
                status: 401,
                body: #"{"error":{"code":"invalid_api_key","message":"SECRET-401"}}"#
            ),
            streamStub(success)
        ])

        let result = try await send(effort: .high) { rejectedToken in
            recorder.record(rejectedToken)
            return "fresh-token"
        }
        try expectEqual("result after refresh", result, "更新後の回答")
        try expectEqual("refresh called once", recorder.callCount, 1)
        try expectEqual("rejected token passed", recorder.tokens(), [token])

        let requests = recordings()
        try expectEqual("two attempts", requests.count, 2)
        try expectEqual(
            "first bearer token",
            requests[0].request.value(forHTTPHeaderField: "Authorization"),
            "Bearer \(token)"
        )
        try expectEqual(
            "second bearer token",
            requests[1].request.value(forHTTPHeaderField: "Authorization"),
            "Bearer fresh-token"
        )

        let firstBody = try unwrap(requests[0].body, "first body")
        let secondBody = try unwrap(requests[1].body, "second body")
        try expectEqual("identical payload", firstBody, secondBody)

        let firstJSON = try bodyJSON(requests[0])
        let secondJSON = try bodyJSON(requests[1])
        let firstReasoning = try unwrap(firstJSON["reasoning"] as? [String: Any], "first reasoning")
        let secondReasoning = try unwrap(secondJSON["reasoning"] as? [String: Any], "second reasoning")
        try expectEqual("first effort preserved", firstReasoning["effort"] as? String, "high")
        try expectEqual("second effort preserved", secondReasoning["effort"] as? String, "high")
    }

    static func testSecond401IsFinalAndDoesNotRefreshAgain() async throws {
        let recorder = RefreshRecorder()
        reset([
            jsonStub(status: 401, body: #"{"error":{"code":"invalid_api_key"}}"#),
            jsonStub(
                status: 401,
                body: #"{"error":{"code":"subscription_sharing_invalid_user"}}"#,
                requestID: "req_second-401"
            )
        ])

        let error = try await captureError("second 401") {
            try await send { rejectedToken in
                recorder.record(rejectedToken)
                return "fresh-token"
            }
        }

        try expectEqual("refresh called once", recorder.callCount, 1)
        try expectEqual("two attempts only", recordings().count, 2)
        try expectEqual("second status", error.statusCode, 401)
        try expectEqual("second code", error.code, "subscription_sharing_invalid_user")
        try expectEqual("second request ID", error.requestID, "req_second-401")
        try expectContains("sign in again", error.localizedDescription, "サインイン")
    }

    static func testNon401HTTPFailuresAndStreamFailuresDoNotRefresh() async throws {
        for status in [403, 429, 500] {
            let recorder = RefreshRecorder()
            reset([
                jsonStub(
                    status: status,
                    body: #"{"error":{"code":"some_error","message":"SECRET-NO-REFRESH"}}"#
                )
            ])

            let error = try await captureError("HTTP \(status) no refresh") {
                try await send { rejectedToken in
                    recorder.record(rejectedToken)
                    return "fresh-token"
                }
            }
            try expectEqual("status \(status)", error.statusCode, status)
            try expectEqual("no refresh for \(status)", recorder.callCount, 0)
            try expectEqual("one attempt for \(status)", recordings().count, 1)
        }

        let recorder = RefreshRecorder()
        reset([
            streamStub(
                deltaEvent("partial")
                    + failedEvent(code: "subscription_sharing_invalid_user")
            )
        ])
        let streamError = try await captureError("stream failure no refresh") {
            try await send { rejectedToken in
                recorder.record(rejectedToken)
                return "fresh-token"
            }
        }
        try expectEqual("stream failure kind", streamError.kind, .stream)
        try expectEqual("no refresh after stream started", recorder.callCount, 0)
        try expectEqual("one stream attempt", recordings().count, 1)
    }

    static func testRefreshFailurePropagatesWithoutRetry() async throws {
        let recorder = RefreshRecorder()
        reset([
            jsonStub(status: 401, body: #"{"error":{"code":"invalid_api_key"}}"#)
        ])

        do {
            _ = try await send { rejectedToken in
                recorder.record(rejectedToken)
                throw RefreshFailure()
            }
            throw TestFailure(message: "refresh failure: expected an error")
        } catch let failure as TestFailure {
            throw failure
        } catch is RefreshFailure {
            try expectEqual("refresh attempted once", recorder.callCount, 1)
            try expectEqual("no retry after refresh failure", recordings().count, 1)
        } catch {
            throw TestFailure(message: "refresh failure: unexpected error \(error)")
        }
    }

    static func testEmptyRefreshedTokenIsRejected() async throws {
        let recorder = RefreshRecorder()
        reset([
            jsonStub(status: 401, body: #"{"error":{"code":"invalid_api_key"}}"#)
        ])

        let error = try await captureError("empty refreshed token") {
            try await send { rejectedToken in
                recorder.record(rejectedToken)
                return "   "
            }
        }
        try expectEqual("kind", error.kind, .invalidResponse)
        try expectEqual("refresh called once", recorder.callCount, 1)
        try expectEqual("no second request", recordings().count, 1)
    }

    static func testSSEWaitsForEventBoundary() async throws {
        let body = "event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"output_text\":\"UNTRUSTED\"}}\ndata: invalid trailing data\n\n"
        reset([streamStub(body)])
        let error = try await captureError("multi-line event must not complete early") { try await send() }
        try expectEqual("invalid combined event", error.kind, .invalidResponse)
        try expectDoesNotContain("no partial reply", error.localizedDescription, "UNTRUSTED")
    }

    static func testSSEBareCRAndByteChunkedUnicode() async throws {
        let body = successStream("こんにちは🌏").replacingOccurrences(of: "\n", with: "\r")
        reset([MockURLProtocol.Stub(chunks: body.utf8.map { Data([$0]) })])
        try expectEqual("byte-split Unicode with CR framing", try await send(), "こんにちは🌏")
    }

    static func testModelValidationAndSystemRoleConversion() async throws {
        reset([streamStub(successStream("ok"))])
        _ = try await ChatGPTInference.send(
            accessToken: token, model: "  \(model)\n", systemPrompt: "",
            messages: [["role": "system", "content": "instruction"]], session: mockSession
        )
        let body = try bodyJSON(try unwrap(recordings().first, "request"))
        try expectEqual("trimmed model", body["model"] as? String, model)
        let input = try unwrap(body["input"] as? [[String: String]], "input")
        try expectEqual("system becomes developer", input.first?["role"], "developer")

        reset([])
        _ = try await captureError("empty model") {
            try await ChatGPTInference.send(accessToken: token, model: " \n", systemPrompt: "", messages: [], session: mockSession)
        }
        try expectEqual("no request for empty model", recordings().count, 0)
    }

    static func testStreamFailurePreservesHeaderDiagnostics() async throws {
        var stub = streamStub(failedEvent(code: "subscription_sharing_usage_unavailable"))
        stub.headers["X-Request-ID"] = "req_stream_123"
        reset([stub])
        let error = try await captureError("stream diagnostics") { try await send() }
        try expectEqual("request ID preserved", error.requestID, "req_stream_123")
        try expectContains("request ID visible", error.localizedDescription, "req_stream_123")
        try expectContains("code visible", error.localizedDescription, "subscription_sharing_usage_unavailable")
        try expectDoesNotContain("raw message hidden", error.localizedDescription, "SECRET-RAW")
    }

    // MARK: - Runner

    static func main() async {
        let tests: [(name: String, body: () async throws -> Void)] = [
            ("sseWaitsForEventBoundary", testSSEWaitsForEventBoundary),
            ("sseBareCRAndByteChunkedUnicode", testSSEBareCRAndByteChunkedUnicode),
            ("modelValidationAndSystemRoleConversion", testModelValidationAndSystemRoleConversion),
            ("streamFailurePreservesHeaderDiagnostics", testStreamFailurePreservesHeaderDiagnostics),
            ("effortEnumExposesRawValuesAndLabels", testEffortEnumExposesRawValuesAndLabels),
            ("requestShapeAndSuccessfulCompletedText", testRequestShapeAndSuccessfulCompletedText),
            ("everyEffortLevelIsSentVerbatim", testEveryEffortLevelIsSentVerbatim),
            ("blankSystemPromptOmitsInstructions", testBlankSystemPromptOmitsInstructions),
            ("sseHandlesCRLFCommentsMultilineUnicodeAndTrailingEventWithoutBlank", testSSEHandlesCRLFCommentsMultilineUnicodeAndTrailingEventWithoutBlank),
            ("completedOutputIgnoresReasoningContent", testCompletedOutputIgnoresReasoningContent),
            ("completedOutputTextFieldWinsAndEmptyFieldFallsBackToOutput", testCompletedOutputTextFieldWinsAndEmptyFieldFallsBackToOutput),
            ("completedWithoutTerminalTextUsesAccumulatedDeltas", testCompletedWithoutTerminalTextUsesAccumulatedDeltas),
            ("doneAfterCompletedStillReturnsCompletedText", testDoneAfterCompletedStillReturnsCompletedText),
            ("failedAfterDeltaNeverReturnsPartialText", testFailedAfterDeltaNeverReturnsPartialText),
            ("failedWithoutErrorObjectStillThrows", testFailedWithoutErrorObjectStillThrows),
            ("incompleteAndErrorEventsThrow", testIncompleteAndErrorEventsThrow),
            ("completedWithNonCompletedStatusThrows", testCompletedWithNonCompletedStatusThrows),
            ("doneOnlyAndInterruptedStreamsThrow", testDoneOnlyAndInterruptedStreamsThrow),
            ("malformedTerminalEventAndEmptyCompletedThrow", testMalformedTerminalEventAndEmptyCompletedThrow),
            ("transportInterruptionThrowsTypedError", testTransportInterruptionThrowsTypedError),
            ("http401IsFriendlyAndKeepsSanitizedMetadata", testHTTP401IsFriendlyAndKeepsSanitizedMetadata),
            ("http403DetailBodyDoesNotLeak", testHTTP403DetailBodyDoesNotLeak),
            ("http429AndServerStatusesAreActionable", testHTTP429AndServerStatusesAreActionable),
            ("http400EffortParameterSuggestsAutomatic", testHTTP400EffortParameterSuggestsAutomatic),
            ("knownSubscriptionSharingCodesFromDocs", testKnownSubscriptionSharingCodesFromDocs),
            ("errorMetadataSanitization", testErrorMetadataSanitization),
            ("preStream401RefreshesOnceAndPreservesPayload", testPreStream401RefreshesOnceAndPreservesPayload),
            ("second401IsFinalAndDoesNotRefreshAgain", testSecond401IsFinalAndDoesNotRefreshAgain),
            ("non401HTTPFailuresAndStreamFailuresDoNotRefresh", testNon401HTTPFailuresAndStreamFailuresDoNotRefresh),
            ("refreshFailurePropagatesWithoutRetry", testRefreshFailurePropagatesWithoutRetry),
            ("emptyRefreshedTokenIsRejected", testEmptyRefreshedTokenIsRejected)
        ]

        var failures: [String] = []
        for test in tests {
            do {
                try await test.body()
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
