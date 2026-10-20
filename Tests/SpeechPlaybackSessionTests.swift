import Foundation

// Standalone regression harness for Sources/IrodoriTTS/SpeechPlaybackSession.swift.
//
// Every race is driven by an explicit gate or a directly invoked callback; the
// tests contain no sleeps and touch no audio hardware. Compile with:
//
//   swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
//     Sources/IrodoriTTS/SpeechPlaybackSession.swift \
//     Tests/SpeechPlaybackSessionTests.swift -o "$BIN_DIR/session-tests"

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

/// One-shot, thread-safe signal used to observe work that may resume on a
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

/// Holds a task so a backend hook, which must be `@Sendable`, can cancel it.
final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, any Error>?

    func set(_ task: Task<Void, any Error>) {
        lock.lock()
        self.task = task
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let task = self.task
        lock.unlock()
        task?.cancel()
    }
}

/// Thread-safe fake backend. `start` and `stop` only record work and emit no
/// audio; tests invoke `emit` explicitly from whichever executor they choose.
final class FakeBackend: SpeechPlaybackBackend, @unchecked Sendable {
    private struct StartRecord {
        let request: SpeechPlaybackRequest
        let onEvent: @Sendable (SpeechPlaybackEvent) -> Void
    }

    private let lock = NSLock()
    private var starts: [StartRecord] = []
    private var stops: [UUID] = []
    private var handlers: [UUID: @Sendable (SpeechPlaybackEvent) -> Void] = [:]
    private var startBacklog: [SpeechPlaybackRequest] = []
    private var startWaiters: [CheckedContinuation<SpeechPlaybackRequest, Never>] = []
    private var stopWaiters: [CheckedContinuation<UUID, Never>] = []
    private var startHook: (@Sendable (SpeechPlaybackRequest) -> Void)?

    var startedRequests: [SpeechPlaybackRequest] {
        lock.lock()
        defer { lock.unlock() }
        return starts.map(\.request)
    }

    var startCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return starts.count
    }

    var stoppedIDs: [UUID] {
        lock.lock()
        defer { lock.unlock() }
        return stops
    }

    func setStartHook(_ hook: (@Sendable (SpeechPlaybackRequest) -> Void)?) {
        lock.lock()
        startHook = hook
        lock.unlock()
    }

    func start(
        _ request: SpeechPlaybackRequest,
        onEvent: @escaping @Sendable (SpeechPlaybackEvent) -> Void
    ) {
        lock.lock()
        starts.append(StartRecord(request: request, onEvent: onEvent))
        handlers[request.id] = onEvent
        let hook = startHook
        let waiter: CheckedContinuation<SpeechPlaybackRequest, Never>?
        if startWaiters.isEmpty {
            startBacklog.append(request)
            waiter = nil
        } else {
            waiter = startWaiters.removeFirst()
        }
        lock.unlock()

        // Runs on the main actor while the session is inside `start`, which
        // lets a test cancel an older request at a precise lifecycle point.
        hook?(request)
        waiter?.resume(returning: request)
    }

    func stop(id: UUID) {
        lock.lock()
        stops.append(id)
        let waiter: CheckedContinuation<UUID, Never>?
        if stopWaiters.isEmpty {
            waiter = nil
        } else {
            waiter = stopWaiters.removeFirst()
        }
        lock.unlock()
        waiter?.resume(returning: id)
    }

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
            if stops.isEmpty {
                stopWaiters.append(continuation)
                lock.unlock()
            } else {
                let id = stops.removeFirst()
                lock.unlock()
                continuation.resume(returning: id)
            }
        }
    }
}

enum LoggedEvent: Equatable, Sendable {
    case started
    case meter(Float)
    case finished
    case stopped
    case failed(code: Int)
}

@MainActor
final class Recorder {
    private(set) var events: [LoggedEvent] = []
    private(set) var meters: [Float] = []
    private(set) var lastFailure: (any Error)?

