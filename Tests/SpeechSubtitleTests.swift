import Foundation

// Standalone regression harness for App/Models/SpeechSubtitleState.swift and its
// integration with the production Sources/IrodoriTTS/SpeechPlaybackSession.swift.
//
// The view model appends the assistant reply to `messages` immediately, then
// prepares the subtitle state so the on-screen caption stays hidden until the
// audio backend reports an actual `.started` event. It reveals the caption on
// `.started`, and via a `defer` on every other exit (failure, cancellation,
// backend-initiated stop). This file drives the real `SpeechSubtitleState` and
// the real `SpeechPlaybackSession` through a thread-safe mock backend; every
// race is settled by an explicit continuation or gate, with no sleeps and no
// hardware. Compile with:
//
//   swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
//     App/Models/ChatMessage.swift \
//     App/Models/SpeechSubtitleState.swift \
//     Sources/IrodoriTTS/SpeechPlaybackSession.swift \
//     Tests/SpeechSubtitleTests.swift -o "$BIN_DIR/subtitle-tests"

struct TestFailure: Error, CustomStringConvertible, Sendable {
    let message: String
    var description: String { message }
}

/// A backend error whose identity can be compared after passing through the
/// `any Error` existential.
final class InjectedError: Error, @unchecked Sendable {
    let code: Int

    init(code: Int) {
        self.code = code
    }
}

/// One-shot, thread-safe signal used to observe callbacks that may run on a
/// different executor.
final class Event: @unchecked Sendable {
    private let lock = NSLock()
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var isSignaled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return signaled
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if signaled {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func signal() {
        lock.lock()
        guard !signaled else {
            lock.unlock()
            return
        }
        signaled = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for waiter in pending {
            waiter.resume()
        }
    }
}

/// Settles a continuation at most once, so a late winner cannot double-resume.
private final class OneShotResumer<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var settled = false

    func complete(_ value: T, into continuation: CheckedContinuation<T, any Error>) {
        lock.lock()
        let isFirst = !settled
        settled = true
        lock.unlock()
        if isFirst { continuation.resume(returning: value) }
    }

    func fail(_ error: any Error, into continuation: CheckedContinuation<T, any Error>) {
        lock.lock()
        let isFirst = !settled
        settled = true
        lock.unlock()
        if isFirst { continuation.resume(throwing: error) }
    }
}

/// Races an operation against a generous deadline so a broken invariant fails
/// the suite instead of hanging it. The deadline is a safety net, not a
/// synchronization device: correct paths settle through explicit gates. The
/// losing task is abandoned without being awaited, so a gate that never opens
/// cannot stall the suite.
func withTimeout<T: Sendable>(
    _ label: String,
    seconds: Double = 5,
    _ operation: @escaping @Sendable () async -> T
) async throws -> T {
    let resumer = OneShotResumer<T>()
    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
        Task.detached {
            let value = await operation()
            resumer.complete(value, into: continuation)
        }
        Task.detached {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            resumer.fail(TestFailure(message: "\(label): timed out after \(seconds)s"), into: continuation)
        }
    }
}

/// Thread-safe fake backend. `start` and `stop` only record work and emit no
/// audio; tests invoke `emit` explicitly from whichever point they choose.
final class FakeBackend: SpeechPlaybackBackend, @unchecked Sendable {
    private struct Record {
        let request: SpeechPlaybackRequest
        let onEvent: @Sendable (SpeechPlaybackEvent) -> Void
    }

    private let lock = NSLock()
    private var records: [Record] = []
    private var handlers: [UUID: @Sendable (SpeechPlaybackEvent) -> Void] = [:]
    private var stops: [UUID] = []
    private var startBacklog: [SpeechPlaybackRequest] = []
    private var startWaiters: [CheckedContinuation<SpeechPlaybackRequest, Never>] = []
    private var stopBacklog: [UUID] = []
    private var stopWaiters: [CheckedContinuation<UUID, Never>] = []

    var startedIDs: [UUID] {
        lock.lock()
        defer { lock.unlock() }
        return records.map(\.request.id)
    }

    var stoppedIDs: [UUID] {
        lock.lock()
        defer { lock.unlock() }
        return stops
    }

    func start(
        _ request: SpeechPlaybackRequest,
        onEvent: @escaping @Sendable (SpeechPlaybackEvent) -> Void
    ) {
        lock.lock()
        records.append(Record(request: request, onEvent: onEvent))
        handlers[request.id] = onEvent
        let waiter: CheckedContinuation<SpeechPlaybackRequest, Never>?
        if startWaiters.isEmpty {
            startBacklog.append(request)
            waiter = nil
        } else {
            waiter = startWaiters.removeFirst()
        }
        lock.unlock()
        waiter?.resume(returning: request)
    }

