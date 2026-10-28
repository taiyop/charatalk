import Foundation

/// One playback request handed to a ``SpeechPlaybackBackend``.
public struct SpeechPlaybackRequest: Sendable {
    /// Identity used to correlate backend callbacks with this request.
    public let id: UUID
    /// Mono PCM16 samples in little-endian byte order.
    public let pcm16: Data
    /// Playback rate multiplier.
    public let rate: Float
    /// Playback volume in the range `0...1`.
    public let volume: Float

    public init(id: UUID, pcm16: Data, rate: Float, volume: Float) {
        self.id = id
        self.pcm16 = pcm16
        self.rate = rate
        self.volume = volume
    }
}

/// Lifecycle and metering events emitted by a ``SpeechPlaybackBackend``.
public enum SpeechPlaybackEvent: Sendable {
    case started
    case meter(Float)
    case finished
    case stopped
    case failed(any Error)
}

/// A fast, enqueue-only audio backend.
///
/// `start` and `stop` must not block waiting for audio setup or completion.
/// They only record or cancel work and return. Events may be delivered from
/// any thread and at any time after `start`, including after `stop`.
public protocol SpeechPlaybackBackend: Sendable {
    func start(
        _ request: SpeechPlaybackRequest,
        onEvent: @escaping @Sendable (SpeechPlaybackEvent) -> Void
    )
    func stop(id: UUID)
}

/// Coordinates one audible request at a time.
///
/// Every request has a unique identity. Backend events are serialized through
/// a single main-actor consumer and ignored when their identity is no longer
/// current, which makes delayed native setup, duplicate completion callbacks,
/// and late cancellation handlers harmless. The class keeps at most one
/// checked continuation and settles it exactly once.
@MainActor
public final class SpeechPlaybackSession {
    private struct ActiveRequest {
        let id: UUID
        let onEvent: @MainActor @Sendable (SpeechPlaybackEvent) -> Void
        let continuation: CheckedContinuation<Void, any Error>
        let eventSink: AsyncStream<SpeechPlaybackEvent>.Continuation
        var started: Bool
    }

    private let backend: any SpeechPlaybackBackend
    private var active: ActiveRequest?
    private var eventTask: Task<Void, Never>?

    public init(backend: any SpeechPlaybackBackend) {
        self.backend = backend
    }

    /// Starts a request and suspends until it finishes.
    ///
    /// Starting a new request preempts and stops the previous one. The caller's
    /// `onEvent` observes events for this request only, on the main actor.
    ///
    /// - Throws: `CancellationError` when the request is stopped, preempted, or
    ///   its task is cancelled. A backend `.failed` error is propagated as-is.
    public func play(
        pcm16: Data,
        rate: Float,
        volume: Float,
        onEvent: @escaping @MainActor @Sendable (SpeechPlaybackEvent) -> Void = { _ in }
    ) async throws {
        // A task that was already cancelled never starts or preempts audio.
        try Task.checkCancellation()

        // Only one request may be audible. Stop the old one first so its
        // callbacks cannot be mistaken for the request installed below.
        _ = cancelActive(matching: nil)

        let id = UUID()
        let request = SpeechPlaybackRequest(id: id, pcm16: pcm16, rate: rate, volume: volume)
        let (events, eventSink) = AsyncStream<SpeechPlaybackEvent>.makeStream(
            bufferingPolicy: .unbounded
        )

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Install the continuation and event consumer before the
                // backend can synchronously emit any callback.
                active = ActiveRequest(
                    id: id,
                    onEvent: onEvent,
                    continuation: continuation,
                    eventSink: eventSink,
                    started: false
                )
                eventTask = Task { @MainActor [weak self] in
                    for await event in events {
                        guard let self else { return }
                        self.handle(event, for: id)
                    }
                }

                // Covers cancellation that raced with the check above and the
                // state installation. No backend work is started in that case.
                if Task.isCancelled {
                    _ = cancelActive(matching: id)
                    return
                }

                // Mark the request as started before the call so a cancellation
                // observed while `start` is running still stops this exact id.
                active?.started = true
                backend.start(request) { event in
                    eventSink.yield(event)
                }

                // Covers a cancellation that arrived during `start`, before the
                // cancellation handler could schedule its main-actor work.
                if Task.isCancelled {
                    _ = cancelActive(matching: id)
                }
            }
        } onCancel: {
            // Delayed on purpose: this may run after a newer request replaced
            // this one. The identity check below keeps the new request safe.
            Task { @MainActor [weak self] in
                self?.cancelIfActive(id: id)
            }
        }
    }

    /// Stops the current request, if any.
    ///
    /// The request's observer receives `.stopped` once and its `play` call
    /// throws `CancellationError`. Calling this with no active request does
    /// nothing.
    public func stop() {
        _ = cancelActive(matching: nil)
    }

    // MARK: - Event handling

    private func handle(_ event: SpeechPlaybackEvent, for id: UUID) {
        guard let current = active, current.id == id else { return }

        switch event {
        case .started:
            current.onEvent(.started)
        case .meter(let level):
            current.onEvent(.meter(level))
        case .finished:
            guard let finished = detach(matching: id) else { return }
            finished.onEvent(.finished)
            finished.continuation.resume()
        case .stopped:
            guard let stopped = detach(matching: id) else { return }
            // The backend already stopped itself; do not call `stop` again.
            stopped.onEvent(.stopped)
            stopped.continuation.resume(throwing: CancellationError())
        case .failed(let error):
            guard let failed = detach(matching: id) else { return }
            failed.onEvent(.failed(error))
            failed.continuation.resume(throwing: error)
        }
    }

    private func cancelIfActive(id: UUID) {
        _ = cancelActive(matching: id)
    }

    @discardableResult
    private func cancelActive(matching id: UUID?) -> Bool {
        guard let cancelled = detach(matching: id) else { return false }
        if cancelled.started {
            backend.stop(id: cancelled.id)
            cancelled.onEvent(.stopped)
        }
        cancelled.continuation.resume(throwing: CancellationError())
        return true
    }

    /// Removes the active request before notifying observers or resuming its
    /// continuation, so reentrant calls and duplicate callbacks see no request.
    private func detach(matching id: UUID?) -> ActiveRequest? {
        guard let current = active, id == nil || current.id == id else { return nil }
        active = nil
        eventTask?.cancel()
        eventTask = nil
        current.eventSink.finish()
        return current
    }
}

