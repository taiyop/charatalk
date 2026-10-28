import Foundation

// swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
//   Sources/IrodoriTTS/SpeechPlaybackSession.swift \
//   Sources/IrodoriTTS/SpeechPlaybackPipeline.swift \
//   Tests/SpeechPlaybackQueueTests.swift -o "$BIN_DIR/queue-tests"

private struct Failure: Error, CustomStringConvertible {
    let description: String
}
private enum InjectedError: Error, Equatable { case setup, synthesis }

private final class PCMReleaseCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func makePCM() -> Data {
        let size = 16_384
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 2)
        pointer.initializeMemory(as: UInt8.self, repeating: 65, count: size)
        return Data(bytesNoCopy: pointer, count: size, deallocator: .custom { [self] pointer, _ in
            pointer.deallocate()
            lock.lock(); count += 1; lock.unlock()
        })
    }
}

@MainActor
private final class Gate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func signal() {
        open = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private final class Backend: SpeechPlaybackQueueBackend, @unchecked Sendable {
    struct Request: Sendable {
        let id: UUID
        let streamID: UUID
        let payload: String
        let rate: Float
        let volume: Float
    }
    private let lock = NSLock()
    private var handlers: [UUID: @Sendable (SpeechPlaybackEvent) -> Void] = [:]
    private var stops: [UUID] = []
    let requests: AsyncStream<Request>
    private let requestSink: AsyncStream<Request>.Continuation
    let stopped: AsyncStream<UUID>
    private let stopSink: AsyncStream<UUID>.Continuation
    var synchronousEvents = false // Set only before any calls.

    init() {
        (requests, requestSink) = AsyncStream.makeStream()
        (stopped, stopSink) = AsyncStream.makeStream()
    }
    var stoppedIDs: [UUID] {
        lock.lock(); defer { lock.unlock() }; return stops
    }
    func enqueue(_ request: SpeechPlaybackRequest, streamID: UUID,
                 onEvent: @escaping @Sendable (SpeechPlaybackEvent) -> Void) {
        lock.lock(); handlers[request.id] = onEvent; lock.unlock()
        requestSink.yield(Request(id: request.id, streamID: streamID,
                                  payload: String(decoding: request.pcm16, as: UTF8.self), rate: request.rate, volume: request.volume))
        if synchronousEvents { onEvent(.started); onEvent(.started); onEvent(.finished); onEvent(.finished) }
    }
    func stop(streamID: UUID) {
        lock.lock(); stops.append(streamID); lock.unlock()
        stopSink.yield(streamID)
    }
    func emit(_ event: SpeechPlaybackEvent, id: UUID) {
        lock.lock(); let callback = handlers[id]; lock.unlock()
        callback?(event)
    }
}

@main
@MainActor
struct SpeechPlaybackQueueTests {
    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }
    private static func cancelled(_ completion: SpeechPlaybackCompletion) async throws {
        do { try await completion.wait(); throw Failure(description: "expected cancellation") }
        catch is CancellationError {}
    }

    static func prequeueAndEarlyCompletion() async throws {
        let backend = Backend()
        let session = SpeechPlaybackQueueSession(backend: backend)
        let stream = session.begin()
        var events: [String] = []
        let observed = Gate()
        let first = try session.enqueue(pcm16: Data("first".utf8), streamID: stream, rate: 1.5, volume: 0.7) {
            if case .started = $0 { events.append("start0") }
            if case .finished = $0 { events.append("finish0") }
        }
        let second = try session.enqueue(pcm16: Data("second".utf8), streamID: stream, rate: 1.5, volume: 0.7) {
            if case .started = $0 { events.append("start1") }
            if case .finished = $0 { events.append("finish1"); observed.signal() }
        }
        var requests = backend.requests.makeAsyncIterator()
        let r0 = await requests.next()!
        let r1 = await requests.next()!
        try expect(r0.streamID == stream && r1.streamID == stream, "buffers must share a stream")
        try expect(r0.payload == "first" && r1.payload == "second", "ordered PCM")
        try expect(r0.rate == 1.5 && r0.volume == 0.7, "settings preserved")
        try expect(events.isEmpty, "enqueue must not claim audible playback")
        backend.emit(.started, id: r0.id)
        backend.emit(.finished, id: r0.id)
        backend.emit(.started, id: r1.id)
        backend.emit(.finished, id: r1.id)
        await observed.wait()
        // Both native completions happened before either consumer wait.
        try await first.wait()
        try await second.wait()
        try expect(events == ["start0", "finish0", "start1", "finish1"], "cross-buffer event order")
        session.stop(streamID: stream)
    }