    func handle(_ event: SpeechPlaybackEvent) {
        switch event {
        case .started:
            events.append(.started)
        case .meter(let value):
            meters.append(value)
            events.append(.meter(value))
        case .finished:
            events.append(.finished)
        case .stopped:
            events.append(.stopped)
        case .failed(let error):
            lastFailure = error
            events.append(.failed(code: (error as? InjectedError)?.code ?? -1))
        }
    }
}

@main
struct SpeechPlaybackSessionTests {
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

    static func expectCancellation(
        _ label: String,
        _ operation: @MainActor () async throws -> Void
    ) async throws {
        do {
            try await operation()
            throw TestFailure(message: "\(label): expected CancellationError, but no error was thrown")
        } catch let failure as TestFailure {
            throw failure
        } catch is CancellationError {
            return
        } catch {
            throw TestFailure(message: "\(label): expected CancellationError, got \(error)")
        }
    }

    static func expectFailure(
        _ label: String,
        _ expected: InjectedError,
        _ operation: @MainActor () async throws -> Void
    ) async throws {
        do {
            try await operation()
            throw TestFailure(message: "\(label): expected backend failure, but no error was thrown")
        } catch let failure as TestFailure {
            throw failure
        } catch let error as InjectedError {
            guard error === expected else {
                throw TestFailure(message: "\(label): propagated a different error instance")
            }
        } catch {
            throw TestFailure(message: "\(label): expected the backend error, got \(error)")
        }
    }

    /// Lets already-enqueued main-actor tasks run without sleeping.
    static func mainActorTurn() async {
        let turn = Event()
        Task { @MainActor in turn.signal() }
        await turn.wait()
    }

    // MARK: - Tests

    @MainActor
    static func testComplete() async throws {
        let backend = FakeBackend()
        let session = SpeechPlaybackSession(backend: backend)
        let recorder = Recorder()
        let finished = Event()
        let pcm = Data([1, 2, 3, 4])

        let task = Task { @MainActor in
            try await session.play(pcm16: pcm, rate: 1.25, volume: 0.5) { event in
                recorder.handle(event)
                if case .finished = event { finished.signal() }
            }
        }

        let request = await backend.waitForStart()
        try expectEqual("request payload", request.pcm16, pcm)
        try expectEqual("request rate", request.rate, 1.25)
        try expectEqual("request volume", request.volume, 0.5)
        try expectTrue("request has an id", !request.id.uuidString.isEmpty)

        // The backend is silent, so the session must not occupy the main actor.
        let responsive = Event()
        Task { @MainActor in responsive.signal() }
        await responsive.wait()

        backend.emit(.started, for: request.id)
        backend.emit(.meter(0.4), for: request.id)
        backend.emit(.finished, for: request.id)
        try await task.value
        await finished.wait()

        try expectEqual("complete event order", recorder.events, [.started, .meter(0.4), .finished])
        try expectEqual("one backend start", backend.startCount, 1)
        try expectEqual("completion does not call stop", backend.stoppedIDs, [])
    }

    @MainActor
    static func testMainActorResponsiveWhileBackendIsSilent() async throws {
        let backend = FakeBackend()
        let session = SpeechPlaybackSession(backend: backend)
        let recorder = Recorder()
        let finished = Event()

        let task = Task { @MainActor in
            try await session.play(pcm16: Data([0]), rate: 1, volume: 1) { event in
                recorder.handle(event)
                if case .finished = event { finished.signal() }
            }
        }
        let request = await backend.waitForStart()

        // Starting suspends in the session, not on the main actor.
        let marker = Event()
        Task { @MainActor in marker.signal() }
        await marker.wait()
        try expectTrue("play is still pending before the backend responds", !finished.isSignaled)
        try expectEqual("no events before the backend emits", recorder.events, [])

        backend.emit(.finished, for: request.id)
        try await task.value
        try expectEqual("silent backend followed by finish", recorder.events, [.finished])
    }