/// A backend that appends buffers to one player for an entire response. Unlike
/// `start`, enqueue must not replace audio already scheduled in this stream.
public protocol SpeechPlaybackQueueBackend: Sendable {
    func enqueue(
        _ request: SpeechPlaybackRequest,
        streamID: UUID,
        onEvent: @escaping @Sendable (SpeechPlaybackEvent) -> Void
    )
    func stop(streamID: UUID)
}

/// A completion contains no PCM. It also remembers completion before wait() is
/// called, since a prequeued buffer can finish while the consumer is resuming.
@MainActor
public final class SpeechPlaybackCompletion {
    private var result: Result<Void, any Error>?
    private var waiters: [CheckedContinuation<Void, any Error>] = []
    private let onCancel: @MainActor @Sendable () -> Void

    init(onCancel: @escaping @MainActor @Sendable () -> Void) {
        self.onCancel = onCancel
    }

    public func wait() async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                if let result { continuation.resume(with: result) }
                else { waiters.append(continuation) }
            }
            try Task.checkCancellation()
        } onCancel: {
            Task { @MainActor in self.onCancel() }
        }
    }

    func settle(_ result: Result<Void, any Error>) {
        guard self.result == nil else { return }
        self.result = result
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume(with: result) }
    }
}

/// Identity-scoped queue ownership: stop/replacement settles every queued wait,
/// and callbacks or cancellation from an older stream cannot affect a new one.
@MainActor
public final class SpeechPlaybackQueueSession {
    private struct Pending {
        let completion: SpeechPlaybackCompletion
        let onEvent: @MainActor @Sendable (SpeechPlaybackEvent) -> Void
        var started = false
    }

    private let backend: any SpeechPlaybackQueueBackend
    private var streamID: UUID?
    private var pending: [UUID: Pending] = [:]
    private var sink: AsyncStream<(UUID, SpeechPlaybackEvent)>.Continuation?
    private var eventTask: Task<Void, Never>?

    public init(backend: any SpeechPlaybackQueueBackend) { self.backend = backend }

    public func begin() -> UUID {
        stop()
        let id = UUID()
        streamID = id
        let (events, sink) = AsyncStream<(UUID, SpeechPlaybackEvent)>.makeStream()
        self.sink = sink
        // One consumer for the whole stream preserves finish/start/meter order
        // across buffers, even when the main actor is temporarily busy.
        eventTask = Task { @MainActor [weak self] in
            for await (requestID, event) in events { self?.handle(event, id: requestID, streamID: id) }
        }
        return id
    }

    public func enqueue(
        pcm16: Data, streamID: UUID, rate: Float, volume: Float,
        onEvent: @escaping @MainActor @Sendable (SpeechPlaybackEvent) -> Void = { _ in }
    ) throws -> SpeechPlaybackCompletion {
        try Task.checkCancellation()
        guard self.streamID == streamID, let sink else { throw CancellationError() }
        let id = UUID()
        let completion = SpeechPlaybackCompletion { [weak self] in self?.stop(streamID: streamID) }
        pending[id] = Pending(completion: completion, onEvent: onEvent)
        backend.enqueue(SpeechPlaybackRequest(id: id, pcm16: pcm16, rate: rate, volume: volume), streamID: streamID) {
            sink.yield((id, $0))
        }
        return completion
    }

    public func stop(streamID: UUID) {
        guard self.streamID == streamID else { return }
        terminate(error: CancellationError())
    }

    public func stop() {
        guard streamID != nil else { return }
        terminate(error: CancellationError())
    }

    private func terminate(error: any Error) {
        guard let id = streamID else { return }
        streamID = nil
        let entries = pending
        pending.removeAll()
        sink?.finish()
        sink = nil
        eventTask?.cancel()
        eventTask = nil
        backend.stop(streamID: id)
        for entry in entries.values {
            entry.onEvent(error is CancellationError ? .stopped : .failed(error))
            entry.completion.settle(.failure(error))
        }
    }

    private func handle(_ event: SpeechPlaybackEvent, id: UUID, streamID: UUID) {
        guard self.streamID == streamID, let entry = pending[id] else { return }
        switch event {
        case .started:
            guard !entry.started else { return }
            pending[id]?.started = true
            entry.onEvent(event)
        case .meter:
            if entry.started { entry.onEvent(event) }
        case .finished:
            pending.removeValue(forKey: id)
            entry.onEvent(event)
            entry.completion.settle(.success(()))
        case .stopped:
            terminate(error: CancellationError())
        case .failed(let error):
            terminate(error: error)
        }
    }
}