    func stop(id: UUID) {
        lock.lock()
        stops.append(id)
        let waiter: CheckedContinuation<UUID, Never>?
        if stopWaiters.isEmpty {
            stopBacklog.append(id)
            waiter = nil
        } else {
            waiter = stopWaiters.removeFirst()
        }
        lock.unlock()
        waiter?.resume(returning: id)
    }

    /// Delivers one event to the handler registered for `id`, mirroring a
    /// delayed native callback. Handlers stay installed after a request
    /// settles, so stale events can be replayed deliberately.
    func emit(_ event: SpeechPlaybackEvent, for id: UUID) {
        lock.lock()
        let handler = handlers[id]
        lock.unlock()
        handler?(event)
    }

    func waitForStart() async -> SpeechPlaybackRequest {
        await withCheckedContinuation { (continuation: CheckedContinuation<SpeechPlaybackRequest, Never>) in
            lock.lock()
            if startBacklog.isEmpty {
                startWaiters.append(continuation)
                lock.unlock()
            } else {
                let request = startBacklog.removeFirst()
                lock.unlock()
                continuation.resume(returning: request)
            }
        }
    }

    func waitForStop() async -> UUID {
        await withCheckedContinuation { (continuation: CheckedContinuation<UUID, Never>) in
            lock.lock()
            if stopBacklog.isEmpty {
                stopWaiters.append(continuation)
                lock.unlock()
            } else {
                let id = stopBacklog.removeFirst()
                lock.unlock()
                continuation.resume(returning: id)
            }
        }
    }
}

/// Mirrors the view model's subtitle lifecycle around the production
/// `SpeechPlaybackSession`: the reply joins `messages` immediately, the state
/// prepares before the append, the caption reveals only on `.started`, and a
/// `defer` reveals it on every other exit.
@MainActor
final class SubtitleHarness {
    let session: SpeechPlaybackSession
    private(set) var state = SpeechSubtitleState()
    private(set) var messages: [ChatMessage] = []

    /// Message identities the session actually forwarded a `.started` for,
    /// in delivery order. Stale requests must never appear here.
    private(set) var observedStarted: [UUID] = []
    /// Message identities the session forwarded a `.meter` for.
    private(set) var observedMeters: [UUID] = []

    var onStarted: (() -> Void)?
    var onMeter: (() -> Void)?

    init(backend: FakeBackend) {
        session = SpeechPlaybackSession(backend: backend)
    }

    var subtitle: ChatMessage? {
        state.visibleMessage(in: messages)
    }

    /// Appends the assistant reply and hides the caption until playback starts.
    @discardableResult
    func appendReply(_ text: String) -> UUID {
        let message = ChatMessage(role: .assistant, content: text)
        state.prepare(for: message.id)
        messages.append(message)
        return message.id
    }

    @discardableResult
    func speak(_ pcm: Data, messageID: UUID) -> Task<Void, Never> {
        Task { @MainActor in
            defer { self.state.reveal(for: messageID) }
            do {
                try await self.session.play(pcm16: pcm, rate: 1, volume: 1) { event in
                    self.receive(event, messageID: messageID)
                }
            } catch {
                // Failure, cancellation, and stop all fall through to the
                // deferred reveal so the text is never lost.
            }
        }
    }

    /// Mirrors `stopSpeaking()`: stop audio, then reset the subtitle state so
    /// the reply becomes visible immediately.
    func stop() {
        session.stop()
        state.reset()
    }

    private func receive(_ event: SpeechPlaybackEvent, messageID: UUID) {
        switch event {
        case .started:
            observedStarted.append(messageID)
            revealIfCurrent(messageID)
            onStarted?()
        case .meter:
            observedMeters.append(messageID)
            onMeter?()
        case .finished, .stopped, .failed:
            break
        }
    }

    private func revealIfCurrent(_ messageID: UUID) {
        // Matches `speechPlaybackStarted`, which ignores a notification once a
        // newer turn owns the last message.
        guard messages.last?.id == messageID else { return }
        state.reveal(for: messageID)
    }
}

@main
struct SpeechSubtitleTests {
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

    static func waitForSignal(_ label: String, _ event: Event) async throws {
        try await withTimeout(label) { await event.wait() }
    }

    // MARK: - Production state

