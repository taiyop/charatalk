import Foundation

// Standalone regression harness for Sources/IrodoriTTS/SpeechPlaybackPipeline.swift.
//
// The tests use explicit asynchronous gates for sequencing instead of sleeps.
// Compile as a standalone executable:
//
//   swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
//     Sources/IrodoriTTS/SpeechPlaybackPipeline.swift \
//     Tests/SpeechPlaybackPipelineTests.swift -o "$BIN_DIR/pipeline-tests"

struct TestFailure: Error, CustomStringConvertible, Sendable {
    let message: String
    var description: String { message }
}

enum TestError: Error, Equatable, Sendable {
    case synthesis(Int)
    case playback(Int)
}

/// One-shot, thread-safe signal used to observe work that may finish on a
/// different executor (notably `withTaskCancellationHandler`'s `onCancel`).
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

/// A release gate for deterministic MainActor sequencing.
@MainActor
final class AsyncGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if opened {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }

    func open() {
        guard !opened else { return }
        opened = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}

/// A gate that also resumes its waiter when the owning task is cancelled.
/// `wait()` returns `false` when cancellation won the race.
final class CancellableGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var cancelled = false
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    func wait() async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                lock.lock()
                if opened || cancelled {
                    let result = opened
                    lock.unlock()
                    continuation.resume(returning: result)
                } else {
                    waiters.append(continuation)
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            cancelled = true
            let pending = waiters
            waiters.removeAll()
            lock.unlock()
            for waiter in pending {
                waiter.resume(returning: false)
            }
        }
    }

    func open() {
        lock.lock()
        opened = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for waiter in pending {
            waiter.resume(returning: true)
        }
    }
}

/// Counts releases of no-copy PCM buffers without relying on process memory
/// figures. Each synthesized chunk allocates one buffer, and its custom
/// deallocator increments the counter exactly once when the last Data
/// reference goes away.
final class DeallocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func recordDeallocation() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Returns PCM whose storage is released deterministically, so tests can tell
/// whether the pipeline still retains a consumed chunk.
func makePCMBuffer(index: Int, counter: DeallocationCounter) -> Data {
    let byteCount = 64
    let pointer = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 1)
    _ = pointer.initializeMemory(as: UInt8.self, repeating: UInt8(truncatingIfNeeded: index), count: byteCount)
    return Data(bytesNoCopy: pointer, count: byteCount, deallocator: .custom { pointer, _ in
        pointer.deallocate()
        counter.recordDeallocation()
    })
}

@MainActor
final class Recorder {
    private(set) var events: [String] = []
    private(set) var synthIndices: [Int] = []
    private(set) var synthEnds: [Int] = []
    private(set) var playIndices: [Int] = []
    private(set) var playedPayloads: [String] = []
    private(set) var maxActiveSynth = 0
    private(set) var maxActivePlay = 0
    private(set) var cancellationSeenInSynthesis = false
    private(set) var pipelineEvents: [SpeechPlaybackPipeline.Event] = []
    var observedCancellationAtLateReturn = false

    func recordPipelineEvent(_ event: SpeechPlaybackPipeline.Event) {
        pipelineEvents.append(event)
    }

    private var activeSynth = 0
    private var activePlay = 0

    func synthStart(_ index: Int) {
        synthIndices.append(index)
        activeSynth += 1
        maxActiveSynth = max(maxActiveSynth, activeSynth)
        events.append("synthStart(\(index))")
    }

    func synthEnd(_ index: Int) {
        synthEnds.append(index)
        activeSynth -= 1
        events.append("synthEnd(\(index))")
    }

    func synthCancelled(_ index: Int) {
        cancellationSeenInSynthesis = true
        events.append("synthCancelled(\(index))")
    }

    func playStart(_ index: Int, _ data: Data) {
        playIndices.append(index)
        playedPayloads.append(String(decoding: data, as: UTF8.self))
        activePlay += 1
        maxActivePlay = max(maxActivePlay, activePlay)
        events.append("playStart(\(index))")
    }

    func playEnd(_ index: Int) {
        activePlay -= 1
        events.append("playEnd(\(index))")
    }

    func eventIndex(_ event: String) -> Int? {
        events.firstIndex(of: event)
    }
}

@main
struct SpeechPlaybackPipelineTests {
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

