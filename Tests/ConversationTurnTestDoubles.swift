import Foundation
import IrodoriTTS

// Standalone test doubles for the App service types that
// ConversationViewModel.swift normally links against. The real view model is
// compiled unchanged; only its concrete service dependencies are replaced here
// so no network, model download, audio device, or microphone is required.
//
// Keep these signatures in sync with the production services the view model
// actually calls. Fake behavior is observable from the test runner so every
// asynchronous step is settled by an explicit gate instead of a sleep.

// MARK: - Settings

public enum LLMProviderType: String, CaseIterable, Identifiable, Sendable {
    case localLFM = "localLFM"
    case chatGPTSignIn = "chatGPTSignIn"
    case gemini = "gemini"
    case openAICompatible = "openAICompatible"

    public var id: String { rawValue }
}

@MainActor
public final class AppSettings {
    public static let shared = AppSettings()

    public var llmProviderType: LLMProviderType = .openAICompatible
    public var systemPrompt = "テスト用システムプロンプト"
    public var temperature = 0.7
    public var ttsSynthesisMode: TTSSynthesisMode = .perSentence
    public var ttsCaption = "テスト用キャプション"
    public var useRandomSeed = false
    public var speakerSeed: Int = 12345
    public var watermarkEnabled = false
    public var isHandsFreeMode = false

    public init() {}

    public func reset() {
        llmProviderType = .openAICompatible
        systemPrompt = "テスト用システムプロンプト"
        temperature = 0.7
        ttsSynthesisMode = .perSentence
        ttsCaption = "テスト用キャプション"
        useRandomSeed = false
        speakerSeed = 12345
        watermarkEnabled = false
        isHandsFreeMode = false
    }
}

// MARK: - LLM

public struct LLMRequestSnapshot: Sendable {
    public let index: Int
    public let systemPrompt: String
    public let messages: [ChatMessage]
    public let temperature: Double
}

/// Shared backing store for every fake `LLMClient` instance. The view model
/// creates its own client, so the gate lives outside that instance and the test
/// can hold a request open until it explicitly releases (or fails) it.
public actor FakeLLMBackend {
    public static let shared = FakeLLMBackend()

    private var requests: [LLMRequestSnapshot] = []
    private var continuations: [Int: CheckedContinuation<String, any Error>] = [:]
    private var requestWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var finishedRequests: Set<Int> = []
    private var finishWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    public init() {}

    public func generate(
        systemPrompt: String,
        messages: [ChatMessage],
        temperature: Double
    ) async throws -> String {
        let index = requests.count
        requests.append(LLMRequestSnapshot(
            index: index,
            systemPrompt: systemPrompt,
            messages: messages,
            temperature: temperature
        ))
        resumeRequestWaiters()

        do {
            let reply = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<String, any Error>) in
                continuations[index] = continuation
            }
            markFinished(index)
            return reply
        } catch {
            markFinished(index)
            throw error
        }
    }

    public func requestCount() -> Int {
        requests.count
    }

    public func request(at index: Int) -> LLMRequestSnapshot? {
        guard requests.indices.contains(index) else { return nil }
        return requests[index]
    }

    /// Waits until at least `count` LLM requests have reached this gate.
    public func waitForRequestCount(_ count: Int) async {
        guard requests.count < count else { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append((count: count, continuation: continuation))
        }
    }

    /// Completes request `index` with a successful reply. The view model's
    /// continuation is resumed only at this point.
    public func release(_ index: Int, reply: String) {
        guard let continuation = continuations.removeValue(forKey: index) else { return }
        continuation.resume(returning: reply)
    }

    /// Completes request `index` with an error.
    public func fail(_ index: Int, error: any Error) {
        guard let continuation = continuations.removeValue(forKey: index) else { return }
        continuation.resume(throwing: error)
    }

    /// Waits until the fake client has actually returned from `count` requests.
    /// The view model may still need a few main-actor turns after this point.
    public func waitForFinishedCount(_ count: Int) async {
        guard finishedRequests.count < count else { return }
        await withCheckedContinuation { continuation in
            finishWaiters.append((count: count, continuation: continuation))
        }
    }

    /// Releases any hung request and clears all observations between tests.
    public func reset() {
        let pending = continuations.values
        continuations.removeAll()
        requests.removeAll()
        finishedRequests.removeAll()

        for continuation in pending {
            continuation.resume(throwing: CancellationError())
        }
        let requestsToResume = requestWaiters
        requestWaiters.removeAll()
        for waiter in requestsToResume {
            waiter.continuation.resume()
        }
        let finishesToResume = finishWaiters
        finishWaiters.removeAll()
        for waiter in finishesToResume {
            waiter.continuation.resume()
        }
    }

    private func resumeRequestWaiters() {
        let ready = requestWaiters.filter { $0.count <= requests.count }
        requestWaiters.removeAll { $0.count <= requests.count }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }

    private func markFinished(_ index: Int) {
        finishedRequests.insert(index)
        let ready = finishWaiters.filter { $0.count <= finishedRequests.count }
        finishWaiters.removeAll { $0.count <= finishedRequests.count }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }
}