    @MainActor
    static func testStateHidesPendingLastMessage() async throws {
        var state = SpeechSubtitleState()
        let message = ChatMessage(role: .assistant, content: "reply")

        state.prepare(for: message.id)
        try expectEqual("pending id stored", state.pendingMessageID, message.id)
        try expectTrue("pending reply is hidden", state.visibleMessage(in: [message]) == nil)
        // Hiding is presentation only: history keeps the text.
        try expectEqual("history retains the reply", [message].last?.content, "reply")
    }

    @MainActor
    static func testRevealShowsMessageAndClearsPending() async throws {
        var state = SpeechSubtitleState()
        let message = ChatMessage(role: .assistant, content: "reply")

        state.prepare(for: message.id)
        state.reveal(for: message.id)
        try expectEqual("pending cleared", state.pendingMessageID, nil)
        try expectEqual("reply visible after reveal", state.visibleMessage(in: [message]), message)
    }

    @MainActor
    static func testRevealIgnoresNonMatchingIdentity() async throws {
        var state = SpeechSubtitleState()
        let older = ChatMessage(role: .assistant, content: "older")
        let newer = ChatMessage(role: .assistant, content: "newer")

        // Prepare replaces the previous pending identity.
        state.prepare(for: older.id)
        state.prepare(for: newer.id)
        state.reveal(for: older.id)
        try expectEqual("stale reveal leaves newer pending", state.pendingMessageID, newer.id)
        try expectTrue("newer reply still hidden", state.visibleMessage(in: [older, newer]) == nil)

        state.reveal(for: UUID())
        try expectEqual("unknown id is inert", state.pendingMessageID, newer.id)

        state.reveal(for: newer.id)
        try expectEqual("matching reveal shows the last reply", state.visibleMessage(in: [older, newer]), newer)
    }

    @MainActor
    static func testResetRevealsWithoutCallback() async throws {
        var state = SpeechSubtitleState()
        let message = ChatMessage(role: .assistant, content: "reply")

        state.prepare(for: message.id)
        state.reset()
        try expectEqual("reset clears pending", state.pendingMessageID, nil)
        try expectEqual("reply visible after reset", state.visibleMessage(in: [message]), message)

        // A late reveal after reset must not misbehave.
        state.reveal(for: message.id)
        try expectEqual("late reveal after reset is inert", state.pendingMessageID, nil)
    }

    @MainActor
    static func testVisibleMessageOnlyConsidersLastMessage() async throws {
        var state = SpeechSubtitleState()
        let first = ChatMessage(role: .assistant, content: "first")
        let second = ChatMessage(role: .assistant, content: "second")

        try expectTrue("no messages yields nil", state.visibleMessage(in: []) == nil)
        try expectEqual("default shows the last reply", state.visibleMessage(in: [first, second]), second)

        // Pending an *older* identity never hides the newer last message.
        state.prepare(for: first.id)
        try expectEqual("older pending does not hide newer reply", state.visibleMessage(in: [first, second]), second)

        state.prepare(for: second.id)
        try expectTrue("pending last reply is hidden", state.visibleMessage(in: [first, second]) == nil)
    }

    // MARK: - Integration with the production playback session

    @MainActor
    static func testHistoryKeepsTextHiddenUntilPlaybackStarts() async throws {
        let backend = FakeBackend()
        let harness = SubtitleHarness(backend: backend)
        let started = Event()
        harness.onStarted = { started.signal() }

        let id = harness.appendReply("spoken reply")
        let task = harness.speak(Data([1, 2, 3]), messageID: id)
        let request = try await withTimeout("start") { await backend.waitForStart() }

        // Silent backend: caption hidden, but the transcript already has it.
        try expectTrue("caption hidden before start", harness.subtitle == nil)
        try expectEqual("history has the reply text", harness.messages.last?.content, "spoken reply")

        backend.emit(.started, for: request.id)
        try await waitForSignal("started", started)
        try expectEqual("caption revealed on start", harness.subtitle, harness.messages.last)

        backend.emit(.finished, for: request.id)
        await task.value
        try expectEqual("caption stays visible after finish", harness.subtitle, harness.messages.last)
    }

    @MainActor
    static func testMetersDoNotRevealBeforeStart() async throws {
        let backend = FakeBackend()
        let harness = SubtitleHarness(backend: backend)
        let meter = Event()
        let started = Event()
        harness.onMeter = { meter.signal() }
        harness.onStarted = { started.signal() }

        let id = harness.appendReply("reply")
        let task = harness.speak(Data([0]), messageID: id)
        let request = try await withTimeout("start") { await backend.waitForStart() }

        backend.emit(.meter(0.7), for: request.id)
        try await waitForSignal("meter", meter)
        try expectTrue("metering alone does not reveal", harness.subtitle == nil)

        backend.emit(.started, for: request.id)
        try await waitForSignal("started", started)
        try expectEqual("start reveals after metering", harness.subtitle, harness.messages.last)

        backend.emit(.meter(0.9), for: request.id)
        backend.emit(.finished, for: request.id)
        await task.value
        try expectEqual("all forwarded events are for this message", harness.observedStarted, [id])
    }