    static func expectThrows<T: Error & Equatable>(
        _ label: String,
        _ expected: T,
        _ operation: @MainActor () async throws -> Void
    ) async throws {
        do {
            try await operation()
            throw TestFailure(message: "\(label): expected \(expected), but no error was thrown")
        } catch let failure as TestFailure {
            throw failure
        } catch let error as T {
            guard error == expected else {
                throw TestFailure(message: "\(label): expected \(expected), got \(error)")
            }
        } catch {
            throw TestFailure(message: "\(label): expected \(expected), got \(error)")
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

    // MARK: - Timing event assertions

    struct Milestones {
        var synthesisStarted: [Int] = []
        var synthesisCompleted: [Int] = []
        var playbackWaits: [Int] = []
        var playbackStarted: [Int] = []
        var playbackCompleted: [Int] = []
    }

    static func eventDescriptions(_ events: [SpeechPlaybackPipeline.Event]) -> [String] {
        events.map { event in
            switch event {
            case .synthesisStarted(let index):
                return "synthesisStarted(\(index))"
            case .synthesisCompleted(let index, _):
                return "synthesisCompleted(\(index))"
            case .playbackWaitCompleted(let index, _):
                return "playbackWaitCompleted(\(index))"
            case .playbackStarted(let index):
                return "playbackStarted(\(index))"
            case .playbackCompleted(let index, _):
                return "playbackCompleted(\(index))"
            }
        }
    }

    static func milestones(_ events: [SpeechPlaybackPipeline.Event]) -> Milestones {
        var result = Milestones()
        for event in events {
            switch event {
            case .synthesisStarted(let index):
                result.synthesisStarted.append(index)
            case .synthesisCompleted(let index, _):
                result.synthesisCompleted.append(index)
            case .playbackWaitCompleted(let index, _):
                result.playbackWaits.append(index)
            case .playbackStarted(let index):
                result.playbackStarted.append(index)
            case .playbackCompleted(let index, _):
                result.playbackCompleted.append(index)
            }
        }
        return result
    }

    static func playbackWaitElapsed(
        _ events: [SpeechPlaybackPipeline.Event],
        index: Int
    ) -> TimeInterval? {
        for event in events {
            if case .playbackWaitCompleted(let eventIndex, let elapsed) = event, eventIndex == index {
                return elapsed
            }
        }
        return nil
    }

    /// Checks strict lifecycle pairing and that every reported duration is
    /// nonnegative. Starts without completions are allowed at cancellation or
    /// failure boundaries; completions without a matching start are not.
    static func expectEventLifecycle(
        _ label: String,
        _ events: [SpeechPlaybackPipeline.Event]
    ) throws {
        var synthesizing: Int?
        var playing: Int?
        var synthesized: Set<Int> = []
        var waited: Set<Int> = []
        var completed: Set<Int> = []

        for event in events {
            switch event {
            case .synthesisStarted(let index):
                try expectTrue("\(label): synthesis is serial", synthesizing == nil)
                synthesizing = index
            case .synthesisCompleted(let index, let elapsed):
                try expectEqual("\(label): synthesis completion matches its start", synthesizing, index)
                try expectTrue("\(label): synthesis duration is nonnegative", elapsed >= 0)
                synthesized.insert(index)
                synthesizing = nil
            case .playbackWaitCompleted(let index, let elapsed):
                try expectTrue("\(label): playback wait duration is nonnegative", elapsed >= 0)
                try expectTrue(
                    "\(label): playback waits only for a finished synthesis",
                    synthesized.contains(index)
                )
                try expectTrue("\(label): playback waits are unique", waited.insert(index).inserted)
                try expectTrue("\(label): playback does not wait mid-playback", playing == nil)
            case .playbackStarted(let index):
                try expectTrue("\(label): playback is serial", playing == nil)
                try expectTrue("\(label): playback waits before it starts", waited.contains(index))
                playing = index
            case .playbackCompleted(let index, let elapsed):
                try expectEqual("\(label): playback completion matches its start", playing, index)
                try expectTrue("\(label): playback duration is nonnegative", elapsed >= 0)
                try expectTrue("\(label): playback completes once", completed.insert(index).inserted)
                playing = nil
            }
        }
    }

    static func expectMilestoneOrder(
        _ label: String,
        _ events: [SpeechPlaybackPipeline.Event],
        index: Int
    ) throws {
        func position(
            _ kind: String,
            _ predicate: (SpeechPlaybackPipeline.Event) -> Bool
        ) throws -> Int {
            guard let found = events.firstIndex(where: predicate) else {
                throw TestFailure(message: "\(label): missing \(kind)(\(index))")
            }
            return found
        }

        let synthesis = try position("synthesisCompleted") { event in
            if case .synthesisCompleted(let eventIndex, _) = event { return eventIndex == index }
            return false
        }
        let wait = try position("playbackWaitCompleted") { event in
            if case .playbackWaitCompleted(let eventIndex, _) = event { return eventIndex == index }
            return false
        }
        let start = try position("playbackStarted") { event in
            if case .playbackStarted(let eventIndex) = event { return eventIndex == index }
            return false
        }
        let completion = try position("playbackCompleted") { event in
            if case .playbackCompleted(let eventIndex, _) = event { return eventIndex == index }
            return false
        }

        try expectTrue(
            "\(label): synthesis precedes playback wait for \(index)",
            synthesis < wait
        )
        try expectTrue(
            "\(label): playback wait precedes playback start for \(index)",
            wait < start
        )
        try expectTrue(
            "\(label): playback start precedes completion for \(index)",
            start < completion
        )
    }

    // MARK: - Tests

    @MainActor
    static func testEmptyChunks() async throws {
        let recorder = Recorder()
        let synthesize: @MainActor (String) async throws -> Data = { _ in
            throw TestFailure(message: "empty chunks must not synthesize")
        }
        let play: @MainActor (Data, Int) async throws -> Void = { _, _ in
            throw TestFailure(message: "empty chunks must not play")
        }

        try await SpeechPlaybackPipeline.play(
            chunks: [],
            onEvent: recorder.recordPipelineEvent,
            synthesize: synthesize,
            play: play
        )
        try expectEqual("empty chunks do not synthesize", recorder.synthIndices, [])
        try expectEqual("empty chunks do not play", recorder.playIndices, [])
        try expectEqual("empty chunks emit no timing events", recorder.pipelineEvents, [])
    }

    @MainActor
    static func testSingleChunk() async throws {
        let recorder = Recorder()
        let synthStarted = Event()
        let synthGate = AsyncGate()

        let synthesize: @MainActor (String) async throws -> Data = { text in
            recorder.synthStart(0)
            synthStarted.signal()
            await synthGate.wait()
            recorder.synthEnd(0)
            return Data("pcm-\(text)".utf8)
        }
        let play: @MainActor (Data, Int) async throws -> Void = { data, index in
            recorder.playStart(index, data)
            recorder.playEnd(index)
        }

        let task = Task { @MainActor in
            try await SpeechPlaybackPipeline.play(
                chunks: ["only"],
                onEvent: recorder.recordPipelineEvent,
                synthesize: synthesize,
                play: play
            )
        }

        await synthStarted.wait()
        try expectEqual("single chunk does not play before synthesis completes", recorder.playIndices, [])
        synthGate.open()
        try await task.value

        try expectEqual("single chunk synthesized once", recorder.synthIndices, [0])
        try expectEqual("single chunk played once", recorder.playIndices, [0])
        try expectEqual("single chunk payload", recorder.playedPayloads, ["pcm-only"])
        try expectEqual("single chunk synthesis serial", recorder.maxActiveSynth, 1)
        try expectEqual("single chunk playback serial", recorder.maxActivePlay, 1)
        try expectEqual(
            "single chunk event order",
            eventDescriptions(recorder.pipelineEvents),
            [
                "synthesisStarted(0)",
                "synthesisCompleted(0)",
                "playbackWaitCompleted(0)",
                "playbackStarted(0)",
                "playbackCompleted(0)"
            ]
        )
        try expectEventLifecycle("single chunk lifecycle", recorder.pipelineEvents)
        try expectEqual(
            "single chunk is already buffered at the playback boundary",
            playbackWaitElapsed(recorder.pipelineEvents, index: 0),
            0
        )
    }

    @MainActor
    static func testFirstChunkStartupLookaheadAndOrder() async throws {
        let chunkCount = 5
        let chunks = (0..<chunkCount).map(String.init)
        let recorder = Recorder()
        let synthGates = (0..<chunkCount).map { _ in AsyncGate() }
        let playGates = (0..<chunkCount).map { _ in AsyncGate() }
        let synthStarted = (0..<chunkCount).map { _ in Event() }
        let playStarted = (0..<chunkCount).map { _ in Event() }

        let synthesize: @MainActor (String) async throws -> Data = { text in
            let index = Int(text) ?? -1
            recorder.synthStart(index)
            synthStarted[index].signal()
            await synthGates[index].wait()
            recorder.synthEnd(index)
            return Data("pcm-\(index)".utf8)
        }
        let play: @MainActor (Data, Int) async throws -> Void = { data, index in
            recorder.playStart(index, data)
            playStarted[index].signal()
            await playGates[index].wait()
            recorder.playEnd(index)
        }

        let task = Task { @MainActor in
            try await SpeechPlaybackPipeline.play(
                chunks: chunks,
                onEvent: recorder.recordPipelineEvent,
                synthesize: synthesize,
                play: play
            )
        }

        // First synthesis is held; nothing may play yet.
        await synthStarted[0].wait()
        try expectEqual("no playback during first synthesis", recorder.playIndices, [])
        synthGates[0].open()

        // The first chunk alone starts playback. The second chunk is still
        // held, so the first chunk does not wait for a two-chunk startup.
        await playStarted[0].wait()
        try expectEqual("playback starts after only the first chunk", recorder.playIndices, [0])
        try expectEqual(
            "first chunk wait is zero",
            playbackWaitElapsed(recorder.pipelineEvents, index: 0),
            0
        )

        // The lookahead begins synthesizing the held second chunk while the
        // first chunk plays. The third chunk waits behind it.
        await synthStarted[1].wait()
        try expectTrue("second chunk is still synthesizing during first playback", !synthStarted[2].isSignaled)
        try expectTrue("bounded lookahead does not schedule a fourth chunk", !synthStarted[3].isSignaled)
        try expectTrue("second chunk did not finish while held", !recorder.synthEnds.contains(1))

        synthGates[1].open()
        await synthStarted[2].wait()
        try expectEqual("third synthesis waits for the second", recorder.synthIndices, [0, 1, 2])
        try expectEqual("only first chunk is playing", recorder.playIndices, [0])
        try expectTrue("bounded lookahead does not schedule a fourth chunk", !synthStarted[3].isSignaled)

        // Let playback of chunk 0 finish. Chunk 1 is now buffered, so it
        // starts with no playback wait. During its playback chunk 3 may be
        // scheduled, but not chunk 4.
        playGates[0].open()
        synthGates[2].open()
        await playStarted[1].wait()
        await synthStarted[3].wait()
        try expectEqual("lookahead remains two chunks ahead", recorder.synthIndices, [0, 1, 2, 3])
        try expectEqual("playback order so far", recorder.playIndices, [0, 1])
        try expectTrue("bounded lookahead does not schedule a fifth chunk", !synthStarted[4].isSignaled)
        try expectEqual(
            "second chunk was buffered before its playback",
            playbackWaitElapsed(recorder.pipelineEvents, index: 1),
            0
        )

        // Release everything and let the response finish.
        for gate in synthGates { gate.open() }
        for gate in playGates { gate.open() }
        try await task.value

        // The first chunk was audible before the second finished synthesizing.
        guard let firstPlayStart = recorder.eventIndex("playStart(0)"),
              let secondSynthEnd = recorder.eventIndex("synthEnd(1)") else {
            throw TestFailure(message: "startup ordering milestones are missing")
        }
        try expectTrue(
            "first playback starts before the second synthesis completes",
            firstPlayStart < secondSynthEnd
        )

        try expectEqual("all chunks synthesized once", recorder.synthIndices, Array(0..<chunkCount))
        try expectEqual("ordered playback", recorder.playIndices, Array(0..<chunkCount))
        try expectEqual(
            "ordered payloads",
            recorder.playedPayloads,
            (0..<chunkCount).map { "pcm-\($0)" }
        )
        try expectEqual("synthesis is strictly serial", recorder.maxActiveSynth, 1)
        try expectEqual("playback is serial", recorder.maxActivePlay, 1)

        let timing = milestones(recorder.pipelineEvents)
        let allIndices = Array(0..<chunkCount)
        try expectEqual("timing synthesis starts", timing.synthesisStarted, allIndices)
        try expectEqual("timing synthesis completions", timing.synthesisCompleted, allIndices)
        try expectEqual("timing playback waits", timing.playbackWaits, allIndices)
        try expectEqual("timing playback starts", timing.playbackStarted, allIndices)
        try expectEqual("timing playback completions", timing.playbackCompleted, allIndices)
        try expectEventLifecycle("startup timing lifecycle", recorder.pipelineEvents)
        for index in allIndices {
            try expectMilestoneOrder("startup timing order", recorder.pipelineEvents, index: index)
        }
        try expectEqual(
            "first chunk startup wait is excluded and zero",
            playbackWaitElapsed(recorder.pipelineEvents, index: 0),
            0
        )
    }

    @MainActor
    static func testTwoChunksPlayFirstWhileSecondSynthesizes() async throws {
        let recorder = Recorder()
        let synthGates = (0..<2).map { _ in AsyncGate() }
        let playGates = (0..<2).map { _ in AsyncGate() }
        let synthStarted = (0..<2).map { _ in Event() }
        let playStarted = (0..<2).map { _ in Event() }

        let synthesize: @MainActor (String) async throws -> Data = { text in
            let index = Int(text) ?? -1
            recorder.synthStart(index)
            synthStarted[index].signal()
            await synthGates[index].wait()
            recorder.synthEnd(index)
            return Data("pcm-\(index)".utf8)
        }
        let play: @MainActor (Data, Int) async throws -> Void = { data, index in
            recorder.playStart(index, data)
            playStarted[index].signal()
            await playGates[index].wait()
            recorder.playEnd(index)
        }

        let task = Task { @MainActor in
            try await SpeechPlaybackPipeline.play(
                chunks: ["0", "1"],
                onEvent: recorder.recordPipelineEvent,
                synthesize: synthesize,
                play: play
            )
        }

        await synthStarted[0].wait()
        try expectEqual("nothing plays before the first chunk is ready", recorder.playIndices, [])
        synthGates[0].open()

        // The first chunk starts playing while the second is still held in
        // synthesis, proving startup no longer waits for two chunks.
        await playStarted[0].wait()
        await synthStarted[1].wait()
        try expectEqual("only the first chunk has been synthesized", recorder.synthEnds, [0])
        try expectEqual("first chunk plays while second is held", recorder.playIndices, [0])
        try expectTrue("second chunk has not started playing", !playStarted[1].isSignaled)
        try expectEqual(
            "the two-chunk response does not add a startup wait",
            playbackWaitElapsed(recorder.pipelineEvents, index: 0),
            0
        )

        let firstPlayStart = recorder.eventIndex("playStart(0)")
        try expectTrue("first playback start was recorded", firstPlayStart != nil)

        synthGates[1].open()
        playGates[0].open()
        await playStarted[1].wait()
        playGates[1].open()
        try await task.value

        if let firstPlayStart, let secondSynthEnd = recorder.eventIndex("synthEnd(1)") {
            try expectTrue(
                "first playback starts before the second synthesis completes",
                firstPlayStart < secondSynthEnd
            )
        } else {
            throw TestFailure(message: "second synthesis completion was not recorded")
        }

        try expectEqual("two chunks synthesized in order", recorder.synthIndices, [0, 1])
        try expectEqual("two chunks played in order", recorder.playIndices, [0, 1])
        try expectEqual("two chunk payloads", recorder.playedPayloads, ["pcm-0", "pcm-1"])
        try expectEqual("synthesis stayed serial", recorder.maxActiveSynth, 1)
        try expectEqual("playback stayed serial", recorder.maxActivePlay, 1)
        try expectEventLifecycle("two chunk lifecycle", recorder.pipelineEvents)
        let timing = milestones(recorder.pipelineEvents)
        try expectEqual("two chunk timing synthesis starts", timing.synthesisStarted, [0, 1])
        try expectEqual("two chunk timing synthesis completions", timing.synthesisCompleted, [0, 1])
        try expectEqual("two chunk timing playback waits", timing.playbackWaits, [0, 1])
        try expectEqual("two chunk timing playback starts", timing.playbackStarted, [0, 1])
        try expectEqual("two chunk timing playback completions", timing.playbackCompleted, [0, 1])
        for index in 0..<2 {
            try expectMilestoneOrder("two chunk milestone order", recorder.pipelineEvents, index: index)
        }
    }

    @MainActor
    static func testPlaybackWaitForLateChunk() async throws {
        let recorder = Recorder()
        let synthGates = (0..<3).map { _ in AsyncGate() }
        let playGates = (0..<3).map { _ in AsyncGate() }
        let synthStarted = (0..<3).map { _ in Event() }
        let playStarted = (0..<3).map { _ in Event() }
        let playFinished = (0..<3).map { _ in Event() }

        let synthesize: @MainActor (String) async throws -> Data = { text in
            let index = Int(text) ?? -1
            recorder.synthStart(index)
            synthStarted[index].signal()
            await synthGates[index].wait()
            recorder.synthEnd(index)
            return Data("pcm-\(index)".utf8)
        }
        let play: @MainActor (Data, Int) async throws -> Void = { data, index in
            recorder.playStart(index, data)
            playStarted[index].signal()
            await playGates[index].wait()
            recorder.playEnd(index)
            playFinished[index].signal()
        }

        let task = Task { @MainActor in
            try await SpeechPlaybackPipeline.play(
                chunks: (0..<3).map(String.init),
                onEvent: recorder.recordPipelineEvent,
                synthesize: synthesize,
                play: play
            )
        }

        // Only chunk 0 is buffered at startup. Chunks 1 and 2 are scheduled
        // while it plays; chunk 1 is intentionally held.
        await synthStarted[0].wait()
        synthGates[0].open()
        await playStarted[0].wait()
        await synthStarted[1].wait()
        try expectEqual("late chunk has not finished synthesizing", recorder.synthEnds, [0])
        try expectEqual(
            "playback has only reached the startup chunk",
            milestones(recorder.pipelineEvents).playbackWaits,
            [0]
        )

        // Finish chunk 1 while chunk 0 is still playing. It is then buffered
        // and plays without a boundary wait.
        synthGates[1].open()
        await synthStarted[2].wait()
        try expectEqual("second chunk finished during first playback", recorder.synthEnds, [0, 1])
        try expectEqual("first playback is still active", recorder.playIndices, [0])
        playGates[0].open()
        await playStarted[1].wait()
        try expectEqual(
            "buffered chunk never waits",
            playbackWaitElapsed(recorder.pipelineEvents, index: 1),
            0
        )

        // Chunk 2 is now the late chunk. Stop chunk 1 playback and park the
        // consumer at the playback boundary for chunk 2.
        playGates[1].open()
        await playFinished[1].wait()
        try expectEqual(
            "playback waits for the late chunk",
            milestones(recorder.pipelineEvents).playbackWaits,
            [0, 1]
        )
        try expectEqual(
            "playback must not start while the chunk is unavailable",
            milestones(recorder.pipelineEvents).playbackStarted,
            [0, 1]
        )
        try expectTrue("late chunk is still held at the boundary", !playStarted[2].isSignaled)
        try expectTrue(
            "late wait event is not emitted early",
            playbackWaitElapsed(recorder.pipelineEvents, index: 2) == nil
        )

        // Release chunk 2; its boundary wait completes, then playback starts.
        synthGates[2].open()
        await playStarted[2].wait()

        guard let lateWait = playbackWaitElapsed(recorder.pipelineEvents, index: 2) else {
            throw TestFailure(message: "late chunk wait duration is missing")
        }
        try expectTrue("late chunk wait duration is nonnegative", lateWait >= 0)
        try expectEventLifecycle("late chunk lifecycle", recorder.pipelineEvents)

        playGates[2].open()
        try await task.value

        let timing = milestones(recorder.pipelineEvents)
        let allIndices = Array(0..<3)
        try expectEqual("late chunk timing waits", timing.playbackWaits, allIndices)
        try expectEqual("late chunk timing playback starts", timing.playbackStarted, allIndices)
        try expectEqual("late chunk timing playback completions", timing.playbackCompleted, allIndices)
        try expectEventLifecycle("late chunk final lifecycle", recorder.pipelineEvents)
        for index in allIndices {
            try expectMilestoneOrder("late chunk final milestone order", recorder.pipelineEvents, index: index)
        }
        try expectEqual(
            "startup buffered wait stays zero",
            playbackWaitElapsed(recorder.pipelineEvents, index: 0),
            0
        )
    }

    @MainActor
    static func testSynthesisIsStrictlySerial() async throws {
        let chunkCount = 3
        let recorder = Recorder()
        let synthGates = (0..<chunkCount).map { _ in AsyncGate() }
        let playGates = (0..<chunkCount).map { _ in AsyncGate() }
        let synthStarted = (0..<chunkCount).map { _ in Event() }

        let synthesize: @MainActor (String) async throws -> Data = { text in
            let index = Int(text) ?? -1
            recorder.synthStart(index)
            synthStarted[index].signal()
            await synthGates[index].wait()
            recorder.synthEnd(index)
            return Data("pcm-\(index)".utf8)
        }
        let play: @MainActor (Data, Int) async throws -> Void = { data, index in
            recorder.playStart(index, data)
            await playGates[index].wait()
            recorder.playEnd(index)
        }

        let task = Task { @MainActor in
            try await SpeechPlaybackPipeline.play(
                chunks: (0..<chunkCount).map(String.init),
                onEvent: recorder.recordPipelineEvent,
                synthesize: synthesize,
                play: play
            )
        }

        await synthStarted[0].wait()
        try expectTrue("second synthesis waits for the first", !synthStarted[1].isSignaled)
        try expectEqual("only one synthesis started", recorder.synthIndices, [0])
        try expectEqual(
            "held synthesis has not completed",
            eventDescriptions(recorder.pipelineEvents),
            ["synthesisStarted(0)"]
        )

        synthGates[0].open()
        await synthStarted[1].wait()
        try expectEqual("second synthesis starts after the first", recorder.synthIndices, [0, 1])
        guard let firstSynthEnd = recorder.eventIndex("synthEnd(0)"),
              let secondSynthStart = recorder.eventIndex("synthStart(1)") else {
            throw TestFailure(message: "serial synthesis milestones are missing")
        }
        try expectTrue(
            "first synthesis completed before the second started",
            firstSynthEnd < secondSynthStart
        )

        for gate in synthGates { gate.open() }
        for gate in playGates { gate.open() }
        try await task.value

        try expectEqual("synthesis remains serial", recorder.maxActiveSynth, 1)
        try expectEqual("all chunks played", recorder.playIndices, [0, 1, 2])

        let timing = milestones(recorder.pipelineEvents)
        let allIndices = Array(0..<chunkCount)
        try expectEqual("serial timing synthesis starts", timing.synthesisStarted, allIndices)
        try expectEqual("serial timing synthesis completions", timing.synthesisCompleted, allIndices)
        try expectEqual("serial timing playback", timing.playbackStarted, allIndices)
        try expectEventLifecycle("serial timing lifecycle", recorder.pipelineEvents)
        for index in allIndices {
            try expectMilestoneOrder("serial timing order", recorder.pipelineEvents, index: index)
        }
    }

    @MainActor
    static func testOrderedPlaybackPayloads() async throws {
        let chunks = ["a", "b", "c", "d"]
        let recorder = Recorder()

        let synthesize: @MainActor (String) async throws -> Data = { text in
            let index = chunks.firstIndex(of: text) ?? -1
            recorder.synthStart(index)
            recorder.synthEnd(index)
            return Data("pcm-\(text)".utf8)
        }
        let play: @MainActor (Data, Int) async throws -> Void = { data, index in
            recorder.playStart(index, data)
            recorder.playEnd(index)
        }

        try await SpeechPlaybackPipeline.play(
            chunks: chunks,
            onEvent: recorder.recordPipelineEvent,
            synthesize: synthesize,
            play: play
        )

        try expectEqual("playback follows input order", recorder.playIndices, [0, 1, 2, 3])
        try expectEqual(
            "playback receives the matching payloads",
            recorder.playedPayloads,
            ["pcm-a", "pcm-b", "pcm-c", "pcm-d"]
        )
        try expectEqual("synthesis order follows input", recorder.synthIndices, [0, 1, 2, 3])
        try expectEqual("one playback at a time", recorder.maxActivePlay, 1)

        let timing = milestones(recorder.pipelineEvents)
        let allIndices = Array(0..<chunks.count)
        try expectEqual("ordered timing synthesis starts", timing.synthesisStarted, allIndices)
        try expectEqual("ordered timing synthesis completions", timing.synthesisCompleted, allIndices)
        try expectEqual("ordered timing playback waits", timing.playbackWaits, allIndices)
        try expectEqual("ordered timing playback starts", timing.playbackStarted, allIndices)
        try expectEqual("ordered timing playback completions", timing.playbackCompleted, allIndices)
        try expectEventLifecycle("ordered timing lifecycle", recorder.pipelineEvents)
        for index in allIndices {
            try expectMilestoneOrder("ordered timing order", recorder.pipelineEvents, index: index)
        }
    }

    @MainActor
    static func testFirstChunkSynthesisFailureNeverStartsPlayback() async throws {
        let recorder = Recorder()
        let expected = TestError.synthesis(0)

        try await expectThrows("first chunk synthesis error is preserved", expected) {
            try await SpeechPlaybackPipeline.play(
                chunks: ["0", "1"],
                onEvent: recorder.recordPipelineEvent
            ) { _ in
                recorder.synthStart(0)
                throw expected
            } play: { data, index in
                recorder.playStart(index, data)
                recorder.playEnd(index)
            }
        }

        try expectEqual("later chunks are never synthesized", recorder.synthIndices, [0])
        try expectEqual("failed startup never starts audio", recorder.playIndices, [])
        try expectEqual(
            "failed startup never claims synthesis or playback completion",
            eventDescriptions(recorder.pipelineEvents),
            ["synthesisStarted(0)"]
        )
    }

    @MainActor
    static func testSynthesisErrorAfterFirstChunkIsPreserved() async throws {
        let recorder = Recorder()
        let expected = TestError.synthesis(1)

        let synthesize: @MainActor (String) async throws -> Data = { text in
            let index = Int(text) ?? -1
            recorder.synthStart(index)
            if index == 1 {
                recorder.synthEnd(index)
                throw expected
            }
            recorder.synthEnd(index)
            return Data("pcm-\(index)".utf8)
        }
        let play: @MainActor (Data, Int) async throws -> Void = { data, index in
            recorder.playStart(index, data)
            recorder.playEnd(index)
        }

        let task = Task { @MainActor in
            try await SpeechPlaybackPipeline.play(
                chunks: (0..<3).map(String.init),
                onEvent: recorder.recordPipelineEvent,
                synthesize: synthesize,
                play: play
            )
        }

        try await expectThrows("synthesis error is preserved", expected) {
            try await task.value
        }
        try expectEqual("synthesis stops at the failing chunk", recorder.synthIndices, [0, 1])
        try expectEqual("only the already-ready chunk plays", recorder.playIndices, [0])

        let timing = milestones(recorder.pipelineEvents)
        try expectEqual("first chunk playback started", timing.playbackStarted, [0])
        try expectEqual("first chunk playback completed", timing.playbackCompleted, [0])
        try expectEqual("failure never cancels a completed synthesis", timing.synthesisCompleted, [0])
        try expectTrue(
            "failed synthesis never claims completion",
            !timing.synthesisCompleted.contains(1)
        )
        try expectTrue(
            "failed chunk never emits a playback wait",
            playbackWaitElapsed(recorder.pipelineEvents, index: 1) == nil
        )
        try expectEventLifecycle("synthesis error lifecycle", recorder.pipelineEvents)
        try expectMilestoneOrder("synthesis error first chunk order", recorder.pipelineEvents, index: 0)
    }

    @MainActor
    static func testPlaybackErrorIsPreservedAndStopsPlayback() async throws {
        let recorder = Recorder()
        let expected = TestError.playback(1)

        let synthesize: @MainActor (String) async throws -> Data = { text in
            let index = Int(text) ?? -1
            recorder.synthStart(index)
            recorder.synthEnd(index)
            return Data("pcm-\(index)".utf8)
        }
        let play: @MainActor (Data, Int) async throws -> Void = { data, index in
            recorder.playStart(index, data)
            if index == 1 {
                throw expected
            }
            recorder.playEnd(index)
        }

        let task = Task { @MainActor in
            try await SpeechPlaybackPipeline.play(
                chunks: (0..<4).map(String.init),
                onEvent: recorder.recordPipelineEvent,
                synthesize: synthesize,
                play: play
            )
        }

        try await expectThrows("playback error is preserved", expected) {
            try await task.value
        }
        try expectEqual("playback stops at the failing chunk", recorder.playIndices, [0, 1])

        let timing = milestones(recorder.pipelineEvents)
        try expectEqual("playback error started only reached chunks", timing.playbackStarted, [0, 1])
        try expectEqual("failing playback never claims completion", timing.playbackCompleted, [0])
        try expectEventLifecycle("playback error lifecycle", recorder.pipelineEvents)
        try expectMilestoneOrder("playback error order", recorder.pipelineEvents, index: 0)
    }

    @MainActor
    static func testCancellationCancelsOutstandingSynthesis() async throws {
        let recorder = Recorder()
        let synthStarted = Event()
        let cancellationSeen = Event()
        let gate = CancellableGate()

        let synthesize: @MainActor (String) async throws -> Data = { text in
            let index = Int(text) ?? -1
            recorder.synthStart(index)
            synthStarted.signal()
            let allowed = await gate.wait()
            if !allowed {
                recorder.synthCancelled(index)
                cancellationSeen.signal()
                throw CancellationError()
            }
            recorder.synthEnd(index)
            return Data("pcm-\(index)".utf8)
        }
        let play: @MainActor (Data, Int) async throws -> Void = { data, index in
            recorder.playStart(index, data)
            recorder.playEnd(index)
        }

        let task = Task { @MainActor in
            try await SpeechPlaybackPipeline.play(
                chunks: (0..<3).map(String.init),
                onEvent: recorder.recordPipelineEvent,
                synthesize: synthesize,
                play: play
            )
        }

        await synthStarted.wait()
        task.cancel()
        await cancellationSeen.wait()

        try await expectCancellation("pipeline reports cancellation") {
            try await task.value
        }
        try expectEqual("only the in-flight synthesis started", recorder.synthIndices, [0])
        try expectTrue("synthesis observed native cancellation", recorder.cancellationSeenInSynthesis)
        try expectEqual("cancelled synthesis never plays", recorder.playIndices, [])
        try expectEqual(
            "cancelled synthesis never claims completion",
            eventDescriptions(recorder.pipelineEvents),
            ["synthesisStarted(0)"]
        )
        try expectEventLifecycle("cancelled synthesis lifecycle", recorder.pipelineEvents)
    }

    @MainActor
    static func testCancellationAfterPlayback() async throws {
        let recorder = Recorder()
        let playStarted = Event()
        let playGate = AsyncGate()

        let synthesize: @MainActor (String) async throws -> Data = { text in
            let index = Int(text) ?? -1
            recorder.synthStart(index)
            recorder.synthEnd(index)
            return Data("pcm-\(index)".utf8)
        }
        let play: @MainActor (Data, Int) async throws -> Void = { data, index in
            recorder.playStart(index, data)
            playStarted.signal()
            await playGate.wait()
            recorder.playEnd(index)
        }

        let task = Task { @MainActor in
            try await SpeechPlaybackPipeline.play(
                chunks: (0..<3).map(String.init),
                onEvent: recorder.recordPipelineEvent,
                synthesize: synthesize,
                play: play
            )
        }

        await playStarted.wait()
        task.cancel()
        playGate.open()

        try await expectCancellation("cancellation after playback is reported") {
            try await task.value
        }
        try expectEqual("playback stops after cancellation", recorder.playIndices, [0])

        let timing = milestones(recorder.pipelineEvents)
        try expectEqual("cancelled playback started once", timing.playbackStarted, [0])
        try expectEqual("cancelled playback never claims completion", timing.playbackCompleted, [])
        try expectEventLifecycle("cancelled playback lifecycle", recorder.pipelineEvents)
    }

    @MainActor
    static func testNoncooperativeCancellationLateReturnIsNotPlayed() async throws {
        let recorder = Recorder()
        let synthStarted = Event()
        let cancellationObserved = Event()
        let synthesisReturned = Event()
        let release = AsyncGate()

        let synthesize: @MainActor (String) async throws -> Data = { text in
            let index = Int(text) ?? -1
            recorder.synthStart(index)
            synthStarted.signal()

            // Deliberately ignore cancellation and keep waiting. The pipeline
            // must still cancel the task and discard this late result.
            await withTaskCancellationHandler {
                await release.wait()
            } onCancel: {
                cancellationObserved.signal()
            }

            recorder.synthEnd(index)
            recorder.observedCancellationAtLateReturn = Task.isCancelled
            synthesisReturned.signal()
            return Data("late-\(index)".utf8)
        }
        let play: @MainActor (Data, Int) async throws -> Void = { data, index in
            recorder.playStart(index, data)
            recorder.playEnd(index)
        }

        let task = Task { @MainActor in
            try await SpeechPlaybackPipeline.play(
                chunks: (0..<3).map(String.init),
                onEvent: recorder.recordPipelineEvent,
                synthesize: synthesize,
                play: play
            )
        }

        await synthStarted.wait()
        task.cancel()
        await cancellationObserved.wait()

        // Release the noncooperative synthesis only after cancellation has
        // reached it. Its late Data must not be played.
        release.open()
        await synthesisReturned.wait()

        try await expectCancellation("late noncooperative synthesis still cancels the pipeline") {
            try await task.value
        }
        try expectTrue("late synthesis saw cancellation", recorder.observedCancellationAtLateReturn)
        try expectEqual("late result is discarded", recorder.playIndices, [])
        try expectEqual("no follow-up synthesis started", recorder.synthIndices, [0])
        try expectEqual(
            "late result never claims synthesis completion",
            eventDescriptions(recorder.pipelineEvents),
            ["synthesisStarted(0)"]
        )
        try expectEventLifecycle("late result lifecycle", recorder.pipelineEvents)
    }

    @MainActor
    static func testPlaybackFailureWaitsForLateLookahead() async throws {
        let thirdStarted = Event()
        let cancellationObserved = Event()
        let finished = Event()
        let release = AsyncGate()
        let recorder = Recorder()
        let expected = TestError.playback(0)

        let task = Task { @MainActor in
            defer { finished.signal() }
            try await SpeechPlaybackPipeline.play(
                chunks: ["0", "1", "2", "3"],
                onEvent: recorder.recordPipelineEvent
            ) { text in
                let index = Int(text)!
                recorder.synthStart(index)
                if index == 2 {
                    thirdStarted.signal()
                    await withTaskCancellationHandler {
                        await release.wait()
                    } onCancel: {
                        cancellationObserved.signal()
                    }
                }
                recorder.synthEnd(index)
                return Data(text.utf8)
            } play: { data, index in
                recorder.playStart(index, data)
                // Keep the native stand-in active when playback fails.
                await thirdStarted.wait()
                throw expected
            }
        }

        await cancellationObserved.wait()
        try expectTrue("cleanup awaits outstanding native synthesis before returning", !finished.isSignaled)
        release.open()
        try await expectThrows("cleanup preserves the playback error", expected) {
            try await task.value
        }
        try expectEqual("late lookahead drained before exit", recorder.synthEnds, [0, 1, 2])
        try expectEqual("no further synthesis after failure", recorder.synthIndices, [0, 1, 2])
        try expectEqual("no playback after failure", recorder.playIndices, [0])

        let timing = milestones(recorder.pipelineEvents)
        try expectEqual("failing playback started once", timing.playbackStarted, [0])
        try expectEqual("failing playback never claims completion", timing.playbackCompleted, [])
        try expectEqual(
            "cancelled lookahead never claims synthesis completion",
            timing.synthesisCompleted,
            [0, 1]
        )
        try expectEventLifecycle("playback failure lifecycle", recorder.pipelineEvents)
    }

    @MainActor
    static func testCancellationDuringPlaybackDrainsLateLookahead() async throws {
        let thirdStarted = Event()
        let cancellationObserved = Event()
        let finished = Event()
        let release = AsyncGate()
        let recorder = Recorder()

        let task = Task { @MainActor in
            defer { finished.signal() }
            try await SpeechPlaybackPipeline.play(chunks: ["0", "1", "2", "3"]) { text in
                let index = Int(text)!
                recorder.synthStart(index)
                if index == 2 {
                    thirdStarted.signal()
                    await withTaskCancellationHandler {
                        await release.wait()
                    } onCancel: {
                        cancellationObserved.signal()
                    }
                }
                recorder.synthEnd(index)
                return Data(text.utf8)
            } play: { data, index in
                recorder.playStart(index, data)
                await thirdStarted.wait()
                // Cancel this pipeline task at a deterministic playback boundary.
                withUnsafeCurrentTask { $0?.cancel() }
                recorder.playEnd(index)
            }
        }

        await cancellationObserved.wait()
        try expectTrue("cancelled playback waits for native cleanup", !finished.isSignaled)
        release.open()
        try await expectCancellation("cancelled lookahead is drained") {
            try await task.value
        }
        try expectEqual("cancelled native synthesis finished before exit", recorder.synthEnds, [0, 1, 2])
        try expectEqual("cancelled lookahead never plays", recorder.playIndices, [0])
    }

    @MainActor
    static func testConsumedChunksReleasePCM() async throws {
        let chunkCount = 5
        let recorder = Recorder()
        let counter = DeallocationCounter()
        let synthGates = (0..<chunkCount).map { _ in AsyncGate() }
        let playFinished = (0..<chunkCount).map { _ in Event() }
        var releasedAtPlayback: [Int] = []

        let synthesize: @MainActor (String) async throws -> Data = { text in
            let index = Int(text) ?? -1
            recorder.synthStart(index)
            await synthGates[index].wait()
            recorder.synthEnd(index)
            return makePCMBuffer(index: index, counter: counter)
        }
        let play: @MainActor (Data, Int) async throws -> Void = { data, index in
            recorder.playStart(index, data)
            releasedAtPlayback.append(counter.count)
            recorder.playEnd(index)
            playFinished[index].signal()
        }

        let task = Task { @MainActor in
            try await SpeechPlaybackPipeline.play(
                chunks: (0..<chunkCount).map(String.init),
                onEvent: recorder.recordPipelineEvent,
                synthesize: synthesize,
                play: play
            )
        }

        // Release synthesis for chunk i only after playback of i-1 finished,
        // so every chunk after the first waits at the playback boundary and
        // exercises the duplicate-publication path.
        for index in 0..<chunkCount {
            if index == 0 { synthGates[0].open() }
            await playFinished[index].wait()
            if index + 1 < chunkCount { synthGates[index + 1].open() }
        }
        try await task.value

        // At the start of playback i, every earlier chunk has been consumed
        // and released; the current chunk is still held by the play closure.
        // Before consumed results were discarded, awaited chunks stayed in the
        // ready buffer for the whole response.
        try expectEqual(
            "consumed chunks release PCM before the next playback",
            releasedAtPlayback,
            Array(0..<chunkCount)
        )
        try expectEqual("all PCM buffers are released after playback", counter.count, chunkCount)
        try expectEqual("memory test synthesized once", recorder.synthIndices, Array(0..<chunkCount))
        try expectEqual("memory test played in order", recorder.playIndices, Array(0..<chunkCount))
        try expectEqual("memory test stayed serial", recorder.maxActiveSynth, 1)
        try expectEventLifecycle("memory test lifecycle", recorder.pipelineEvents)
    }

    @MainActor
    static func testSlowNextChunkWaitsAtBoundary() async throws {
        let recorder = Recorder()
        let synthGate = AsyncGate()
        let synthStarted = (0..<2).map { _ in Event() }
        let playStarted = (0..<2).map { _ in Event() }
        let playFinished = (0..<2).map { _ in Event() }

        let synthesize: @MainActor (String) async throws -> Data = { text in
            let index = Int(text) ?? -1
            recorder.synthStart(index)
            synthStarted[index].signal()
            if index == 1 {
                await synthGate.wait()
            }
            recorder.synthEnd(index)
            return Data("pcm-\(index)".utf8)
        }
        let play: @MainActor (Data, Int) async throws -> Void = { data, index in
            recorder.playStart(index, data)
            playStarted[index].signal()
            recorder.playEnd(index)
            playFinished[index].signal()
        }

        let task = Task { @MainActor in
            try await SpeechPlaybackPipeline.play(
                chunks: ["0", "1"],
                onEvent: recorder.recordPipelineEvent,
                synthesize: synthesize,
                play: play
            )
        }

        // The first chunk plays immediately; the second remains in synthesis.
        await playFinished[0].wait()
        await synthStarted[1].wait()
        try expectEqual("slow next chunk has not been synthesized", recorder.synthEnds, [0])
        try expectEqual("playback stops after the first chunk", recorder.playIndices, [0])
        try expectTrue("slow next chunk must not start playback", !playStarted[1].isSignaled)
        try expectTrue(
            "boundary wait is not reported before the chunk is ready",
            playbackWaitElapsed(recorder.pipelineEvents, index: 1) == nil
        )
        try expectEqual(
            "playback has not advanced past the ready chunk",
            milestones(recorder.pipelineEvents).playbackStarted,
            [0]
        )

        // Releasing the slow chunk completes the boundary wait, then playback.
        synthGate.open()
        await playStarted[1].wait()
        guard let wait = playbackWaitElapsed(recorder.pipelineEvents, index: 1) else {
            throw TestFailure(message: "slow next chunk wait duration is missing")
        }
        try expectTrue("slow next chunk wait is nonnegative", wait >= 0)
        try await task.value

        try expectEqual("slow next chunk eventually plays", recorder.playIndices, [0, 1])
        try expectEqual("slow next chunk synthesized once", recorder.synthIndices, [0, 1])
        let timing = milestones(recorder.pipelineEvents)
        try expectEqual("slow next chunk timing waits", timing.playbackWaits, [0, 1])
        try expectEqual("slow next chunk timing starts", timing.playbackStarted, [0, 1])
        try expectEqual("slow next chunk timing completions", timing.playbackCompleted, [0, 1])
        try expectEventLifecycle("slow next chunk lifecycle", recorder.pipelineEvents)
        try expectMilestoneOrder("slow next chunk milestone order", recorder.pipelineEvents, index: 0)
        try expectMilestoneOrder("slow next chunk milestone order", recorder.pipelineEvents, index: 1)
    }

    @MainActor
    static func testSynthesisFailureWhileWaitingAtBoundary() async throws {
        let recorder = Recorder()
        let expected = TestError.synthesis(1)
        let synthGate = AsyncGate()
        let synthStarted = (0..<2).map { _ in Event() }
        let playFinished = Event()

        let synthesize: @MainActor (String) async throws -> Data = { text in
            let index = Int(text) ?? -1
            recorder.synthStart(index)
            synthStarted[index].signal()
            if index == 1 {
                // Fail only after the consumer is waiting at the boundary.
                await synthGate.wait()
                recorder.synthEnd(index)
                throw expected
            }
            recorder.synthEnd(index)
            return Data("pcm-\(index)".utf8)
        }
        let play: @MainActor (Data, Int) async throws -> Void = { data, index in
            recorder.playStart(index, data)
            recorder.playEnd(index)
            playFinished.signal()
        }

        let task = Task { @MainActor in
            try await SpeechPlaybackPipeline.play(
                chunks: ["0", "1", "2"],
                onEvent: recorder.recordPipelineEvent,
                synthesize: synthesize,
                play: play
            )
        }

        await playFinished.wait()
        await synthStarted[1].wait()
        try expectEqual("failing chunk has not finished", recorder.synthEnds, [0])
        try expectTrue(
            "failing chunk never starts playback",
            milestones(recorder.pipelineEvents).playbackStarted == [0]
        )

        synthGate.open()
        try await expectThrows("boundary synthesis error is preserved", expected) {
            try await task.value
        }

        try expectEqual("failure plays only the ready chunk", recorder.playIndices, [0])
        try expectEqual("failure stops scheduling new synthesis", recorder.synthIndices, [0, 1])

        let timing = milestones(recorder.pipelineEvents)
        try expectEqual("failed chunk never claims completion", timing.synthesisCompleted, [0])
        try expectEqual("failed chunk never completes playback", timing.playbackCompleted, [0])
        try expectTrue(
            "failed chunk never emits a playback wait",
            playbackWaitElapsed(recorder.pipelineEvents, index: 1) == nil
        )
        try expectEventLifecycle("boundary failure lifecycle", recorder.pipelineEvents)
        try expectMilestoneOrder("boundary failure order", recorder.pipelineEvents, index: 0)
    }

    @MainActor
    static func testCancellationWhileAwaitingNextChunkDiscardsLateResult() async throws {
        let recorder = Recorder()
        let synthStarted = (0..<2).map { _ in Event() }
        let playFinished = Event()
        let firstPlaybackCompleted = Event()
        let cancellationObserved = Event()
        let synthesisReturned = Event()
        let release = AsyncGate()

        let synthesize: @MainActor (String) async throws -> Data = { text in
            let index = Int(text) ?? -1
            recorder.synthStart(index)
            synthStarted[index].signal()
            if index == 1 {
                // Behave like a native call that finishes its current work:
                // cancellation is observed but the call returns data late.
                await withTaskCancellationHandler {
                    await release.wait()
                } onCancel: {
                    cancellationObserved.signal()
                }
                recorder.synthEnd(index)
                synthesisReturned.signal()
                return Data("late-\(index)".utf8)
            }
            recorder.synthEnd(index)
            return Data("pcm-\(index)".utf8)
        }
        let play: @MainActor (Data, Int) async throws -> Void = { data, index in
            recorder.playStart(index, data)
            recorder.playEnd(index)
            playFinished.signal()
        }

        let task = Task { @MainActor in
            try await SpeechPlaybackPipeline.play(
                chunks: ["0", "1", "2"],
                onEvent: { event in
                    recorder.recordPipelineEvent(event)
                    if case .playbackCompleted(0, _) = event {
                        firstPlaybackCompleted.signal()
                    }
                },
                synthesize: synthesize,
                play: play
            )
        }

        await playFinished.wait()
        await synthStarted[1].wait()
        await firstPlaybackCompleted.wait()
        // Cancel while the slow next chunk is still outstanding.
        task.cancel()
        await cancellationObserved.wait()

        release.open()
        await synthesisReturned.wait()

        try await expectCancellation("boundary cancellation is reported after native return") {
            try await task.value
        }
        try expectEqual("canceled boundary never plays the late chunk", recorder.playIndices, [0])
        try expectEqual("only the in-flight chunk was synthesized", recorder.synthIndices, [0, 1])
        try expectEqual("late native call finished before exit", recorder.synthEnds, [0, 1])

        let timing = milestones(recorder.pipelineEvents)
        try expectEqual("canceled chunk never reports a wait", timing.playbackWaits, [0])
        try expectEqual("canceled chunk never starts playback", timing.playbackStarted, [0])
        try expectEqual("canceled chunk never claims synthesis completion", timing.synthesisCompleted, [0])
        try expectEventLifecycle("boundary cancellation lifecycle", recorder.pipelineEvents)
    }

    // MARK: - Runner

    @MainActor
    static func main() async {
        let tests: [(name: String, body: @MainActor () async throws -> Void)] = [
            ("emptyChunks", testEmptyChunks),
            ("singleChunk", testSingleChunk),
            ("firstChunkStartupLookaheadAndOrder", testFirstChunkStartupLookaheadAndOrder),
            ("twoChunksPlayFirstWhileSecondSynthesizes", testTwoChunksPlayFirstWhileSecondSynthesizes),
            ("playbackWaitForLateChunk", testPlaybackWaitForLateChunk),
            ("synthesisIsStrictlySerial", testSynthesisIsStrictlySerial),
            ("orderedPlaybackPayloads", testOrderedPlaybackPayloads),
            ("firstChunkSynthesisFailureNeverStartsPlayback", testFirstChunkSynthesisFailureNeverStartsPlayback),
            ("synthesisErrorAfterFirstChunkIsPreserved", testSynthesisErrorAfterFirstChunkIsPreserved),
            ("playbackErrorIsPreservedAndStopsPlayback", testPlaybackErrorIsPreservedAndStopsPlayback),
            ("cancellationCancelsOutstandingSynthesis", testCancellationCancelsOutstandingSynthesis),
            ("cancellationAfterPlayback", testCancellationAfterPlayback),
            ("noncooperativeCancellationLateReturnIsNotPlayed", testNoncooperativeCancellationLateReturnIsNotPlayed),
            ("playbackFailureWaitsForLateLookahead", testPlaybackFailureWaitsForLateLookahead),
            ("cancellationDuringPlaybackDrainsLateLookahead", testCancellationDuringPlaybackDrainsLateLookahead),
            ("consumedChunksReleasePCM", testConsumedChunksReleasePCM),
            ("slowNextChunkWaitsAtBoundary", testSlowNextChunkWaitsAtBoundary),
            ("synthesisFailureWhileWaitingAtBoundary", testSynthesisFailureWhileWaitingAtBoundary),
            (
                "cancellationWhileAwaitingNextChunkDiscardsLateResult",
                testCancellationWhileAwaitingNextChunkDiscardsLateResult
            )
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
