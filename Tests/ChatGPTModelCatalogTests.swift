import Foundation

// Standalone regression harness for App/Models/ChatGPTModel.swift.
//
// Compiled together with the catalog source into a plain executable: no XCTest,
// no test target, no real authentication, and no real network access. Checks
// throw on failure instead of relying on `assert`, so they stay active in
// release builds.

struct TestFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// Minimal URLProtocol stub. It records the outgoing request and returns a
/// canned HTTP response (or transport error) so `fetch` never touches the
/// network.
final class MockURLProtocol: URLProtocol {
    struct Stub {
        var statusCode: Int
        var body: Data
        var error: URLError?
    }

    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var stub = Stub(statusCode: 200, body: Data(), error: nil)
        private var recorded: [URLRequest] = []

        func set(_ newStub: Stub) {
            lock.lock()
            defer { lock.unlock() }
            stub = newStub
            recorded.removeAll()
        }

        func record(_ request: URLRequest) {
            lock.lock()
            defer { lock.unlock() }
            recorded.append(request)
        }

        func currentStub() -> Stub {
            lock.lock()
            defer { lock.unlock() }
            return stub
        }

        func requests() -> [URLRequest] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }
    }

    static let state = State()

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let stub = Self.state.currentStub()
        Self.state.record(request)

        if let error = stub.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }

        guard let response = HTTPURLResponse(
            url: url,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !stub.body.isEmpty {
            client?.urlProtocol(self, didLoad: stub.body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@main
struct ChatGPTModelCatalogTests {
    // MARK: - Fixtures

    static let oauthToken = "oauth-token-123"

    static let mockSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }()

    static func data(_ json: String) -> Data {
        Data(json.utf8)
    }

    static func stub(status: Int, json: String, error: URLError? = nil) {
        MockURLProtocol.state.set(
            MockURLProtocol.Stub(statusCode: status, body: data(json), error: error)
        )
    }

    static func models(_ entries: [(slug: String, displayName: String)]) -> [ChatGPTModel] {
        entries.map { ChatGPTModel(slug: $0.slug, displayName: $0.displayName) }
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

    static func expectInvalidResponse(_ label: String, json: String) throws {
        do {
            let decoded = try ChatGPTModelCatalog.decode(data(json))
            throw TestFailure(message: "\(label): expected invalidResponse, got \(decoded)")
        } catch let failure as TestFailure {
            throw failure
        } catch let error as ChatGPTModelCatalogError {
            try expectEqual(label, error, .invalidResponse)
        } catch {
            throw TestFailure(message: "\(label): unexpected error \(error)")
        }
    }

    static func fetchError(
        _ label: String,
        token: String = oauthToken,
        session: URLSession = mockSession
    ) async throws -> ChatGPTModelCatalogError {
        do {
            let fetched = try await ChatGPTModelCatalog.fetch(accessToken: token, session: session)
            throw TestFailure(message: "\(label): expected an error, got \(fetched)")
        } catch let failure as TestFailure {
            throw failure
        } catch let error as ChatGPTModelCatalogError {
            return error
        } catch {
            throw TestFailure(message: "\(label): unexpected error \(error)")
        }
    }

    // MARK: - Decoding

    static func testDecodeKeepsOnlyListVisibilityInServerOrder() throws {
        let json = """
        {
          "models": [
            {"slug": "gpt-alpha", "display_name": "Alpha", "visibility": "list",
             "metadata": {"tier": "preview"}},
            {"slug": "gpt-hidden", "display_name": "Hidden", "visibility": "hidden"},
            {"slug": "gpt-unlisted", "display_name": "Unlisted", "visibility": "unlisted"},
            {"slug": "gpt-missing", "display_name": "Missing visibility"},
            {"slug": "gpt-beta", "display_name": "Beta", "visibility": "list"}
          ],
          "object": "catalog",
          "request_id": "req-123"
        }
        """

        let decoded = try ChatGPTModelCatalog.decode(data(json))
        try expectEqual(
            "filtered order and names",
            decoded,
            models([("gpt-alpha", "Alpha"), ("gpt-beta", "Beta")])
        )
        try expectEqual("id equals slug", decoded.first?.id, "gpt-alpha")
    }

    static func testDecodeFallsBackToSlugForMissingOrEmptyDisplayName() throws {
        let json = """
        {
          "models": [
            {"slug": "gpt-no-name", "visibility": "list"},
            {"slug": "gpt-empty-name", "display_name": "", "visibility": "list"},
            {"slug": "gpt-blank-name", "display_name": "   ", "visibility": "list"},
            {"slug": "gpt-null-name", "display_name": null, "visibility": "list"},
            {"slug": "gpt-named", "display_name": "Named Model", "visibility": "list"}
          ]
        }
        """

        let decoded = try ChatGPTModelCatalog.decode(data(json))
        try expectEqual(
            "display name fallbacks",
            decoded,
            models([
                ("gpt-no-name", "gpt-no-name"),
                ("gpt-empty-name", "gpt-empty-name"),
                ("gpt-blank-name", "gpt-blank-name"),
                ("gpt-null-name", "gpt-null-name"),
                ("gpt-named", "Named Model")
            ])
        )
    }

    static func testDecodeSkipsEmptySlugsAndDuplicatesPreservingFirst() throws {
        let json = """
        {
          "models": [
            {"slug": "gpt-a", "display_name": "A first", "visibility": "list"},
            {"slug": "", "display_name": "Empty", "visibility": "list"},
            {"slug": "   ", "display_name": "Blank", "visibility": "list"},
            {"display_name": "No slug", "visibility": "list"},
            {"slug": "gpt-a", "display_name": "A second", "visibility": "list"},
            {"slug": "gpt-b", "display_name": "B", "visibility": "list"},
            {"slug": "gpt-b", "display_name": "B duplicate", "visibility": "list"}
          ]
        }
        """

        let decoded = try ChatGPTModelCatalog.decode(data(json))
        try expectEqual(
            "empty and duplicate slugs removed",
            decoded,
            models([("gpt-a", "A first"), ("gpt-b", "B")])
        )
    }

    static func testDecodeSupportsEmptyCatalogAndCustomServerSlugs() throws {
        try expectEqual("empty models", try ChatGPTModelCatalog.decode(data(#"{"models": []}"#)), [])

        let custom = """
        {"models": [
          {"slug": "account-specific-preview", "display_name": "Account Preview", "visibility": "list"}
        ]}
        """
        try expectEqual(
            "custom slug only",
            try ChatGPTModelCatalog.decode(data(custom)),
            models([("account-specific-preview", "Account Preview")])
        )
    }

    static func testDecodeRejectsAPIKeyDataEnvelope() throws {
        let apiKeyShape = """
        {
          "object": "list",
          "data": [
            {"id": "gpt-4o", "object": "model", "owned_by": "system"}
          ]
        }
        """
        try expectInvalidResponse("API-key data envelope", json: apiKeyShape)
    }

    static func testDecodeRejectsMalformedEnvelopes() throws {
        let malformed = [
            ("invalid json", "{\"models\": [}"),
            ("missing models key", #"{"object": "list"}"#),
            ("models is an object", #"{"models": {}}"#),
            ("models is a string", #"{"models": "gpt-4o"}"#),
            ("top-level array", #"[{"slug": "gpt-4o", "visibility": "list"}]"#),
            ("entry is not an object", #"{"models": [42]}"#),
            ("slug is not a string", #"{"models": [{"slug": 1, "visibility": "list"}]}"#),
            ("visibility is not a string", #"{"models": [{"slug": "gpt-4o", "visibility": 1}]}"#)
        ]

        for (label, json) in malformed {
            try expectInvalidResponse(label, json: json)
        }
    }

    // MARK: - Selection

    static func testSelectionKeepsExactValidPreferred() throws {
        let catalog = models([
            ("gpt-first", "First"),
            ("gpt-second", "Second")
        ])

        try expectEqual(
            "existing preferred retained",
            ChatGPTModelCatalog.selectedSlug(preferred: "gpt-second", models: catalog),
            "gpt-second"
        )
        try expectEqual(
            "preferred trimmed before matching",
            ChatGPTModelCatalog.selectedSlug(preferred: "  gpt-second\n", models: catalog),
            "gpt-second"
        )
        try expectEqual(
            "blank preferred falls back to first",
            ChatGPTModelCatalog.selectedSlug(preferred: " \t ", models: catalog),
            "gpt-first"
        )
    }

    static func testSelectionFallsBackToFirstServerModelWithoutHardcodedDefault() throws {
        let catalog = models([
            ("custom-one", "Custom One"),
            ("custom-two", "Custom Two")
        ])

        try expectEqual(
            "stale old model replaced by first server model",
            ChatGPTModelCatalog.selectedSlug(preferred: "gpt-4o-mini", models: catalog),
            "custom-one"
        )
        try expectEqual(
            "matching is case-sensitive",
            ChatGPTModelCatalog.selectedSlug(preferred: "CUSTOM-ONE", models: catalog),
            "custom-one"
        )
        try expectNil(
            "empty catalog has no fallback",
            ChatGPTModelCatalog.selectedSlug(preferred: "gpt-4o-mini", models: [])
        )
    }

    // MARK: - Fetch

    static func testFetchRequestsModelsEndpointWithBearerToken() async throws {
        let json = """
        {"models": [
          {"slug": "gpt-alpha", "display_name": "Alpha", "visibility": "list"},
          {"slug": "gpt-hidden", "display_name": "Hidden", "visibility": "hidden"},
          {"slug": "gpt-beta", "display_name": "Beta", "visibility": "list"}
        ]}
        """
        stub(status: 200, json: json)

        let decoded = try await ChatGPTModelCatalog.fetch(accessToken: oauthToken, session: mockSession)
        try expectEqual(
            "fetched models",
            decoded,
            models([("gpt-alpha", "Alpha"), ("gpt-beta", "Beta")])
        )

        let requests = MockURLProtocol.state.requests()
        try expectEqual("one request", requests.count, 1)
        let request = try unwrap(requests.first, "recorded request")

        try expectEqual("GET method", request.httpMethod, "GET")
        try expectEqual("refresh bypasses local cache", request.cachePolicy, .reloadIgnoringLocalCacheData)
        try expectEqual("scheme", request.url?.scheme, "https")
        try expectEqual("host", request.url?.host, "api.openai.com")
        try expectEqual("path", request.url?.path, "/v1/models")
        try expectNil("no query", request.url?.query)
        try expectEqual(
            "bearer token",
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer \(oauthToken)"
        )
        try expectEqual(
            "accept json",
            request.value(forHTTPHeaderField: "Accept"),
            "application/json"
        )
    }

    static func testFetchSupportsEmptyCatalog() async throws {
        stub(status: 200, json: #"{"models": []}"#)

        let decoded = try await ChatGPTModelCatalog.fetch(accessToken: oauthToken, session: mockSession)
        try expectEqual("empty catalog", decoded, [])
        try expectEqual("request still made", MockURLProtocol.state.requests().count, 1)
    }

    static func testFetchMapsAuthenticationAndRateLimitErrors() async throws {
        let cases: [(status: Int, expected: ChatGPTModelCatalogError, hint: String)] = [
            (401, .unauthorized, "サインイン"),
            (403, .forbidden, "権限"),
            (429, .rateLimited, "しばらく")
        ]

        for testCase in cases {
            let secret = "SECRET-\(testCase.status)-RESPONSE"
            stub(
                status: testCase.status,
                json: #"{"error": {"message": "\#(secret)", "type": "test_error"}}"#
            )

            let error = try await fetchError("status \(testCase.status)")
            try expectEqual("status \(testCase.status) mapping", error, testCase.expected)

            let message = error.localizedDescription
            try expectContains("status \(testCase.status) hint", message, testCase.hint)
            try expectDoesNotContain("status \(testCase.status) body leak", message, secret)
            try expectDoesNotContain("status \(testCase.status) raw error type leak", message, "test_error")
        }
    }

    static func testFetchMapsServerErrors() async throws {
        for status in [500, 503] {
            let secret = "SECRET-\(status)-BODY"
            stub(status: status, json: #"{"error": {"message": "\#(secret)"}}"#)

            let error = try await fetchError("server \(status)")
            try expectEqual("server \(status) mapping", error, .server(statusCode: status))

            let message = error.localizedDescription
            try expectContains("server \(status) status", message, "HTTP \(status)")
            try expectContains("server \(status) hint", message, "時間をおいて")
            try expectDoesNotContain("server \(status) body leak", message, secret)
        }
    }

    static func testFetchMapsUnexpectedStatusAndMalformedSuccess() async throws {
        let secret = "SECRET-404-BODY"
        stub(status: 404, json: #"{"error": {"message": "\#(secret)"}}"#)

        let notFound = try await fetchError("unexpected 404")
        try expectEqual("unexpected status mapping", notFound, .unexpectedStatus(statusCode: 404))
        try expectContains("unexpected status message", notFound.localizedDescription, "HTTP 404")
        try expectDoesNotContain("unexpected status body leak", notFound.localizedDescription, secret)

        let malformedSecret = "SECRET-API-KEY-SHAPE"
        stub(status: 200, json: #"{"object": "list", "data": [{"id": "\#(malformedSecret)"}]}"#)
        let malformed = try await fetchError("malformed success")
        try expectEqual("malformed success mapping", malformed, .invalidResponse)
        try expectDoesNotContain("malformed success body leak", malformed.localizedDescription, malformedSecret)
    }

    static func testFetchPropagatesTransportErrors() async throws {
        MockURLProtocol.state.set(
            MockURLProtocol.Stub(
                statusCode: 200,
                body: Data(),
                error: URLError(.timedOut)
            )
        )

        do {
            let fetched = try await ChatGPTModelCatalog.fetch(accessToken: oauthToken, session: mockSession)
            throw TestFailure(message: "transport error: expected URLError, got \(fetched)")
        } catch let failure as TestFailure {
            throw failure
        } catch let error as URLError {
            try expectEqual("transport error code", error.code, .timedOut)
        } catch {
            throw TestFailure(message: "transport error: unexpected error \(error)")
        }
    }

    // MARK: - Runner

    static func main() async {
        let tests: [(name: String, body: () async throws -> Void)] = [
            ("decodeKeepsOnlyListVisibilityInServerOrder", testDecodeKeepsOnlyListVisibilityInServerOrder),
            ("decodeFallsBackToSlugForMissingOrEmptyDisplayName", testDecodeFallsBackToSlugForMissingOrEmptyDisplayName),
            ("decodeSkipsEmptySlugsAndDuplicatesPreservingFirst", testDecodeSkipsEmptySlugsAndDuplicatesPreservingFirst),
            ("decodeSupportsEmptyCatalogAndCustomServerSlugs", testDecodeSupportsEmptyCatalogAndCustomServerSlugs),
            ("decodeRejectsAPIKeyDataEnvelope", testDecodeRejectsAPIKeyDataEnvelope),
            ("decodeRejectsMalformedEnvelopes", testDecodeRejectsMalformedEnvelopes),
            ("selectionKeepsExactValidPreferred", testSelectionKeepsExactValidPreferred),
            ("selectionFallsBackToFirstServerModelWithoutHardcodedDefault", testSelectionFallsBackToFirstServerModelWithoutHardcodedDefault),
            ("fetchRequestsModelsEndpointWithBearerToken", testFetchRequestsModelsEndpointWithBearerToken),
            ("fetchSupportsEmptyCatalog", testFetchSupportsEmptyCatalog),
            ("fetchMapsAuthenticationAndRateLimitErrors", testFetchMapsAuthenticationAndRateLimitErrors),
            ("fetchMapsServerErrors", testFetchMapsServerErrors),
            ("fetchMapsUnexpectedStatusAndMalformedSuccess", testFetchMapsUnexpectedStatusAndMalformedSuccess),
            ("fetchPropagatesTransportErrors", testFetchPropagatesTransportErrors)
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