    @MainActor
    static func testFailureBeforeStartRevealsViaDefer() async throws {
        let backend = FakeBackend()
        let harness = SubtitleHarness(backend: backend)
        let failure = InjectedError(code: 7)

        let id = harness.appendReply("reply")
        let task = harness.speak(Data([1]), messageID: id)
        let request = try await withTimeout("start") { await backend.waitForStart() }

        // Backend fails during setup, before any `.started`.
        backend.emit(.failed(failure), for: request.id)
        await task.value

        try expectEqual("failed reply becomes visible", harness.subtitle, harness.messages.last)
        try expectEqual("no start was observed", harness.observedStarted, [])
        try expectEqual("failure never stops the backend", backend.stoppedIDs, [])
        try expectEqual("pending cleared by reveal", harness.state.pendingMessageID, nil)
    }

    @MainActor
    static func testBackendStoppedBeforeStartRevealsViaDefer() async throws {
        let backend = FakeBackend()
        let harness = SubtitleHarness(backend: backend)

        let id = harness.appendReply("reply")
        let task = harness.speak(Data([1]), messageID: id)
        let request = try await withTimeout("start") { await backend.waitForStart() }

        // The backend aborts itself (e.g. audio route change) before playback.
        backend.emit(.stopped, for: request.id)
        await task.value

        try expectEqual("stopped reply becomes visible", harness.subtitle, harness.messages.last)
        try expectEqual("no start was observed", harness.observedStarted, [])
        try expectEqual("backend stop is not echoed", backend.stoppedIDs, [])
    }

    @MainActor
    static func testStopResetsStateAndRevealsMessage() async throws {
        let backend = FakeBackend()
        let harness = SubtitleHarness(backend: backend)

        let id = harness.appendReply("reply")
        let task = harness.speak(Data([1]), messageID: id)
        let request = try await withTimeout("start") { await backend.waitForStart() }
        try expectTrue("hidden while playing", harness.subtitle == nil)

        harness.stop()
        let stopped = try await withTimeout("stop") { await backend.waitForStop() }
        try expectEqual("active request stopped", stopped, request.id)
        try expectEqual("reset clears pending immediately", harness.state.pendingMessageID, nil)
        try expectEqual("reply visible after stop", harness.subtitle, harness.messages.last)

        await task.value
        try expectEqual("reply stays visible after unwind", harness.subtitle, harness.messages.last)
    }

    @MainActor
    static func testPreemptionKeepsNewerHiddenAndIgnoresStaleStarted() async throws {
        let backend = FakeBackend()
        let harness = SubtitleHarness(backend: backend)
        let secondStarted = Event()
        harness.onStarted = { secondStarted.signal() }

        let firstID = harness.appendReply("first")
        let firstTask = harness.speak(Data([1]), messageID: firstID)
        let firstRequest = try await withTimeout("first start") { await backend.waitForStart() }
        try expectTrue("first hidden", harness.subtitle == nil)

        // A newer turn preempts the first request before it ever started.
        let secondID = harness.appendReply("second")
        let secondTask = harness.speak(Data([2]), messageID: secondID)
        let secondRequest = try await withTimeout("second start") { await backend.waitForStart() }
        let firstStopped = try await withTimeout("first stop") { await backend.waitForStop() }
        try expectEqual("preemption stops the first request", firstStopped, firstRequest.id)

        await firstTask.value
        try expectTrue("newer caption still hidden", harness.subtitle == nil)
        try expectEqual("newer pending id", harness.state.pendingMessageID, secondID)

        // A late `.started` from the preempted request must be dropped. Emit the
        // real start afterwards; the serialized stream guarantees the stale
        // event is processed first if it were forwarded at all.
        backend.emit(.started, for: firstRequest.id)
        backend.emit(.started, for: secondRequest.id)
        try await waitForSignal("second started", secondStarted)

        try expectEqual("only the current request was forwarded", harness.observedStarted, [secondID])
        try expectEqual("newer caption revealed on its own start", harness.subtitle, harness.messages.last)
        try expectEqual("newer message is last", harness.messages.last?.id, secondID)
        try expectEqual("stale first never started", harness.observedStarted.contains(firstID), false)

        backend.emit(.finished, for: secondRequest.id)
        await secondTask.value
    }