public actor LLMClient {
    public init() {}

    public func generateReply(
        systemPrompt: String,
        messages: [ChatMessage],
        temperature: Double = 0.7
    ) async throws -> String {
        try await FakeLLMBackend.shared.generate(
            systemPrompt: systemPrompt,
            messages: messages,
            temperature: temperature
        )
    }
}

// MARK: - TTS

@MainActor
public final class SpeechTTSManager {
    public static let shared = SpeechTTSManager()

    public private(set) var isModelInstalled = true
    public private(set) var synthesizeCallCount = 0
    public private(set) var synthesizedTexts: [String] = []

    public init() {}

    public func synthesize(
        text: String,
        caption: String,
        seed: UInt32 = 12345,
        watermark: Bool = false
    ) async throws -> Data {
        synthesizeCallCount += 1
        synthesizedTexts.append(text)
        return Data(repeating: 0, count: 480)
    }

    public func reset() {
        isModelInstalled = true
        synthesizeCallCount = 0
        synthesizedTexts.removeAll()
    }
}

// MARK: - Audio

@MainActor
public final class AudioSpeechPlayer {
    public static let shared = AudioSpeechPlayer()

    public private(set) var playCallCount = 0
    public private(set) var stopCallCount = 0
    public private(set) var isPlaying = false

    private struct PendingPlayback {
        let id: UUID
        let onPlaybackStarted: @MainActor @Sendable () -> Void
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var pending: PendingPlayback?
    private var requestWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    public init() {}

    /// Suspends until the test calls `signalPlaybackStarted()` and then
    /// `finishPlayback()` (or `stop()` / `failPlayback(_:)`).
    public func play(
        pcm16: Data,
        onPlaybackStarted: @escaping @MainActor @Sendable () -> Void = {}
    ) async throws {
        let id = UUID()
        playCallCount += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                pending = PendingPlayback(
                    id: id,
                    onPlaybackStarted: onPlaybackStarted,
                    continuation: continuation
                )
                resumeRequestWaiters()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelPendingPlayback(matching: id)
            }
        }
    }

    public func stop() {
        stopCallCount += 1
        isPlaying = false
        cancelPendingPlayback()
    }

    public func waitForPlayRequest(_ count: Int) async {
        guard playCallCount < count else { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append((count: count, continuation: continuation))
        }
    }

    /// Returns the queued playback's start callback without completing it, so
    /// a test can replay a callback that belongs to an invalidated turn.
    public func pendingPlaybackStartedCallback() -> (@MainActor @Sendable () -> Void)? {
        pending?.onPlaybackStarted
    }

    /// Emits the backend's actual playback-start event without finishing
    /// playback, so the test can observe the view model's reveal transition.
    public func signalPlaybackStarted() {
        guard let pending else { return }
        isPlaying = true
        pending.onPlaybackStarted()
    }

    public func finishPlayback() {
        guard let pending else { return }
        self.pending = nil
        isPlaying = false
        pending.continuation.resume()
    }

    public func failPlayback(_ error: any Error) {
        guard let pending else { return }
        self.pending = nil
        isPlaying = false
        pending.continuation.resume(throwing: error)
    }

    public func reset() {
        cancelPendingPlayback()
        playCallCount = 0
        stopCallCount = 0
        isPlaying = false
        let waiters = requestWaiters
        requestWaiters.removeAll()
        for waiter in waiters {
            waiter.continuation.resume()
        }
    }

    private func cancelPendingPlayback(matching id: UUID? = nil) {
        guard let pending, id == nil || pending.id == id else { return }
        self.pending = nil
        pending.continuation.resume(throwing: CancellationError())
    }

    private func resumeRequestWaiters() {
        let ready = requestWaiters.filter { $0.count <= playCallCount }
        requestWaiters.removeAll { $0.count <= playCallCount }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }
}

// MARK: - Speech recognition

@MainActor
public final class SpeechAnalyzerService {
    public static let shared = SpeechAnalyzerService()

    public private(set) var isPreparing = false
    public private(set) var isListening = false
    public var liveTranscript = ""
    public var isHandsFreeEnabled = false
    public var onSpeechRecognized: ((String) -> Void)?

    public init() {}

    public func startListening() async throws {
        isPreparing = false
        isListening = true
    }

    public func stopListening() {
        isPreparing = false
        isListening = false
        liveTranscript = ""
    }

    public func reset() {
        stopListening()
        isHandsFreeEnabled = false
        onSpeechRecognized = nil
    }
}

// MARK: - IrodoriTTS shim symbol

/// ConversationViewModel maps synthesis/playback errors to `IrodoriError`.
/// The real SpeechPlaybackPipeline shim does not include the model bundle, so
/// this tiny production-shaped error lives in the test executable.
public enum IrodoriError: LocalizedError, Sendable {
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let message):
            return message
        }
    }
}
