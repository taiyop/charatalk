import Foundation

/// Plays synthesized speech chunks in order with a small, bounded synthesis
/// lookahead.
///
/// The pipeline starts playback as soon as the first chunk is synthesized.
/// The next two chunks are then scheduled while that first chunk plays, so a
/// short reply becomes audible without waiting for a two-chunk startup buffer.
/// The bounded two-chunk lookahead is retained: when playback catches up with
/// synthesis, the playback boundary waits for the missing chunk instead of
/// allowing the producer to run further ahead.
///
/// Synthesis is strictly serial because speech managers generally do not
/// support concurrent synthesis calls. While a chunk is playing, the pipeline
/// keeps at most two chunks scheduled ahead of the playing index, so the
/// producer can make progress without retaining the PCM for the whole
/// response.
///
/// - Parameters:
///   - chunks: Text chunks in playback order.
///   - onEvent: Optional synchronous observer for timing milestones. Called on
///     the main actor in emission order, before the pipeline continues.
///   - synthesize: Synthesizes one chunk. Called serially.
///   - play: Plays one chunk and its index. Called serially in input order.
/// - Throws: The first synthesis or playback error. Cancellation of the
///   current task is propagated to outstanding synthesis tasks and reported
///   as `CancellationError`.
@MainActor
public enum SpeechPlaybackPipeline {
    /// Timing milestones for one pipeline run.
    ///
    /// Durations come from `ProcessInfo.processInfo.systemUptime`, so they are
    /// monotonic and unaffected by wall-clock changes. Synthesis durations
    /// cover only the `synthesize` call itself, after any predecessor has been
    /// awaited. The playback wait covers only the readiness wait at the
    /// playback boundary and is zero for a chunk that is already buffered;
    /// waiting for the first chunk before playback starts is startup latency
    /// and is not reported here.
    public enum Event: Sendable, Equatable {
        /// The serial `synthesize` call for `index` is about to begin.
        case synthesisStarted(index: Int)
        /// The `synthesize` call for `index` returned successfully.
        case synthesisCompleted(index: Int, elapsed: TimeInterval)
        /// Playback finished waiting `elapsed` seconds for `index` to be
        /// ready. Chunks already buffered report zero.
        case playbackWaitCompleted(index: Int, elapsed: TimeInterval)
        /// Playback of `index` is about to call the play closure. This is not
        /// the moment audio physically starts.
        case playbackStarted(index: Int)
        /// The play closure for `index` returned successfully.
        case playbackCompleted(index: Int, elapsed: TimeInterval)
    }

    public static func play(
        chunks: [String],
        onEvent: (@MainActor @Sendable (Event) -> Void)? = nil,
        synthesize: @escaping @MainActor (String) async throws -> Data,
        play: @escaping @MainActor (Data, Int) async throws -> Void
    ) async throws {
        guard !chunks.isEmpty else { return }
        try Task.checkCancellation()

        let store = SynthesisTaskStore()
        let ready = ReadyChunkBuffer()
        defer {
            store.cancelAll()
            ready.removeAll()
        }

        var lastScheduled = -1
        var lastTask: Task<Data, Error>?

        // Each new synthesis task awaits its predecessor before calling the
        // manager, which keeps the manager calls strictly serial even though
        // several bounded tasks can exist at once.
        func schedule(through limit: Int) {
            while lastScheduled + 1 < chunks.count, lastScheduled + 1 <= limit {
                let index = lastScheduled + 1
                let text = chunks[index]
                let predecessor = lastTask
                let task = Task { @MainActor in
                    if let predecessor {
                        _ = try await predecessor.value
                    }
                    try Task.checkCancellation()
                    // Time only the serial manager call. Waiting for the
                    // predecessor is queue delay, not synthesis work.
                    let synthesisStart = ProcessInfo.processInfo.systemUptime
                    onEvent?(.synthesisStarted(index: index))
                    let data = try await synthesize(text)
                    try Task.checkCancellation()
                    let elapsed = ProcessInfo.processInfo.systemUptime - synthesisStart
                    onEvent?(.synthesisCompleted(index: index, elapsed: elapsed))
                    // Publish the finished chunk immediately so the playback
                    // boundary can consume it without an extra readiness wait.
                    ready.store(data, at: index)
                    store.remove(at: index)
                    return data
                }
                store.add(task, at: index)
                lastScheduled = index
                lastTask = task
            }
            // Once the final chunk is scheduled no future task can await this
            // handle. Drop it so its completed result is not retained for the
            // rest of playback.
            if lastScheduled == chunks.count - 1 {
                lastTask = nil
            }
        }

        func awaitValue(_ task: Task<Data, Error>) async throws -> Data {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
                store.cancelAll()
            }
        }