    @MainActor
    static func testStaleDeferredRevealCannotRevealNewerMessage() async throws {
        let backend = FakeBackend()
        let harness = SubtitleHarness(backend: backend)

        let firstID = harness.appendReply("first")
        let firstTask = harness.speak(Data([1]), messageID: firstID)
        _ = try await withTimeout("first start") { await backend.waitForStart() }

        let secondID = harness.appendReply("second")
        let secondTask = harness.speak(Data([2]), messageID: secondID)
        let secondRequest = try await withTimeout("second start") { await backend.waitForStart() }
        _ = try await withTimeout("first stop") { await backend.waitForStop() }

        // Unwinding the preempted task runs `reveal(for: firstID)`. Because the
        // pending identity is the newer message, the deferred reveal is inert.
        await firstTask.value
        try expectEqual("pending identity kept", harness.state.pendingMessageID, secondID)
        try expectTrue("newer caption remains hidden", harness.subtitle == nil)

        let started = Event()
        harness.onStarted = { started.signal() }
        backend.emit(.started, for: secondRequest.id)
        try await waitForSignal("second started", started)
        try expectEqual("second revealed by its own start", harness.subtitle, harness.messages.last)

        backend.emit(.finished, for: secondRequest.id)
        await secondTask.value
    }

    @MainActor
    static func testLateStartAfterCompletionIsInert() async throws {
        let backend = FakeBackend()
        let harness = SubtitleHarness(backend: backend)

        let firstID = harness.appendReply("first")
        let firstStarted = Event()
        harness.onStarted = { firstStarted.signal() }
        let firstTask = harness.speak(Data([1]), messageID: firstID)
        let firstRequest = try await withTimeout("first start") { await backend.waitForStart() }
        backend.emit(.started, for: firstRequest.id)
        try await waitForSignal("first started", firstStarted)
        backend.emit(.finished, for: firstRequest.id)
        await firstTask.value
        try expectEqual("first matched once", harness.observedStarted, [firstID])

        // A duplicate `.started` after the request settled must not be forwarded
        // or reveal anything new.
        backend.emit(.started, for: firstRequest.id)

        // A second turn proves ordering: any stale duplicate would be delivered
        // before the second start.
        let secondID = harness.appendReply("second")
        let secondStarted = Event()
        harness.onStarted = { secondStarted.signal() }
        let secondTask = harness.speak(Data([2]), messageID: secondID)
        let secondRequest = try await withTimeout("second start") { await backend.waitForStart() }
        backend.emit(.started, for: secondRequest.id)
        try await waitForSignal("second started", secondStarted)

        try expectEqual("late duplicate dropped", harness.observedStarted, [firstID, secondID])
        try expectEqual("caption follows the newest reply", harness.subtitle, harness.messages.last)

        backend.emit(.finished, for: secondRequest.id)
        await secondTask.value
    }

    // MARK: - Runner

    @MainActor
    static func main() async {
        let tests: [(name: String, body: @MainActor () async throws -> Void)] = [
            ("stateHidesPendingLastMessage", testStateHidesPendingLastMessage),
            ("revealShowsMessageAndClearsPending", testRevealShowsMessageAndClearsPending),
            ("revealIgnoresNonMatchingIdentity", testRevealIgnoresNonMatchingIdentity),
            ("resetRevealsWithoutCallback", testResetRevealsWithoutCallback),
            ("visibleMessageOnlyConsidersLastMessage", testVisibleMessageOnlyConsidersLastMessage),
            ("historyKeepsTextHiddenUntilPlaybackStarts", testHistoryKeepsTextHiddenUntilPlaybackStarts),
            ("metersDoNotRevealBeforeStart", testMetersDoNotRevealBeforeStart),
            ("failureBeforeStartRevealsViaDefer", testFailureBeforeStartRevealsViaDefer),
            ("backendStoppedBeforeStartRevealsViaDefer", testBackendStoppedBeforeStartRevealsViaDefer),
            ("stopResetsStateAndRevealsMessage", testStopResetsStateAndRevealsMessage),
            ("preemptionKeepsNewerHiddenAndIgnoresStaleStarted", testPreemptionKeepsNewerHiddenAndIgnoresStaleStarted),
            ("staleDeferredRevealCannotRevealNewerMessage", testStaleDeferredRevealCannotRevealNewerMessage),
            ("lateStartAfterCompletionIsInert", testLateStartAfterCompletionIsInert)
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