    @MainActor
    static func testFailurePropagatesAndLateFinishIsIgnored() async throws {
        let backend = FakeBackend()
        let session = SpeechPlaybackSession(backend: backend)
        let recorder = Recorder()
        let failure = InjectedError(code: 7)
        let failedSeen = Event()

        let first = Task { @MainActor in
            try await session.play(pcm16: Data([1]), rate: 1, volume: 1) { event in
                recorder.handle(event)
                if case .failed = event { failedSeen.signal() }
            }
        }
        let firstRequest = await backend.waitForStart()
        backend.emit(.failed(failure), for: firstRequest.id)
        await failedSeen.wait()
        try await expectFailure("exact backend error", failure) {
            try await first.value
        }

        // Late or duplicate callbacks for a settled request must be inert.
        backend.emit(.finished, for: firstRequest.id)
        backend.emit(.failed(failure), for: firstRequest.id)
        await mainActorTurn()
        try expectEqual("failed request emits one failure only", recorder.events, [.failed(code: 7)])
        try expectEqual("failure does not stop the backend", backend.stoppedIDs, [])

        // A stale finish must not complete a newer request either.
        let second = Task { @MainActor in
            try await session.play(pcm16: Data([2]), rate: 1, volume: 1) { event in
                recorder.handle(event)
            }
        }
        let secondRequest = await backend.waitForStart()
        backend.emit(.finished, for: firstRequest.id)
        backend.emit(.started, for: secondRequest.id)
        backend.emit(.finished, for: secondRequest.id)
        try await second.value

        try expectEqual(
            "late failure callbacks stay isolated",
            recorder.events,
            [.failed(code: 7), .started, .finished]
        )
        try expectEqual("a failed request never calls stop", backend.stoppedIDs, [])
    }

    @MainActor
    static func testStopDuringSetupIgnoresLateEvents() async throws {
        let backend = FakeBackend()
        let session = SpeechPlaybackSession(backend: backend)
        let recorder = Recorder()

        let task = Task { @MainActor in
            try await session.play(pcm16: Data([1]), rate: 1, volume: 1) { event in
                recorder.handle(event)
            }
        }
        let request = await backend.waitForStart()

        // Setup has been enqueued but has not reported `started` yet.
        session.stop()
        try await expectCancellation("stop during setup") {
            try await task.value
        }
        try expectEqual("stop notifies once", recorder.events, [.stopped])
        try expectEqual("stop targets the current request", backend.stoppedIDs, [request.id])

        // Native setup may complete late and emit events after the stop.
        backend.emit(.started, for: request.id)
        backend.emit(.meter(0.8), for: request.id)
        backend.emit(.finished, for: request.id)
        await mainActorTurn()
        try expectEqual("late setup events are ignored", recorder.events, [.stopped])

        // And a subsequent request is unaffected by the old callbacks.
        let next = Task { @MainActor in
            try await session.play(pcm16: Data([3]), rate: 1, volume: 1) { event in
                recorder.handle(event)
            }
        }
        let nextRequest = await backend.waitForStart()
        backend.emit(.finished, for: request.id)
        backend.emit(.started, for: nextRequest.id)
        backend.emit(.finished, for: nextRequest.id)
        try await next.value
        try expectEqual("old late events do not reach the new request", recorder.events, [.stopped, .started, .finished])
        try expectEqual("old request is stopped exactly once", backend.stoppedIDs, [request.id])
    }