        func run() async throws {
            // One ready chunk is enough to start. The playback loop schedules
            // the two-chunk lookahead before it begins playing this chunk, so
            // the second one synthesizes during the first one's playback.
            schedule(through: 0)
            // Keep the handle scoped to this block: holding it in `run` would
            // retain the first chunk's PCM for the whole response.
            do {
                guard let firstTask = store.task(at: 0) else {
                    throw PipelineInvariantError.missingChunk(0)
                }
                _ = try await awaitValue(firstTask)
            }
            try Task.checkCancellation()

            for index in chunks.indices {
                try Task.checkCancellation()

                // Schedule before playback so synthesis can run during it.
                schedule(through: min(chunks.count - 1, index + 2))

                let data: Data
                if let readyData = ready.take(at: index) {
                    data = readyData
                    // Already on hand at the playback boundary. Startup
                    // waiting for the first chunk is measured by the caller.
                    onEvent?(.playbackWaitCompleted(index: index, elapsed: 0))
                } else if let task = store.task(at: index) {
                    let waitStart = ProcessInfo.processInfo.systemUptime
                    data = try await awaitValue(task)
                    try Task.checkCancellation()
                    store.remove(at: index)
                    // The task publishes its result before returning; this copy
                    // is already consumed above, so drop it to keep the buffer
                    // bounded.
                    _ = ready.take(at: index)
                    let elapsed = ProcessInfo.processInfo.systemUptime - waitStart
                    onEvent?(.playbackWaitCompleted(index: index, elapsed: elapsed))
                } else {
                    // Never synthesize here: it could overlap lookahead work.
                    throw PipelineInvariantError.missingChunk(index)
                }

                var playbackStart: TimeInterval?
                try await withTaskCancellationHandler {
                    try Task.checkCancellation()
                    playbackStart = ProcessInfo.processInfo.systemUptime
                    onEvent?(.playbackStarted(index: index))
                    try await play(data, index)
                } onCancel: {
                    store.cancelAll()
                }
                try Task.checkCancellation()
                if let playbackStart {
                    let elapsed = ProcessInfo.processInfo.systemUptime - playbackStart
                    onEvent?(.playbackCompleted(index: index, elapsed: elapsed))
                }
            }
        }

        do {
            try await run()
        } catch {
            store.cancelAll()
            // Nothing in the buffer will play after a failure or
            // cancellation. Release that PCM before a slow native synthesis
            // unwinds so cleanup does not keep a full lookahead resident.
            ready.removeAll()
            // Cancellation is cooperative: wait even for a late native return
            // so no old synthesis can keep mutating manager state after exit.
            await store.waitForAll()
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }
}

private enum PipelineInvariantError: Error, Equatable {
    case missingChunk(Int)
}

/// Finished chunks waiting for their playback turn.
///
/// Only the MainActor touches this buffer: synthesis tasks publish their result
/// on completion and the playback loop consumes it at the boundary.
@MainActor
private final class ReadyChunkBuffer {
    private var chunks: [Int: Data] = [:]

    func store(_ data: Data, at index: Int) {
        chunks[index] = data
    }

    func take(at index: Int) -> Data? {
        chunks.removeValue(forKey: index)
    }

    func removeAll() {
        chunks.removeAll()
    }
}

/// Thread-safe collection of in-flight synthesis tasks.
///
/// Only the MainActor mutates the collection, while the nonisolated
/// cancellation handlers need to cancel every task promptly.
private final class SynthesisTaskStore: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [Int: Task<Data, Error>] = [:]
    private var cancelled = false

    func add(_ task: Task<Data, Error>, at index: Int) {
        lock.lock()
        tasks[index] = task
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    func task(at index: Int) -> Task<Data, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return tasks[index]
    }

    func remove(at index: Int) {
        lock.lock()
        defer { lock.unlock() }
        tasks.removeValue(forKey: index)
    }

    func cancelAll() {
        lock.lock()
        cancelled = true
        let pending = Array(tasks.values)
        lock.unlock()
        for task in pending {
            task.cancel()
        }
    }

    private func pendingTasks() -> [Task<Data, Error>] {
        lock.lock()
        defer { lock.unlock() }
        return Array(tasks.values)
    }

    func waitForAll() async {
        for task in pendingTasks() {
            _ = try? await task.value
        }
    }
}