    static func replacementAndLateCancellation() async throws {
        let backend = Backend()
        let session = SpeechPlaybackQueueSession(backend: backend)
        let old = session.begin()
        var oldEvents = 0
        let a = try session.enqueue(pcm16: Data(), streamID: old, rate: 1, volume: 1) { _ in oldEvents += 1 }
        let b = try session.enqueue(pcm16: Data(), streamID: old, rate: 1, volume: 1)
        var requests = backend.requests.makeAsyncIterator()
        let oldRequest = await requests.next()!
        _ = await requests.next()
        let new = session.begin()
        try await cancelled(a)
        try await cancelled(b)
        let countAfterStop = oldEvents
        backend.emit(.started, id: oldRequest.id)
        backend.emit(.finished, id: oldRequest.id)
        backend.emit(.meter(1), id: oldRequest.id)
        // Delayed cancellation of an old completion must not stop `new`.
        let late = Task { try await a.wait() }
        late.cancel()
        _ = await late.result
        session.stop(streamID: old)
        let next = try session.enqueue(pcm16: Data(), streamID: new, rate: 1, volume: 1)
        let request = await requests.next()!
        backend.emit(.finished, id: request.id)
        try await next.wait()
        try expect(oldEvents == countAfterStop, "stale events must be discarded")
        try expect(backend.stoppedIDs == [old], "stale cancellation must not stop the new stream")
        session.stop()
    }

    static func failureSettlesEntireQueue() async throws {
        let backend = Backend()
        let session = SpeechPlaybackQueueSession(backend: backend)
        let stream = session.begin()
        let completions = try (0..<3).map { _ in try session.enqueue(pcm16: Data(), streamID: stream, rate: 1, volume: 1) }
        var requests = backend.requests.makeAsyncIterator()
        let request = await requests.next()!
        backend.emit(.failed(InjectedError.setup), id: request.id)
        for completion in completions {
            do { try await completion.wait(); throw Failure(description: "failure was lost") }
            catch let error as InjectedError { try expect(error == .setup, "wrong failure") }
        }
        do {
            _ = try session.enqueue(pcm16: Data(), streamID: stream, rate: 1, volume: 1)
            throw Failure(description: "failed stream accepted new buffers")
        } catch is CancellationError {}
        try expect(backend.stoppedIDs == [stream], "failure must stop scheduled buffers")
    }

    static func synchronousAndDuplicateEvents() async throws {
        let backend = Backend()
        backend.synchronousEvents = true
        let session = SpeechPlaybackQueueSession(backend: backend)
        let stream = session.begin()
        var starts = 0, finishes = 0
        let completion = try session.enqueue(pcm16: Data(), streamID: stream, rate: 1, volume: 1) {
            if case .started = $0 { starts += 1 }
            if case .finished = $0 { finishes += 1 }
        }
        try await completion.wait()
        try expect(starts == 1 && finishes == 1, "duplicate events must settle once")
        session.stop()
    }