    @MainActor
    static func testReplacementStopsOldRequestOnly() async throws {
        let backend = FakeBackend()
        let session = SpeechPlaybackSession(backend: backend)
        let recorder = Recorder()
        let meterSeen = Event()

        let first = Task { @MainActor in
            try await session.play(pcm16: Data([1]), rate: 1, volume: 1) { event in
                recorder.handle(event)
                if case .meter = event { meterSeen.signal() }
            }
        }
        let firstRequest = await backend.waitForStart()
        backend.emit(.meter(0.1), for: firstRequest.id)
        await meterSeen.wait()

        let second = Task { @MainActor in
            try await session.play(pcm16: Data([2]), rate: 1, volume: 1) { event in
                recorder.handle(event)
            }
        }
        let secondRequest = await backend.waitForStart()
        try expectEqual("preemption stops only the old id", backend.stoppedIDs, [firstRequest.id])
        try await expectCancellation("preempted play") {
            try await first.value
        }
        try expectEqual("old observer is notified once", recorder.events, [.meter(0.1), .stopped])

        // Old native setup finishes after the replacement.
        backend.emit(.started, for: firstRequest.id)
        backend.emit(.meter(0.9), for: firstRequest.id)
        backend.emit(.finished, for: firstRequest.id)
        backend.emit(.started, for: secondRequest.id)
        backend.emit(.finished, for: secondRequest.id)
        try await second.value

        try expectEqual(
            "replacement event stream",
            recorder.events,
            [.meter(0.1), .stopped, .started, .finished]
        )
        try expectEqual("new request is not stopped", backend.stoppedIDs, [firstRequest.id])
    }

    @MainActor
    static func testCancelBeforeStartDoesNoBackendWork() async throws {
        let backend = FakeBackend()
        let session = SpeechPlaybackSession(backend: backend)
        let recorder = Recorder()

        // The test stays on the main actor between creation and cancellation,
        // so the play task cannot start before cancellation is observed.
        let task = Task { @MainActor in
            try await session.play(pcm16: Data([1]), rate: 1, volume: 1) { event in
                recorder.handle(event)
            }
        }
        task.cancel()

        try await expectCancellation("cancel before start") {
            try await task.value
        }
        try expectEqual("cancelled task does not start", backend.startCount, 0)
        try expectEqual("cancelled task does not stop", backend.stoppedIDs, [])
        try expectEqual("cancelled task emits no events", recorder.events, [])
    }

    @MainActor
    static func testCancelDuringBackendStart() async throws {
        let backend = FakeBackend()
        let session = SpeechPlaybackSession(backend: backend)
        let recorder = Recorder()
        let box = TaskBox()

        let task = Task { @MainActor in
            try await session.play(pcm16: Data([1]), rate: 1, volume: 1) { event in
                recorder.handle(event)
            }
        }
        box.set(task)

        // Cancellation lands while the session is still inside `start`.
        backend.setStartHook { _ in
            box.cancel()
        }

        let request = await backend.waitForStart()
        try await expectCancellation("cancel during start") {
            try await task.value
        }
        try expectEqual("started request is stopped", backend.stoppedIDs, [request.id])
        try expectEqual("cancel during start notifies once", recorder.events, [.stopped])

        // The cancellation handler runs later; it must not add another stop.
        await mainActorTurn()
        backend.emit(.started, for: request.id)
        backend.emit(.finished, for: request.id)
        await mainActorTurn()
        try expectEqual("late cancellation handler is idempotent", backend.stoppedIDs, [request.id])
        try expectEqual("late started/finished are ignored", recorder.events, [.stopped])
    }

    @MainActor
    static func testCancelWhilePlaying() async throws {
        let backend = FakeBackend()
        let session = SpeechPlaybackSession(backend: backend)
        let recorder = Recorder()
        let started = Event()

        let task = Task { @MainActor in
            try await session.play(pcm16: Data([1]), rate: 1, volume: 1) { event in
                recorder.handle(event)
                if case .started = event { started.signal() }
            }
        }
        let request = await backend.waitForStart()
        backend.emit(.started, for: request.id)
        await started.wait()

        task.cancel()
        try await expectCancellation("cancel while playing") {
            try await task.value
        }
        try expectEqual("cancel stops the active request", backend.stoppedIDs, [request.id])
        try expectEqual("cancel while playing event order", recorder.events, [.started, .stopped])

        backend.emit(.meter(0.6), for: request.id)
        backend.emit(.finished, for: request.id)
        await mainActorTurn()
        try expectEqual("events after cancel are ignored", recorder.events, [.started, .stopped])
    }

