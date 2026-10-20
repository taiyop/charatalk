import Foundation

// Standalone regression harness for App/Services/GeminiInference.swift.
//
// Compiled together with the transport into a plain executable: no XCTest, no
// test target, and no real network access. `MockURLProtocol` serves every byte
// of every request, so no live API key is ever needed.

struct TestFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// URLProtocol stub for JSON request/response pairs.
final class MockURLProtocol: URLProtocol {
    struct Stub {
        var statusCode: Int
        var headers: [String: String]
        var chunks: [Data]
        var failure: URLError?
        var failureBeforeResponse: Bool

        init(
            statusCode: Int = 200,
            headers: [String: String] = ["Content-Type": "application/json"],
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

@main
struct GeminiInferenceTests {
    // MARK: - Fixtures

    static let apiKey = "AIzaSyTestKey-123_abc"
    static let model = "gemini-3.8-flash"
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

    static func jsonStub(_ body: String, status: Int = 200) -> MockURLProtocol.Stub {
        MockURLProtocol.Stub(
            statusCode: status,
            headers: ["Content-Type": "application/json"],
            chunks: [Data(body.utf8)]
        )
    }

    static func failureStub(_ code: URLError.Code) -> MockURLProtocol.Stub {
        MockURLProtocol.Stub(
            failure: URLError(code),
            failureBeforeResponse: true
        )
    }

    static func recordings() -> [MockURLProtocol.Recorded] {
        MockURLProtocol.state.recordings()
    }

    static func jsonString(_ object: Any) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    static func bodyJSON(_ recording: MockURLProtocol.Recorded) throws -> [String: Any] {
        guard let data = recording.body,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TestFailure(message: "recorded body was missing or not a JSON object")
        }
        return object
    }

    static func generationConfig(_ recording: MockURLProtocol.Recorded) throws -> [String: Any] {
        let body = try bodyJSON(recording)
        return try unwrap(body["generationConfig"] as? [String: Any], "generationConfig")
    }

    static func thinkingConfig(_ recording: MockURLProtocol.Recorded) throws -> [String: Any]? {
        try generationConfig(recording)["thinkingConfig"] as? [String: Any]
    }

    /// Builds a `generateContent` response envelope.
    static func responseBody(
        _ parts: [[String: Any]],
        finishReason: String? = "STOP",
        candidateExtras: [String: Any] = [:],
        rootExtras: [String: Any] = [:]
    ) -> String {
        var candidate: [String: Any] = [:]
        if !parts.isEmpty {
            candidate["content"] = ["parts": parts]
        }
        if let finishReason {
            candidate["finishReason"] = finishReason
        }
        candidate.merge(candidateExtras) { _, new in new }
        var root: [String: Any] = ["candidates": [candidate]]
        root.merge(rootExtras) { _, new in new }
        return jsonString(root)
    }

    static func textResponse(_ text: String) -> String {
        responseBody([["text": text]])
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

    static func expectNotNil<T>(_ label: String, _ actual: T?) throws {
        guard actual != nil else { throw TestFailure(message: "\(label): expected a value, got nil") }
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

    // MARK: - Invocation helpers

    @discardableResult
    static func send(
        apiKey: String = apiKey,
        model: String = model,
        systemPrompt: String = systemPrompt,
        messages: [[String: String]] = messages,
        temperature: Double = 0.7,
        effort: GeminiThinkingEffort = .automatic
    ) async throws -> String {
        try await GeminiInference.send(
            apiKey: apiKey,
            model: model,
            systemPrompt: systemPrompt,
            messages: messages,
            temperature: temperature,
            effort: effort,
            session: mockSession
        )
    }

    @discardableResult
    static func fetchModels(apiKey: String = apiKey) async throws -> [GeminiModel] {
        try await GeminiInference.fetchModels(apiKey: apiKey, session: mockSession)
    }

    static func captureError<T>(
        _ label: String,
        _ operation: () async throws -> T
    ) async throws -> GeminiInferenceError {
        do {
            let value = try await operation()
            throw TestFailure(message: "\(label): expected an error, got \(String(describing: value))")
        } catch let failure as TestFailure {
            throw failure
        } catch let error as GeminiInferenceError {
            return error
        } catch {
            throw TestFailure(message: "\(label): unexpected error \(error)")
        }
    }

    static func captureCancellation<T>(
        _ label: String,
        _ operation: () async throws -> T
    ) async throws {
        do {
            _ = try await operation()
            throw TestFailure(message: "\(label): expected CancellationError, got a value")
        } catch let failure as TestFailure {
            throw failure
        } catch is CancellationError {
            return
        } catch {
            throw TestFailure(message: "\(label): expected CancellationError, got \(error)")
        }
    }

    static func expectNoKeyLeak(_ label: String, _ text: String) throws {
        try expectDoesNotContain(label, text, apiKey)
        try expectDoesNotContain(label, text, "AIza")
    }

    // MARK: - Thinking effort

    static func testEffortEnumExposesRawValuesAndLabels() throws {
        try expectEqual(
            "case order",
            GeminiThinkingEffort.allCases.map(\.rawValue),
            ["", "minimal", "low", "medium", "high"]
        )
        try expectEqual("automatic raw value", GeminiThinkingEffort.automatic.rawValue, "")
        try expectEqual("automatic id", GeminiThinkingEffort.automatic.id, "automatic")
        try expectEqual("minimal id", GeminiThinkingEffort.minimal.id, "minimal")
        try expectEqual("high id", GeminiThinkingEffort.high.id, "high")

        let ids = GeminiThinkingEffort.allCases.map(\.id)
        try expectEqual("unique ids", Set(ids).count, ids.count)
        try expectTrue("ids non-empty", ids.allSatisfy { !$0.isEmpty })

        try expectContains("automatic label", GeminiThinkingEffort.automatic.displayName, "自動")
        for effort in GeminiThinkingEffort.allCases where effort != .automatic {
            try expectContains("label contains raw name", effort.displayName, effort.rawValue)
        }
    }

    static func testSupportedEffortMatrix() throws {
        let auto = GeminiThinkingEffort.automatic
        let minimal = GeminiThinkingEffort.minimal
        let low = GeminiThinkingEffort.low
        let medium = GeminiThinkingEffort.medium
        let high = GeminiThinkingEffort.high

        let cases: [(String, [GeminiThinkingEffort])] = [
            ("gemini-3.8-flash", [auto, low, medium, high]),
            ("models/gemini-3.8-flash", [auto, low, medium, high]),
            ("  gemini-3.8-flash \n", [auto, low, medium, high]),
            ("gemini-4-argon", [auto, low, medium, high]),
            ("gemini-3-pro-preview", [auto, low, high]),
            ("gemini-3-pro-preview-11-2025", [auto, low, high]),
            ("gemini-3.1-pro-preview", [auto, low, medium, high]),
            ("gemini-3-flash-preview", [auto, minimal, low, medium, high]),
            ("gemini-3.6-flash", [auto, minimal, low, medium, high]),
            ("gemini-3.5-flash-lite", [auto, minimal, low, medium, high]),
            ("gemini-2.5-pro", [auto, low, medium, high]),
            ("gemini-2.5-flash", [auto, low, medium, high]),
            ("gemini-2.5-flash-lite", [auto, low, medium, high]),
            ("gemini-2.0-flash", [auto]),
            ("gemini-2.0-flash-lite", [auto]),
            ("gemini-1.5-pro", [auto]),
            ("custom-model", [auto, low, medium, high]),
            ("gemini", [auto, low, medium, high])
        ]

        for (model, expected) in cases {
            try expectEqual("supported for \(model)", GeminiThinkingEffort.supported(for: model), expected)
        }
    }

    // MARK: - Request shape

    static func testRequestShapeForGemini3() async throws {
        reset([jsonStub(textResponse("やあ、元気？🌏"))])

        let result = try await send(effort: .low)
        try expectEqual("final text", result, "やあ、元気？🌏")

        let requests = recordings()
        try expectEqual("one request", requests.count, 1)
        let request = try unwrap(requests.first?.request, "recorded request")

        try expectEqual("POST", request.httpMethod, "POST")
        try expectEqual("thinking timeout", request.timeoutInterval, 180)
        try expectEqual("scheme", request.url?.scheme, "https")
        try expectEqual("host", request.url?.host, "generativelanguage.googleapis.com")
        try expectEqual(
            "path",
            request.url?.path,
            "/v1beta/models/gemini-3.8-flash:generateContent"
        )
        try expectNil("no query", request.url?.query)
        try expectEqual("api key header", request.value(forHTTPHeaderField: "x-goog-api-key"), apiKey)
        try expectNil("no authorization header", request.value(forHTTPHeaderField: "Authorization"))
        try expectEqual(
            "content type",
            request.value(forHTTPHeaderField: "Content-Type"),
            "application/json"
        )
        try expectEqual("accept", request.value(forHTTPHeaderField: "Accept"), "application/json")

        let urlString = try unwrap(request.url?.absoluteString, "url string")
        try expectNoKeyLeak("url has no key", urlString)

        let body = try bodyJSON(requests[0])
        try expectNil("no model field", body["model"])
        try expectNil("no stream field", body["stream"])
        try expectNil("no safety settings", body["safetySettings"])

        let contents = try unwrap(body["contents"] as? [[String: Any]], "contents")
        try expectEqual("one content", contents.count, 1)
        try expectEqual("user role", contents[0]["role"] as? String, "user")
        let parts = try unwrap(contents[0]["parts"] as? [[String: Any]], "parts")
        try expectEqual("one part", parts.count, 1)
        try expectEqual("part text", parts[0]["text"] as? String, messages[0]["content"])

        let systemInstruction = try unwrap(
            body["systemInstruction"] as? [String: Any],
            "systemInstruction"
        )
        try expectNil("system instruction has no role", systemInstruction["role"])
        let systemParts = try unwrap(
            systemInstruction["parts"] as? [[String: Any]],
            "system parts"
        )
        try expectEqual("system text", systemParts[0]["text"] as? String, systemPrompt)

        let config = try generationConfig(requests[0])
        try expectEqual("response mime type", config["responseMimeType"] as? String, "text/plain")
        try expectNil("temperature omitted for Gemini 3", config["temperature"])
        let thinking = try unwrap(config["thinkingConfig"] as? [String: Any], "thinkingConfig")
        try expectEqual("thinking level", thinking["thinkingLevel"] as? String, "low")
        try expectNil("no thinking budget", thinking["thinkingBudget"])
    }

    static func testModelNormalizationAndSlugValidation() async throws {
        reset([jsonStub(textResponse("ok"))])
        _ = try await send(model: " models/gemini-3.8-flash \n")
        let request = try unwrap(recordings().first?.request, "normalized request")
        try expectEqual(
            "models prefix stripped",
            request.url?.path,
            "/v1beta/models/gemini-3.8-flash:generateContent"
        )

        let invalids = [
            "",
            "   ",
            "models/",
            "gemini/3.8",
            "gemini 3.8",
            "gemini-3.8:generateContent",
            "models/../gemini",
            "gemini-３.８-flash",
            "gemini-3.8\nflash",
            "gemini-3.8-flash?alt=sse"
        ]
        for invalid in invalids {
            reset([jsonStub(textResponse("unused"))])
            let error = try await captureError("invalid model \(String(reflecting: invalid))") {
                try await send(model: invalid)
            }
            try expectEqual("kind for \(invalid)", error.kind, .invalidRequest)
            try expectNil("no status for \(invalid)", error.statusCode)
            try expectContains("actionable model error", error.localizedDescription, "モデル名")
            try expectEqual("no request for \(invalid)", recordings().count, 0)
        }
    }

    static func testAPIKeyValidation() async throws {
        let invalids = ["", "   ", "\n\t", "key with space", "key\nwith-newline", "キー"]
        for invalid in invalids {
            reset([jsonStub(textResponse("unused"))])
            let error = try await captureError("invalid key \(String(reflecting: invalid))") {
                try await send(apiKey: invalid)
            }
            try expectEqual("kind for key \(invalid)", error.kind, .invalidRequest)
            try expectContains("actionable key error", error.localizedDescription, "API キー")
            try expectEqual("no request for key \(invalid)", recordings().count, 0)
        }

        reset([jsonStub(textResponse("ok"))])
        _ = try await send(apiKey: "  \(apiKey)\n")
        let request = try unwrap(recordings().first?.request, "trimmed key request")
        try expectEqual("key trimmed", request.value(forHTTPHeaderField: "x-goog-api-key"), apiKey)
    }

    static func testMessageRoleConversionAndSystemMerging() async throws {
        reset([jsonStub(textResponse("ok"))])
        _ = try await send(
            systemPrompt: "BASE",
            messages: [
                ["role": "system", "content": "EXTRA-SYSTEM"],
                ["role": "user", "content": "hello"],
                ["role": "assistant", "content": "hi"],
                ["role": "model", "content": "model-content"],
                ["role": "user", "content": "bye"],
                ["role": "system", "content": "   "],
                ["role": "user", "content": "   "],
                ["role": "unknown", "content": "mystery"]
            ]
        )

        let body = try bodyJSON(try unwrap(recordings().first, "request"))
        let systemInstruction = try unwrap(
            body["systemInstruction"] as? [String: Any],
            "systemInstruction"
        )
        let systemParts = try unwrap(systemInstruction["parts"] as? [[String: Any]], "system parts")
        try expectEqual(
            "system prompt and system messages merged",
            systemParts[0]["text"] as? String,
            "BASE\n\nEXTRA-SYSTEM"
        )

        let contents = try unwrap(body["contents"] as? [[String: Any]], "contents")
        try expectEqual("blank user message skipped", contents.count, 5)
        let roles = contents.compactMap { $0["role"] as? String }
        try expectEqual("role mapping", roles, ["user", "model", "model", "user", "user"])

        let texts = try contents.map { item -> String in
            let parts = try unwrap(item["parts"] as? [[String: Any]], "content parts")
            return try unwrap(parts[0]["text"] as? String, "content text")
        }
        try expectEqual(
            "content order",
            texts,
            ["hello", "hi", "model-content", "bye", "mystery"]
        )
    }

    static func testBlankSystemPromptOmitsSystemInstruction() async throws {
        for prompt in ["", "   ", "\n\t  \n"] {
            reset([jsonStub(textResponse("ok"))])
            _ = try await send(systemPrompt: prompt)
            let body = try bodyJSON(try unwrap(recordings().first, "request for blank prompt"))
            try expectNil("systemInstruction omitted for \(String(reflecting: prompt))", body["systemInstruction"])
        }

        reset([jsonStub(textResponse("ok"))])
        _ = try await send(
            systemPrompt: "  ",
            messages: [
                ["role": "system", "content": "SYSTEM-ONLY"],
                ["role": "user", "content": "hello"]
            ]
        )
        let body = try bodyJSON(try unwrap(recordings().first, "request with system message"))
        let systemInstruction = try unwrap(
            body["systemInstruction"] as? [String: Any],
            "system message becomes systemInstruction"
        )
        let parts = try unwrap(systemInstruction["parts"] as? [[String: Any]], "system parts")
        try expectEqual("system message text", parts[0]["text"] as? String, "SYSTEM-ONLY")
    }

    static func testEmptyMessagesRejected() async throws {
        let cases: [(String, [[String: String]])] = [
            ("no messages", []),
            ("blank message", [["role": "user", "content": "   "]]),
            ("system only", [["role": "system", "content": "instruction"]]),
            ("blank system only", [["role": "system", "content": "\n"]])
        ]

        for (label, value) in cases {
            reset([jsonStub(textResponse("unused"))])
            let error = try await captureError("\(label)") {
                try await send(messages: value)
            }
            try expectEqual("kind for \(label)", error.kind, .invalidRequest)
            try expectContains("message for \(label)", error.localizedDescription, "メッセージ")
            try expectEqual("no request for \(label)", recordings().count, 0)
        }
    }

    // MARK: - Temperature

    static func testTemperatureOmittedForGemini3AndUnknown() async throws {
        let models = [
            "gemini-3.8-flash",
            "gemini-3.1-pro",
            "gemini-3-pro-preview",
            "gemini-4-argon",
            "custom-model"
        ]
        for model in models {
            reset([jsonStub(textResponse("ok"))])
            _ = try await send(model: model, temperature: 1.7)
            let config = try generationConfig(try unwrap(recordings().first, "request for \(model)"))
            try expectNil("temperature omitted for \(model)", config["temperature"])
        }
    }

    static func testTemperatureSentAndClampedForGemini25() async throws {
        reset([jsonStub(textResponse("ok"))])
        _ = try await send(model: "gemini-2.5-flash", temperature: 0.7)
        var config = try generationConfig(try unwrap(recordings().first, "2.5 request"))
        try expectEqual("2.5 temperature", config["temperature"] as? Double, 0.7)

        reset([jsonStub(textResponse("ok"))])
        _ = try await send(model: "gemini-2.0-flash", temperature: 0.2)
        config = try generationConfig(try unwrap(recordings().first, "2.0 request"))
        try expectEqual("2.0 temperature", config["temperature"] as? Double, 0.2)

        reset([jsonStub(textResponse("ok"))])
        _ = try await send(model: "gemini-2.5-pro", temperature: 5)
        config = try generationConfig(try unwrap(recordings().first, "clamped high"))
        try expectEqual("upper clamp", config["temperature"] as? Double, 2)

        reset([jsonStub(textResponse("ok"))])
        _ = try await send(model: "gemini-2.5-pro", temperature: -3)
        config = try generationConfig(try unwrap(recordings().first, "clamped low"))
        try expectEqual("lower clamp", config["temperature"] as? Double, 0)

        for value in [Double.infinity, -Double.infinity, Double.nan] {
            reset([jsonStub(textResponse("unused"))])
            let error = try await captureError("non-finite temperature") {
                try await send(model: "gemini-2.5-pro", temperature: value)
            }
            try expectEqual("kind for non-finite", error.kind, .invalidRequest)
            try expectContains("actionable temperature", error.localizedDescription, "温度")
            try expectEqual("no request for non-finite", recordings().count, 0)
        }
    }

    // MARK: - Thinking config

    static func testGemini25ThinkingBudgets() async throws {
        let cases: [(GeminiThinkingEffort, Int)] = [
            (.low, 1024),
            (.medium, 8192),
            (.high, 24576)
        ]
        for (effort, budget) in cases {
            reset([jsonStub(textResponse("ok"))])
            _ = try await send(model: "gemini-2.5-pro", effort: effort)
            let thinking = try unwrap(
                thinkingConfig(try unwrap(recordings().first, "2.5 request")),
                "thinkingConfig for \(effort.rawValue)"
            )
            try expectEqual("budget for \(effort.rawValue)", thinking["thinkingBudget"] as? Int, budget)
            try expectNil("no thinkingLevel for \(effort.rawValue)", thinking["thinkingLevel"])
        }

        reset([jsonStub(textResponse("ok"))])
        _ = try await send(model: "gemini-2.5-flash", effort: .automatic)
        let config = try generationConfig(try unwrap(recordings().first, "automatic request"))
        try expectNil("automatic omits thinkingConfig", config["thinkingConfig"])
        try expectNotNil("automatic keeps temperature", config["temperature"])
    }

    static func testGemini25MinimalRejected() async throws {
        for model in ["gemini-2.5-pro", "gemini-2.5-flash"] {
            reset([jsonStub(textResponse("unused"))])
            let error = try await captureError("2.5 minimal for \(model)") {
                try await send(model: model, effort: .minimal)
            }
            try expectEqual("kind", error.kind, .invalidRequest)
            try expectContains("mentions effort", error.localizedDescription, "minimal")
            try expectContains("mentions support", error.localizedDescription, "対応")
            try expectEqual("no request", recordings().count, 0)
        }
    }

    static func testGemini3ThinkingLevels() async throws {
        let cases: [(String, GeminiThinkingEffort)] = [
            ("gemini-3.8-flash", .low),
            ("gemini-3.8-flash", .medium),
            ("gemini-3.8-flash", .high),
            ("gemini-3.1-pro", .medium),
            ("gemini-3-flash-preview", .minimal),
            ("gemini-3.6-flash", .minimal),
            ("gemini-3.5-flash-lite", .minimal),
            ("gemini-4-argon", .high)
        ]

        for (model, effort) in cases {
            reset([jsonStub(textResponse("ok"))])
            _ = try await send(model: model, effort: effort)
            let thinking = try unwrap(
                thinkingConfig(try unwrap(recordings().first, "request for \(model)")),
                "thinkingConfig for \(model)"
            )
            try expectEqual(
                "thinking level for \(model) \(effort.rawValue)",
                thinking["thinkingLevel"] as? String,
                effort.rawValue
            )
            try expectNil(
                "no budget for \(model) \(effort.rawValue)",
                thinking["thinkingBudget"]
            )
        }
    }

    static func testUnsupportedEffortsRejectedBeforeNetworking() async throws {
        let cases: [(String, GeminiThinkingEffort)] = [
            ("gemini-3-pro-preview", .medium),
            ("gemini-3-pro-preview", .minimal),
            ("gemini-3.1-pro", .minimal),
            ("gemini-3.8-flash", .minimal),
            ("gemini-4-argon", .minimal),
            ("custom-model", .minimal),
            ("gemini-2.0-flash", .low),
            ("gemini-2.0-flash", .medium),
            ("gemini-2.0-flash", .high),
            ("gemini-1.5-pro", .low)
        ]

        for (model, effort) in cases {
            reset([jsonStub(textResponse("unused"))])
            let error = try await captureError("\(model) \(effort.rawValue)") {
                try await send(model: model, effort: effort)
            }
            try expectEqual("kind for \(model) \(effort.rawValue)", error.kind, .invalidRequest)
            try expectContains("mentions model", error.localizedDescription, model)
            try expectContains("mentions effort", error.localizedDescription, effort.rawValue)
            try expectContains("mentions automatic", error.localizedDescription, "自動")
            try expectEqual("no request for \(model) \(effort.rawValue)", recordings().count, 0)
        }
    }

    static func testLegacyModelAutomaticOnly() async throws {
        reset([jsonStub(textResponse("ok"))])
        _ = try await send(model: "gemini-2.0-flash", effort: .automatic)
        let config = try generationConfig(try unwrap(recordings().first, "legacy request"))
        try expectNil("legacy automatic omits thinkingConfig", config["thinkingConfig"])
        try expectNotNil("legacy temperature retained", config["temperature"])

        reset([jsonStub(textResponse("ok"))])
        _ = try await send(model: "gemini-1.5-pro", effort: .automatic)
        let config15 = try generationConfig(try unwrap(recordings().first, "1.5 request"))
        try expectNil("1.5 automatic omits thinkingConfig", config15["thinkingConfig"])
    }

    static func testUnknownModelEffortBehavior() async throws {
        for effort in [GeminiThinkingEffort.low, .medium, .high] {
            reset([jsonStub(textResponse("ok"))])
            _ = try await send(model: "custom-gemini-model", effort: effort)
            let thinking = try unwrap(
                thinkingConfig(try unwrap(recordings().first, "unknown request")),
                "unknown thinkingConfig"
            )
            try expectEqual(
                "unknown uses thinkingLevel",
                thinking["thinkingLevel"] as? String,
                effort.rawValue
            )
        }

        reset([jsonStub(textResponse("ok"))])
        _ = try await send(model: "custom-gemini-model", effort: .automatic)
        let config = try generationConfig(try unwrap(recordings().first, "unknown automatic"))
        try expectNil("unknown automatic omits thinkingConfig", config["thinkingConfig"])
    }

    // MARK: - Response parsing

    static func testSuccessJoinsPartsAndExcludesThoughts() async throws {
        reset([
            jsonStub(
                responseBody([
                    ["text": "こんにちは"],
                    ["thought": true, "text": "SECRET-THOUGHT"],
                    ["text": "、世界！"],
                    ["thought": false, "text": "🌏"]
                ])
            )
        ])

        let result = try await send()
        try expectEqual("joined parts", result, "こんにちは、世界！🌏")
        try expectDoesNotContain("thought excluded", result, "SECRET-THOUGHT")
    }

    static func testFirstCandidateOnlyAndWhitespaceTrimmed() async throws {
        reset([
            jsonStub(
                jsonString([
                    "candidates": [
                        [
                            "finishReason": "STOP",
                            "content": ["parts": [["text": "FIRST"]]]
                        ],
                        [
                            "finishReason": "STOP",
                            "content": ["parts": [["text": "SECOND"]]]
                        ]
                    ]
                ])
            )
        ])
        try expectEqual("first candidate wins", try await send(), "FIRST")

        reset([jsonStub(textResponse("  回答です。\n"))])
        try expectEqual("surrounding whitespace trimmed", try await send(), "回答です。")

        reset([jsonStub(responseBody([["text": "ok"]], finishReason: "stop"))])
        try expectEqual("lowercase finish reason accepted", try await send(), "ok")

        reset([jsonStub(responseBody([["text": "ok"]], finishReason: " STOP \n"))])
        try expectEqual("padded finish reason accepted", try await send(), "ok")
    }

    static func testPromptFeedbackBlocks() async throws {
        reset([
            jsonStub(
                jsonString([
                    "promptFeedback": [
                        "blockReason": "SAFETY",
                        "blockReasonMessage": "SECRET-BLOCK-MESSAGE"
                    ],
                    "candidates": [
                        [
                            "finishReason": "STOP",
                            "content": ["parts": [["text": "should not be returned"]]]
                        ]
                    ]
                ])
            )
        ])

        let error = try await captureError("prompt feedback block") { try await send() }
        try expectEqual("blocked kind", error.kind, .blocked)
        try expectEqual("block reason code", error.code, "SAFETY")
        try expectContains("actionable block message", error.localizedDescription, "ブロック")
        try expectDoesNotContain("raw block message hidden", error.localizedDescription, "SECRET-BLOCK-MESSAGE")
        try expectDoesNotContain("no text returned", error.localizedDescription, "should not be returned")

        reset([
            jsonStub(
                jsonString([
                    "promptFeedback": ["blockReason": "OTHER"]
                ])
            )
        ])
        let noCandidates = try await captureError("blocked without candidates") { try await send() }
        try expectEqual("blocked without candidates kind", noCandidates.kind, .blocked)
        try expectEqual("blocked code", noCandidates.code, "OTHER")
    }

    static func testFinishReasonErrors() async throws {
        let blockedReasons = ["SAFETY", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII", "RECITATION"]
        for reason in blockedReasons {
            reset([
                jsonStub(
                    responseBody(
                        [["text": "PARTIAL"]],
                        finishReason: reason,
                        candidateExtras: ["finishMessage": "SECRET-FINISH"]
                    )
                )
            ])
            let error = try await captureError("finish \(reason)") { try await send() }
            try expectEqual("kind for \(reason)", error.kind, .blocked)
            try expectEqual("code for \(reason)", error.code, reason)
            try expectContains("blocked message for \(reason)", error.localizedDescription, "ブロック")
            try expectDoesNotContain("finish message hidden for \(reason)", error.localizedDescription, "SECRET-FINISH")
            try expectDoesNotContain("partial hidden for \(reason)", error.localizedDescription, "PARTIAL")
        }

        let incompleteReasons = ["MAX_TOKENS", "OTHER", "MALFORMED_FUNCTION_CALL"]
        for reason in incompleteReasons {
            reset([jsonStub(responseBody([["text": "PARTIAL"]], finishReason: reason))])
            let error = try await captureError("finish \(reason)") { try await send() }
            try expectEqual("kind for \(reason)", error.kind, .incomplete)
            try expectEqual("code for \(reason)", error.code, reason)
            try expectDoesNotContain("partial hidden for \(reason)", error.localizedDescription, "PARTIAL")
        }

        reset([jsonStub(responseBody([["text": "ok"]], finishReason: nil))])
        let missing = try await captureError("missing finish reason") { try await send() }
        try expectEqual("missing finish kind", missing.kind, .invalidResponse)
        try expectDoesNotContain("missing finish no text", missing.localizedDescription, "ok")
    }

    static func testEmptyMalformedAndErrorEnvelopes() async throws {
        let malformedBodies = [
            "",
            "not json",
            #"{"candidates":"nope"}"#,
            #"{"candidates":[]}"#,
            #"{"candidates":[{}]}"#,
            #"{"candidates":[{"finishReason":"STOP"}]}"#,
            #"{"candidates":[{"finishReason":"STOP","content":{}}]}"#,
            #"{"candidates":[{"finishReason":"STOP","content":{"parts":[]}}]}"#,
            #"{"candidates":[{"finishReason":"STOP","content":{"parts":[{"thought":true,"text":"SECRET-THOUGHT"}]}}]}"#,
            #"{"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":"   "}]}}]}"#,
            #"{"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":42}]}}]}"#,
            #"{"error":{"status":"INVALID_ARGUMENT","message":"SECRET-200-ERROR"}}"#
        ]

        for body in malformedBodies {
            reset([jsonStub(body)])
            let error = try await captureError("malformed body \(body.prefix(40))") {
                try await send()
            }
            try expectEqual("kind for \(body.prefix(40))", error.kind, .invalidResponse)
            try expectNil("no status for \(body.prefix(40))", error.statusCode)
            try expectContains("safe Japanese", error.localizedDescription, "Gemini")
            try expectDoesNotContain("raw body hidden", error.localizedDescription, "SECRET")
        }
    }

    // MARK: - HTTP errors

    static func testHTTPErrorMapping() async throws {
        struct Case {
            let status: Int
            let body: String
            let expectedKind: GeminiInferenceError.Kind
            let expectedCode: String?
            let needle: String
        }

        let cases: [Case] = [
            Case(
                status: 400,
                body: #"{"error":{"code":400,"status":"INVALID_ARGUMENT","message":"SECRET-RAW"}}"#,
                expectedKind: .http,
                expectedCode: "INVALID_ARGUMENT",
                needle: "設定"
            ),
            Case(
                status: 400,
                body: #"{"error":{"status":"INVALID_ARGUMENT","details":[{"reason":"API_KEY_INVALID"}],"message":"SECRET-RAW"}}"#,
                expectedKind: .http,
                expectedCode: "API_KEY_INVALID",
                needle: "API キー"
            ),
            Case(
                status: 401,
                body: #"{"error":{"status":"UNAUTHENTICATED","message":"SECRET-AUTH"}}"#,
                expectedKind: .http,
                expectedCode: "UNAUTHENTICATED",
                needle: "API キー"
            ),
            Case(
                status: 403,
                body: #"{"error":{"status":"PERMISSION_DENIED","message":"SECRET-PERM"}}"#,
                expectedKind: .http,
                expectedCode: "PERMISSION_DENIED",
                needle: "許可"
            ),
            Case(
                status: 404,
                body: #"{"error":{"status":"NOT_FOUND","message":"SECRET-404"}}"#,
                expectedKind: .http,
                expectedCode: "NOT_FOUND",
                needle: "見つかりません"
            ),
            Case(
                status: 429,
                body: #"{"error":{"status":"RESOURCE_EXHAUSTED","message":"SECRET-429"}}"#,
                expectedKind: .http,
                expectedCode: "RESOURCE_EXHAUSTED",
                needle: "利用上限"
            ),
            Case(
                status: 500,
                body: "SECRET-500-BODY",
                expectedKind: .http,
                expectedCode: nil,
                needle: "時間をおいて"
            ),
            Case(
                status: 503,
                body: #"{"error":{"status":"UNAVAILABLE","message":"SECRET-503"}}"#,
                expectedKind: .http,
                expectedCode: "UNAVAILABLE",
                needle: "一時的"
            ),
            Case(
                status: 418,
                body: "SECRET-418-BODY",
                expectedKind: .http,
                expectedCode: nil,
                needle: "HTTP 418"
            )
        ]

        for entry in cases {
            reset([jsonStub(entry.body, status: entry.status)])
            let error = try await captureError("HTTP \(entry.status)") { try await send() }
            try expectEqual("kind for \(entry.status)", error.kind, entry.expectedKind)
            try expectEqual("status for \(entry.status)", error.statusCode, entry.status)
            try expectEqual("code for \(entry.status)", error.code, entry.expectedCode)
            try expectContains("message for \(entry.status)", error.localizedDescription, entry.needle)
            try expectContains("status visible", error.localizedDescription, "HTTP \(entry.status)")
            try expectDoesNotContain("raw body hidden", error.localizedDescription, "SECRET")
            try expectNoKeyLeak("key hidden for \(entry.status)", error.localizedDescription)
            if entry.status == 400, entry.expectedCode == "INVALID_ARGUMENT" {
                try expectContains("unsupported effort recovery", error.localizedDescription, "自動")
            }
        }
    }

    static func testErrorCodeSanitization() throws {
        let mixed = GeminiInferenceError.httpError(
            data: Data(#"{"error":{"status":"BAD STATUS SECRET","message":"SECRET-MESSAGE"}}"#.utf8),
            statusCode: 400
        )
        try expectNil("code with whitespace dropped", mixed.code)
        try expectDoesNotContain("message not leaked", mixed.localizedDescription, "SECRET")

        let long = GeminiInferenceError.httpError(
            data: Data(#"{"error":{"status":"\#(String(repeating: "a", count: 200))"}}"#.utf8),
            statusCode: 400
        )
        try expectNil("overlong code dropped", long.code)

        let valid = GeminiInferenceError.httpError(
            data: Data(#"{"error":{"status":"RESOURCE_EXHAUSTED"}}"#.utf8),
            statusCode: 429
        )
        try expectEqual("valid code retained", valid.code, "RESOURCE_EXHAUSTED")
        try expectEqual("status retained", valid.statusCode, 429)
        try expectNil("local error has no status", GeminiInferenceError(
            kind: .invalidRequest,
            message: "test"
        ).statusCode)
    }

    static func testHTTPErrorBodyNeverLeaksKey() async throws {
        let raw = jsonString([
            "error": [
                "status": "INTERNAL",
                "message": "server echoed \(apiKey) and SECRET-BODY"
            ]
        ])
        reset([jsonStub(raw, status: 500)])
        let error = try await captureError("key echo") { try await send() }
        try expectNoKeyLeak("key hidden", error.localizedDescription)
        try expectDoesNotContain("body hidden", error.localizedDescription, "SECRET-BODY")
    }

    // MARK: - Transport and cancellation

    static func testTransportErrorsAreSanitized() async throws {
        for code in [URLError.Code.cannotConnectToHost, .timedOut, .networkConnectionLost, .notConnectedToInternet] {
            reset([failureStub(code)])
            let error = try await captureError("transport \(code)") { try await send() }
            try expectEqual("kind for \(code)", error.kind, .transport)
            try expectNil("no status for \(code)", error.statusCode)
            try expectNil("no code for \(code)", error.code)
            try expectContains("network guidance", error.localizedDescription, "ネットワーク")
            try expectNoKeyLeak("key hidden for \(code)", error.localizedDescription)
        }

        reset([failureStub(.cannotConnectToHost)])
        let fetchError = try await captureError("fetch transport") { try await fetchModels() }
        try expectEqual("fetch transport kind", fetchError.kind, .transport)
        try expectNoKeyLeak("fetch key hidden", fetchError.localizedDescription)
    }

    static func testCancellationIsPreserved() async throws {
        reset([failureStub(.cancelled)])
        try await captureCancellation("send cancellation") { try await send() }

        reset([failureStub(.cancelled)])
        try await captureCancellation("fetch cancellation") { try await fetchModels() }
    }

    // MARK: - Model catalog

    static func testFetchModelsRequestAndFiltering() async throws {
        let body = jsonString([
            "models": [
                [
                    "name": "models/gemini-3.8-flash",
                    "displayName": "Gemini 3.8 Flash",
                    "supportedGenerationMethods": ["generateContent", "countTokens"]
                ],
                [
                    "name": "models/gemini-2.5-pro",
                    "displayName": "Gemini 2.5 Pro",
                    "supportedGenerationMethods": ["generateContent"]
                ],
                [
                    "name": "models/gemini-2.5-flash-image",
                    "displayName": "Image",
                    "supportedGenerationMethods": ["generateContent"]
                ],
                [
                    "name": "models/gemini-2.5-flash-preview-tts",
                    "displayName": "TTS",
                    "supportedGenerationMethods": ["generateContent"]
                ],
                [
                    "name": "models/gemini-2.5-flash-native-audio",
                    "displayName": "Audio",
                    "supportedGenerationMethods": ["generateContent"]
                ],
                [
                    "name": "models/gemini-live-2.5-flash",
                    "displayName": "Live",
                    "supportedGenerationMethods": ["generateContent"]
                ],
                [
                    "name": "models/gemini-robotics-er-1.5-preview",
                    "displayName": "Robotics",
                    "supportedGenerationMethods": ["generateContent"]
                ],
                [
                    "name": "models/gemini-embedding-001",
                    "displayName": "Embedding",
                    "supportedGenerationMethods": ["embed"]
                ],
                [
                    "name": "models/gemini-2.5-flash",
                    "displayName": "Gemini 2.5 Flash",
                    "supportedGenerationMethods": ["countTokens"]
                ],
                [
                    "name": "models/gemini-2.5-flash-lite",
                    "supportedGenerationMethods": ["generateContent"]
                ],
                [
                    "name": "models/gemini-2.5-pro",
                    "displayName": "Duplicate",
                    "supportedGenerationMethods": ["generateContent"]
                ],
                [
                    "name": "bad name",
                    "displayName": "Bad",
                    "supportedGenerationMethods": ["generateContent"]
                ]
            ]
        ])

        reset([jsonStub(body)])
        let models = try await fetchModels()

        try expectEqual("model count", models.count, 3)
        try expectEqual(
            "model ids",
            models.map(\.id),
            ["gemini-3.8-flash", "gemini-2.5-pro", "gemini-2.5-flash-lite"]
        )
        try expectEqual(
            "display names",
            models.map(\.displayName),
            ["Gemini 3.8 Flash", "Gemini 2.5 Pro", "gemini-2.5-flash-lite"]
        )

        let requests = recordings()
        try expectEqual("one list request", requests.count, 1)
        let request = try unwrap(requests.first?.request, "list request")
        try expectEqual("GET", request.httpMethod, "GET")
        try expectEqual("scheme", request.url?.scheme, "https")
        try expectEqual("host", request.url?.host, "generativelanguage.googleapis.com")
        try expectEqual("path", request.url?.path, "/v1beta/models")
        try expectEqual("api key header", request.value(forHTTPHeaderField: "x-goog-api-key"), apiKey)
        try expectNil("no authorization", request.value(forHTTPHeaderField: "Authorization"))

        let components = try unwrap(
            request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) },
            "list URL components"
        )
        let query = components.queryItems ?? []
        try expectEqual("page size", query.first(where: { $0.name == "pageSize" })?.value, "1000")
        try expectNil("no page token on first page", query.first(where: { $0.name == "pageToken" }))
        try expectNil("key not in query", query.first(where: { $0.name == "key" }))
        try expectNil("api key not in query", query.first(where: { $0.name == "apiKey" }))
        try expectNoKeyLeak("key not in URL", try unwrap(request.url?.absoluteString, "list URL string"))
    }

    static func testFetchModelsDisplayNameHandling() async throws {
        let body = jsonString([
            "models": [
                [
                    "name": "models/gemini-3.8-flash",
                    "displayName": "   ",
                    "supportedGenerationMethods": ["generateContent"]
                ],
                [
                    "name": "models/gemini-3.6-flash",
                    "displayName": "  Gemini 3.6 Flash  ",
                    "supportedGenerationMethods": ["generateContent"]
                ],
                [
                    "name": "models/gemini-3.5-flash-lite",
                    "supportedGenerationMethods": ["generateContent"]
                ]
            ]
        ])

        reset([jsonStub(body)])
        let models = try await fetchModels()
        try expectEqual("blank display name falls back", models[0].displayName, "gemini-3.8-flash")
        try expectEqual("display name trimmed", models[1].displayName, "Gemini 3.6 Flash")
        try expectEqual("missing display name falls back", models[2].displayName, "gemini-3.5-flash-lite")
    }

    static func testFetchModelsPaginationPreservesOrderAndDeduplicates() async throws {
        let first = jsonString([
            "models": [
                [
                    "name": "models/gemini-3.8-flash",
                    "displayName": "Gemini 3.8 Flash",
                    "supportedGenerationMethods": ["generateContent"]
                ],
                [
                    "name": "models/gemini-2.5-pro",
                    "displayName": "Gemini 2.5 Pro",
                    "supportedGenerationMethods": ["generateContent"]
                ]
            ],
            "nextPageToken": "tok-A"
        ])
        let second = jsonString([
            "models": [
                [
                    "name": "models/gemini-2.5-pro",
                    "displayName": "Duplicate",
                    "supportedGenerationMethods": ["generateContent"]
                ],
                [
                    "name": "models/gemini-2.5-flash",
                    "displayName": "Gemini 2.5 Flash",
                    "supportedGenerationMethods": ["generateContent"]
                ]
            ]
        ])

        reset([jsonStub(first), jsonStub(second)])
        let models = try await fetchModels()
        try expectEqual(
            "paginated ids",
            models.map(\.id),
            ["gemini-3.8-flash", "gemini-2.5-pro", "gemini-2.5-flash"]
        )
        try expectEqual("paginated display names", models[2].displayName, "Gemini 2.5 Flash")

        let requests = recordings()
        try expectEqual("two requests", requests.count, 2)
        let secondRequest = try unwrap(requests.last?.request, "second request")
        let components = try unwrap(
            secondRequest.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) },
            "second URL components"
        )
        let query = components.queryItems ?? []
        try expectEqual("token forwarded", query.first(where: { $0.name == "pageToken" })?.value, "tok-A")
        try expectEqual("page size retained", query.first(where: { $0.name == "pageSize" })?.value, "1000")
        try expectEqual(
            "key retained on page two",
            secondRequest.value(forHTTPHeaderField: "x-goog-api-key"),
            apiKey
        )
    }

    static func testFetchModelsStopsOnTokenCycle() async throws {
        reset([
            jsonStub(jsonString([
                "models": [["name": "models/a-model", "supportedGenerationMethods": ["generateContent"]]],
                "nextPageToken": "A"
            ])),
            jsonStub(jsonString([
                "models": [["name": "models/b-model", "supportedGenerationMethods": ["generateContent"]]],
                "nextPageToken": "A"
            ]))
        ])

        let selfCycle = try await fetchModels()
        try expectEqual("self cycle models", selfCycle.map(\.id), ["a-model", "b-model"])
        try expectEqual("self cycle stops", recordings().count, 2)

        reset([
            jsonStub(jsonString([
                "models": [["name": "models/a-model", "supportedGenerationMethods": ["generateContent"]]],
                "nextPageToken": "A"
            ])),
            jsonStub(jsonString([
                "models": [["name": "models/b-model", "supportedGenerationMethods": ["generateContent"]]],
                "nextPageToken": "B"
            ])),
            jsonStub(jsonString([
                "models": [["name": "models/c-model", "supportedGenerationMethods": ["generateContent"]]],
                "nextPageToken": "A"
            ]))
        ])

        let twoCycle = try await fetchModels()
        try expectEqual("two-token cycle models", twoCycle.map(\.id), ["a-model", "b-model", "c-model"])
        try expectEqual("two-token cycle stops", recordings().count, 3)
    }

    static func testFetchModelsErrorsAreActionable() async throws {
        struct Case {
            let status: Int
            let body: String
            let needle: String
        }

        let cases: [Case] = [
            Case(
                status: 401,
                body: #"{"error":{"status":"UNAUTHENTICATED","details":[{"reason":"API_KEY_INVALID"}],"message":"SECRET-401"}}"#,
                needle: "API キー"
            ),
            Case(
                status: 403,
                body: #"{"error":{"status":"PERMISSION_DENIED","message":"SECRET-403"}}"#,
                needle: "API キー"
            ),
            Case(
                status: 429,
                body: #"{"error":{"status":"RESOURCE_EXHAUSTED","message":"SECRET-429"}}"#,
                needle: "しばらく"
            ),
            Case(status: 500, body: "SECRET-500", needle: "一時的"),
            Case(status: 418, body: "SECRET-418", needle: "HTTP 418")
        ]

        for entry in cases {
            reset([jsonStub(entry.body, status: entry.status)])
            let error = try await captureError("fetch HTTP \(entry.status)") { try await fetchModels() }
            try expectEqual("fetch kind for \(entry.status)", error.kind, .http)
            try expectEqual("fetch status for \(entry.status)", error.statusCode, entry.status)
            try expectContains("fetch message for \(entry.status)", error.localizedDescription, entry.needle)
            try expectDoesNotContain("fetch body hidden", error.localizedDescription, "SECRET")
            try expectNoKeyLeak("fetch key hidden", error.localizedDescription)
        }

        for body in ["", "not json", #"{"models":"nope"}"#] {
            reset([jsonStub(body)])
            let error = try await captureError("fetch malformed \(body.prefix(20))") {
                try await fetchModels()
            }
            try expectEqual("fetch malformed kind", error.kind, .invalidResponse)
            try expectContains("fetch malformed message", error.localizedDescription, "モデル一覧")
            try expectDoesNotContain("fetch raw hidden", error.localizedDescription, "nope")
        }
    }

    static func testFetchModelsEmptyCatalogAndEmptyKey() async throws {
        reset([jsonStub(#"{"models":[]}"#)])
        let empty = try await fetchModels()
        try expectTrue("empty catalog", empty.isEmpty)

        reset([jsonStub("{}")])
        let missing = try await fetchModels()
        try expectTrue("missing models is empty", missing.isEmpty)

        reset([jsonStub("{}")])
        let error = try await captureError("empty key fetch") { try await fetchModels(apiKey: "   ") }
        try expectEqual("empty key kind", error.kind, .invalidRequest)
        try expectEqual("no fetch request", recordings().count, 0)

        reset([jsonStub("{}")])
        let invalidKey = try await captureError("unicode key fetch") { try await fetchModels(apiKey: "キー") }
        try expectEqual("unicode key kind", invalidKey.kind, .invalidRequest)
        try expectEqual("no request for unicode key", recordings().count, 0)
    }

    // MARK: - Runner

    static func main() async {
        let tests: [(name: String, body: () async throws -> Void)] = [
            ("effortEnumExposesRawValuesAndLabels", testEffortEnumExposesRawValuesAndLabels),
            ("supportedEffortMatrix", testSupportedEffortMatrix),
            ("requestShapeForGemini3", testRequestShapeForGemini3),
            ("modelNormalizationAndSlugValidation", testModelNormalizationAndSlugValidation),
            ("apiKeyValidation", testAPIKeyValidation),
            ("messageRoleConversionAndSystemMerging", testMessageRoleConversionAndSystemMerging),
            ("blankSystemPromptOmitsSystemInstruction", testBlankSystemPromptOmitsSystemInstruction),
            ("emptyMessagesRejected", testEmptyMessagesRejected),
            ("temperatureOmittedForGemini3AndUnknown", testTemperatureOmittedForGemini3AndUnknown),
            ("temperatureSentAndClampedForGemini25", testTemperatureSentAndClampedForGemini25),
            ("gemini25ThinkingBudgets", testGemini25ThinkingBudgets),
            ("gemini25MinimalRejected", testGemini25MinimalRejected),
            ("gemini3ThinkingLevels", testGemini3ThinkingLevels),
            ("unsupportedEffortsRejectedBeforeNetworking", testUnsupportedEffortsRejectedBeforeNetworking),
            ("legacyModelAutomaticOnly", testLegacyModelAutomaticOnly),
            ("unknownModelEffortBehavior", testUnknownModelEffortBehavior),
            ("successJoinsPartsAndExcludesThoughts", testSuccessJoinsPartsAndExcludesThoughts),
            ("firstCandidateOnlyAndWhitespaceTrimmed", testFirstCandidateOnlyAndWhitespaceTrimmed),
            ("promptFeedbackBlocks", testPromptFeedbackBlocks),
            ("finishReasonErrors", testFinishReasonErrors),
            ("emptyMalformedAndErrorEnvelopes", testEmptyMalformedAndErrorEnvelopes),
            ("httpErrorMapping", testHTTPErrorMapping),
            ("errorCodeSanitization", testErrorCodeSanitization),
            ("httpErrorBodyNeverLeaksKey", testHTTPErrorBodyNeverLeaksKey),
            ("transportErrorsAreSanitized", testTransportErrorsAreSanitized),
            ("cancellationIsPreserved", testCancellationIsPreserved),
            ("fetchModelsRequestAndFiltering", testFetchModelsRequestAndFiltering),
            ("fetchModelsDisplayNameHandling", testFetchModelsDisplayNameHandling),
            ("fetchModelsPaginationPreservesOrderAndDeduplicates", testFetchModelsPaginationPreservesOrderAndDeduplicates),
            ("fetchModelsStopsOnTokenCycle", testFetchModelsStopsOnTokenCycle),
            ("fetchModelsErrorsAreActionable", testFetchModelsErrorsAreActionable),
            ("fetchModelsEmptyCatalogAndEmptyKey", testFetchModelsEmptyCatalogAndEmptyKey)
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