    static func lateBufferKeepsSameStream() async throws {
        let backend = Backend()
        let session = SpeechPlaybackQueueSession(backend: backend)
        let stream = session.begin()
        var requests = backend.requests.makeAsyncIterator()
        let first = try session.enqueue(pcm16: Data(), streamID: stream, rate: 1, volume: 1)
        let r0 = await requests.next()!
        backend.emit(.finished, id: r0.id)
        try await first.wait()
        // Synthesis fell behind and the audio queue became temporarily empty.
        let next = try session.enqueue(pcm16: Data(), streamID: stream, rate: 1, volume: 1)
        let r1 = await requests.next()!
        try expect(r1.streamID == r0.streamID && backend.stoppedIDs.isEmpty, "underflow must not end/recreate the stream")
        backend.emit(.finished, id: r1.id)
        try await next.wait()
        session.stop()
    }

    static func cancellationStopsAllBuffers() async throws {
        let backend = Backend()
        let session = SpeechPlaybackQueueSession(backend: backend)
        let stream = session.begin()
        let a = try session.enqueue(pcm16: Data(), streamID: stream, rate: 1, volume: 1)
        let b = try session.enqueue(pcm16: Data(), streamID: stream, rate: 1, volume: 1)
        let waiting = Gate()
        let task = Task { waiting.signal(); try await a.wait() }
        await waiting.wait()
        task.cancel()
        _ = await task.result
        try await cancelled(b)
        try expect(backend.stoppedIDs == [stream], "waiting task cancellation must stop the whole stream")
    }

    static func pipelinePrequeuesWithBoundedLookahead() async throws {
        let backend = Backend()
        let session = SpeechPlaybackQueueSession(backend: backend)
        let stream = session.begin()
        var completions: [Int: SpeechPlaybackCompletion] = [:]
        var synthesized: [Int] = []
        var consumed: [Int] = []
        let task = Task {
            try await SpeechPlaybackPipeline.play(chunks: (0..<5).map(String.init)) { text in
                synthesized.append(Int(text)!)
                return Data(text.utf8)
            } enqueue: { pcm, index in
                completions[index] = try session.enqueue(pcm16: pcm, streamID: stream, rate: 1, volume: 1)
            } stopPlayback: { session.stop(streamID: stream) } play: { pcm, index in
                try expect(pcm.isEmpty, "pipeline must not retain PCM already owned by backend")
                consumed.append(index)
                try await completions.removeValue(forKey: index)!.wait()
            }
        }
        var requests = backend.requests.makeAsyncIterator()
        let r0 = await requests.next()!
        let r1 = await requests.next()!
        let r2 = await requests.next()!
        try expect(synthesized == [0, 1, 2], "at most two chunks ahead of playing chunk")
        try expect(consumed == [0], "next buffers must enqueue BEFORE previous completion")
        try expect([r0.payload, r1.payload, r2.payload] == ["0", "1", "2"], "prequeue order")
        backend.emit(.finished, id: r0.id)
        let r3 = await requests.next()!
        try expect(synthesized == [0, 1, 2, 3], "window advances only with playback")
        backend.emit(.finished, id: r1.id)
        let r4 = await requests.next()!
        for request in [r2, r3, r4] { backend.emit(.finished, id: request.id) }
        try await task.value
        try expect(consumed == [0, 1, 2, 3, 4], "all queued completions drained in order")
        try expect(completions.isEmpty, "completion handles released")
        session.stop()
    }