    @MainActor
    static func testLateCancellationOfOldTaskDoesNotStopNewRequest() async throws {
        let backend = FakeBackend()
        let session = SpeechPlaybackSession(backend: backend)
        let recorder = Recorder()
        let box = TaskBox()

        let first = Task { @MainActor in
            try await session.play(pcm16: Data([1]), rate: 1, volume: 1) { event in
                recorder.handle(event)
            }
        }
        let firstRequest = await backend.waitForStart()
        box.set(first)

        // The replacement cancels the old task from inside its own `start`.
        // The old cancellation handler therefore runs only after the new
        // request is already active.
        backend.setStartHook { request in
            if request.id != firstRequest.id {
                box.cancel()
            }
        }

        let second = Task { @MainActor in
            try await session.play(pcm16: Data([2]), rate: 1, volume: 1) { event in
                recorder.handle(event)
            }
        }
        let secondRequest = await backend.waitForStart()
        try await expectCancellation("old request was preempted") {
            try await first.value
        }
        await mainActorTurn()

        try expectEqual("delayed cancellation keeps the new request", backend.stoppedIDs, [firstRequest.id])
        try expectEqual("no backend stop for the new id", backend.stoppedIDs.contains(secondRequest.id), false)

        backend.emit(.started, for: secondRequest.id)
        backend.emit(.finished, for: secondRequest.id)
        try await second.value
        try expectEqual("replacement still completes", recorder.events, [.stopped, .started, .finished])
        try expectEqual("new request survives delayed cancellation", backend.stoppedIDs, [firstRequest.id])
    }

    @MainActor
    static func testDuplicateCompletionCallbacks() async throws {
        let backend = FakeBackend()
        let session = SpeechPlaybackSession(backend: backend)
        let recorder = Recorder()

        let first = Task { @MainActor in
            try await session.play(pcm16: Data([1]), rate: 1, volume: 1) { event in
                recorder.handle(event)
            }
        }
        let firstRequest = await backend.waitForStart()
        backend.emit(.finished, for: firstRequest.id)
        backend.emit(.finished, for: firstRequest.id)
        backend.emit(.failed(InjectedError(code: 3)), for: firstRequest.id)
        try await first.value
        await mainActorTurn()
        try expectEqual("duplicate finish settles once", recorder.events, [.finished])

        let failure = InjectedError(code: 9)
        let second = Task { @MainActor in
            try await session.play(pcm16: Data([2]), rate: 1, volume: 1) { event in
                recorder.handle(event)
            }
        }
        let secondRequest = await backend.waitForStart()
        backend.emit(.failed(failure), for: secondRequest.id)
        backend.emit(.failed(failure), for: secondRequest.id)
        backend.emit(.finished, for: secondRequest.id)
        try await expectFailure("duplicate failure propagates once", failure) {
            try await second.value
        }
        await mainActorTurn()
        try expectEqual("duplicate failure settles once", recorder.events, [.finished, .failed(code: 9)])
        try expectEqual("completion callbacks never call stop", backend.stoppedIDs, [])
    }

    @MainActor
    static func testMeteringFromStaleRequestsIsDropped() async throws {
        let backend = FakeBackend()
        let session = SpeechPlaybackSession(backend: backend)
        let recorder = Recorder()
        let firstMeter = Event()

        let first = Task { @MainActor in
            try await session.play(pcm16: Data([1]), rate: 1, volume: 1) { event in
                recorder.handle(event)
                if case .meter = event { firstMeter.signal() }
            }
        }
        let firstRequest = await backend.waitForStart()
        backend.emit(.meter(0.1), for: firstRequest.id)
        await firstMeter.wait()

        let second = Task { @MainActor in
            try await session.play(pcm16: Data([2]), rate: 1, volume: 1) { event in
                recorder.handle(event)
            }
        }
        let secondRequest = await backend.waitForStart()

        backend.emit(.meter(0.7), for: firstRequest.id)
        backend.emit(.meter(0.2), for: secondRequest.id)
        backend.emit(.finished, for: secondRequest.id)
        try await second.value
        try await expectCancellation("first request was replaced") {
            try await first.value
        }

        try expectEqual("only current meters are delivered", recorder.meters, [0.1, 0.2])
        try expectEqual(
            "stale meter event order",
            recorder.events,
            [.meter(0.1), .stopped, .meter(0.2), .finished]
        )
    }