    static func cancellationStopsAudioBeforeLateSynthesis() async throws {
        let backend = Backend()
        let session = SpeechPlaybackQueueSession(backend: backend)
        let stream = session.begin()
        let lateStarted = Gate(), releaseLate = Gate()
        var completions: [Int: SpeechPlaybackCompletion] = [:]
        var enqueued: [Int] = []
        let task = Task {
            try await SpeechPlaybackPipeline.play(chunks: ["0", "1", "2"]) { text in
                if text == "1" { lateStarted.signal(); await releaseLate.wait() }
                return Data(text.utf8) // Deliberately ignores cancellation.
            } enqueue: { pcm, index in
                enqueued.append(index)
                completions[index] = try session.enqueue(pcm16: pcm, streamID: stream, rate: 1, volume: 1)
            } stopPlayback: { session.stop(streamID: stream) } play: { _, index in
                try await completions.removeValue(forKey: index)!.wait()
            }
        }
        await lateStarted.wait()
        task.cancel()
        var stops = backend.stopped.makeAsyncIterator()
        let stoppedID = await stops.next()
        try expect(stoppedID == stream, "audio must stop before native synthesis unwinds")
        releaseLate.signal()
        do { try await task.value; throw Failure(description: "expected pipeline cancellation") }
        catch is CancellationError {}
        try expect(enqueued == [0], "late native result must never be queued")
    }

    static func enqueuedPCMIsReleasedByPipeline() async throws {
        let counter = PCMReleaseCounter()
        let backend = Backend()
        let session = SpeechPlaybackQueueSession(backend: backend)
        let stream = session.begin()
        var completions: [Int: SpeechPlaybackCompletion] = [:]
        let task = Task {
            try await SpeechPlaybackPipeline.play(chunks: ["0", "1"]) { text in
                if text == "0" { return counter.makePCM() }
                try expect(counter.value == 1, "predecessor task retained PCM after enqueue")
                return Data("1".utf8)
            } enqueue: { pcm, index in
                completions[index] = try session.enqueue(pcm16: pcm, streamID: stream, rate: 1, volume: 1)
            } stopPlayback: { session.stop(streamID: stream) } play: { _, index in
                try await completions.removeValue(forKey: index)!.wait()
            }
        }
        var requests = backend.requests.makeAsyncIterator()
        let r0 = await requests.next()!
        let r1 = await requests.next()!
        try expect(counter.value == 1, "ready buffer retained enqueued PCM during playback")
        backend.emit(.finished, id: r0.id)
        backend.emit(.finished, id: r1.id)
        try await task.value
        session.stop()
    }

    static func enqueueFailureStopsPlayback() async throws {
        var stopped = false
        do {
            try await SpeechPlaybackPipeline.play(chunks: ["0"]) { Data($0.utf8) }
            enqueue: { _, _ in throw InjectedError.setup }
            stopPlayback: { stopped = true }
            play: { _, _ in throw Failure(description: "failed enqueue cannot play") }
            throw Failure(description: "expected enqueue failure")
        } catch let error as InjectedError { try expect(error == .setup, "enqueue error preserved") }
        try expect(stopped, "enqueue failure must stop prequeued audio")
    }

    static func main() async {
        let tests: [(String, @MainActor () async throws -> Void)] = [
            ("prequeueAndEarlyCompletion", prequeueAndEarlyCompletion),
            ("replacementAndLateCancellation", replacementAndLateCancellation),
            ("failureSettlesEntireQueue", failureSettlesEntireQueue),
            ("synchronousAndDuplicateEvents", synchronousAndDuplicateEvents),
            ("lateBufferKeepsSameStream", lateBufferKeepsSameStream),
            ("cancellationStopsAllBuffers", cancellationStopsAllBuffers),
            ("pipelinePrequeuesWithBoundedLookahead", pipelinePrequeuesWithBoundedLookahead),
            ("cancellationStopsAudioBeforeLateSynthesis", cancellationStopsAudioBeforeLateSynthesis),
            ("enqueuedPCMIsReleasedByPipeline", enqueuedPCMIsReleasedByPipeline),
            ("enqueueFailureStopsPlayback", enqueueFailureStopsPlayback)
        ]
        var failures = 0
        for (name, test) in tests {
            do { try await test(); print("PASS \(name)") }
            catch { failures += 1; print("FAIL \(name): \(error)") }
        }
        print("\(tests.count - failures)/\(tests.count) tests passed")
        if failures > 0 { exit(1) }
    }
}