    @MainActor
    static func testSynchronousBackendCallbacksAreSafe() async throws {
        let backend = FakeBackend()
        let session = SpeechPlaybackSession(backend: backend)
        let recorder = Recorder()
        let failure = InjectedError(code: 11)

        // `failed` is delivered from inside `start`, before it returns.
        backend.setStartHook { request in
            backend.emit(.failed(failure), for: request.id)
        }
        let failing = Task { @MainActor in
            try await session.play(pcm16: Data([1]), rate: 1, volume: 1) { event in
                recorder.handle(event)
            }
        }
        _ = await backend.waitForStart()
        try await expectFailure("synchronous failure", failure) {
            try await failing.value
        }
        try expectEqual("synchronous failure reports once", recorder.events, [.failed(code: 11)])

        // `finished` is likewise delivered synchronously inside `start`.
        backend.setStartHook { request in
            backend.emit(.started, for: request.id)
            backend.emit(.finished, for: request.id)
        }
        let completing = Task { @MainActor in
            try await session.play(pcm16: Data([2]), rate: 1, volume: 1) { event in
                recorder.handle(event)
            }
        }
        _ = await backend.waitForStart()
        try await completing.value

        try expectEqual(
            "synchronous completion is not lost",
            recorder.events,
            [.failed(code: 11), .started, .finished]
        )
        try expectEqual("synchronous callbacks never call stop", backend.stoppedIDs, [])
    }

    @MainActor
    static func testBackendStoppedThrowsCancellation() async throws {
        let backend = FakeBackend()
        let session = SpeechPlaybackSession(backend: backend)
        let recorder = Recorder()

        let task = Task { @MainActor in
            try await session.play(pcm16: Data([1]), rate: 1, volume: 1) { event in
                recorder.handle(event)
            }
        }
        let request = await backend.waitForStart()
        backend.emit(.started, for: request.id)
        backend.emit(.stopped, for: request.id)

        try await expectCancellation("backend stopped") {
            try await task.value
        }
        try expectEqual("backend stopped event order", recorder.events, [.started, .stopped])
        try expectEqual("backend-initiated stop is not echoed", backend.stoppedIDs, [])
    }

    // MARK: - Runner

    @MainActor
    static func main() async {
        let tests: [(name: String, body: @MainActor () async throws -> Void)] = [
            ("complete", testComplete),
            ("mainActorResponsiveWhileBackendIsSilent", testMainActorResponsiveWhileBackendIsSilent),
            ("failurePropagatesAndLateFinishIsIgnored", testFailurePropagatesAndLateFinishIsIgnored),
            ("stopDuringSetupIgnoresLateEvents", testStopDuringSetupIgnoresLateEvents),
            ("replacementStopsOldRequestOnly", testReplacementStopsOldRequestOnly),
            ("cancelBeforeStartDoesNoBackendWork", testCancelBeforeStartDoesNoBackendWork),
            ("cancelDuringBackendStart", testCancelDuringBackendStart),
            ("cancelWhilePlaying", testCancelWhilePlaying),
            ("lateCancellationOfOldTaskDoesNotStopNewRequest", testLateCancellationOfOldTaskDoesNotStopNewRequest),
            ("duplicateCompletionCallbacks", testDuplicateCompletionCallbacks),
            ("meteringFromStaleRequestsIsDropped", testMeteringFromStaleRequestsIsDropped),
            ("synchronousBackendCallbacksAreSafe", testSynchronousBackendCallbacksAreSafe),
            ("backendStoppedThrowsCancellation", testBackendStoppedThrowsCancellation)
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
