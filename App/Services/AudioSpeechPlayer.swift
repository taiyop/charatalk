import Foundation
import AVFoundation
import IrodoriTTS

/// UI state is main-actor isolated; the engine, PCM conversion and scheduling
/// are confined to the audio worker. One engine/player is used per response.
@MainActor
public final class AudioSpeechPlayer: ObservableObject {
    public static let shared = AudioSpeechPlayer()
    @Published public private(set) var isPlaying = false
    @Published public private(set) var currentMouthOpen: Float = 0

    private let session = SpeechPlaybackQueueSession(backend: QueuedAudioPlaybackBackend())
    private var streamID: UUID?
    private var audibleID: UUID?
    private var smoothedVolume: Float = 0

    private init() {}

    public func beginQueue() -> UUID {
        stop()
        let id = session.begin()
        streamID = id
        return id
    }

    /// Returns immediately after handing PCM to the worker, not after playback.
    /// The completion carries no PCM and can be awaited at the playback boundary.
    public func enqueue(
        pcm16: Data, streamID: UUID,
        onPlaybackStarted: @escaping @MainActor @Sendable () -> Void = {}
    ) throws -> SpeechPlaybackCompletion {
        let audibleID = UUID()
        return try session.enqueue(
            pcm16: pcm16, streamID: streamID,
            rate: max(0.5, min(2, Float(AppSettings.shared.speechRate))),
            volume: max(0, min(1, Float(AppSettings.shared.speechVolume)))
        ) { [weak self] event in
            guard let self, self.streamID == streamID else { return }
            switch event {
            case .started:
                self.audibleID = audibleID
                self.isPlaying = true
                onPlaybackStarted()
            case .meter(let normalized):
                guard self.audibleID == audibleID else { return }
                let boost = Float(AppSettings.shared.lipSyncBoost)
                let target = min(normalized * (boost / 6), 1)
                let next = self.smoothedVolume * 0.5 + target * 0.5
                self.smoothedVolume = next
                let quantized: Float = next < 0.01 ? 0 : next
                if abs(quantized - self.currentMouthOpen) >= 0.015 ||
                    (quantized == 0 && self.currentMouthOpen != 0) {
                    self.currentMouthOpen = quantized
                }
            case .finished, .stopped, .failed:
                if self.audibleID == audibleID { self.resetState() }
            }
        }
    }

    public func endQueue(_ id: UUID) {
        session.stop(streamID: id)
        guard streamID == id else { return }
        streamID = nil
        resetState()
    }

    public func play(
        pcm16: Data,
        onPlaybackStarted: @escaping @MainActor @Sendable () -> Void = {}
    ) async throws {
        let id = beginQueue()
        defer { endQueue(id) }
        try await enqueue(pcm16: pcm16, streamID: id, onPlaybackStarted: onPlaybackStarted).wait()
    }

    public func stop() {
        session.stop()
        streamID = nil
        resetState()
    }

    private func resetState() {
        audibleID = nil
        if isPlaying { isPlaying = false }
        if currentMouthOpen != 0 { currentMouthOpen = 0 }
        smoothedVolume = 0
    }
}

/// GCD does not inherit task-local diagnostics. Never capture text/credentials.
private struct AudioPlaybackContext: Sendable {
    let performance = ConversationPerformance.current
    let chunk = ConversationPerformance.chunkIndex

    func withValue<T>(_ body: () throws -> T) rethrows -> T {
        try ConversationPerformance.$current.withValue(performance) {
            try ConversationPerformance.$chunkIndex.withValue(chunk, operation: body)
        }
    }
}

private final class AudioPlaybackCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
    func check() throws {
        lock.lock()
        let value = cancelled
        lock.unlock()
        if value { throw CancellationError() }
    }
}

/// Buffers are scheduled on the same AVAudioPlayerNode as soon as synthesis
/// completes, BEFORE the preceding buffer finishes. dataPlayedBack is used only
/// for ownership/completion; it is not used to schedule the next buffer.
private final class QueuedAudioPlaybackBackend: SpeechPlaybackQueueBackend, @unchecked Sendable {
    private final class Segment {
        let id: UUID
        let buffer: AVAudioPCMBuffer
        let levels: [Float]
        let startFrame: AVAudioFramePosition
        let context: AudioPlaybackContext
        let callback: @Sendable (SpeechPlaybackEvent) -> Void
        var started = false
        var interval: ConversationPerformance.Interval?
        var endFrame: AVAudioFramePosition { startFrame + Int64(buffer.frameLength) }

        init(id: UUID, buffer: AVAudioPCMBuffer, levels: [Float], startFrame: AVAudioFramePosition,
             context: AudioPlaybackContext, callback: @escaping @Sendable (SpeechPlaybackEvent) -> Void) {
            self.id = id
            self.buffer = buffer
            self.levels = levels
            self.startFrame = startFrame
            self.context = context
            self.callback = callback
        }
    }

    private final class Stream {
        let id: UUID
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let pitch = AVAudioUnitTimePitch()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        var segments: [Segment] = []
        var timer: DispatchSourceTimer?
        var lastFinishedAt: TimeInterval?

        init(id: UUID) { self.id = id }

        var currentFrame: AVAudioFramePosition {
            guard let time = player.lastRenderTime, let time = player.playerTime(forNodeTime: time) else { return 0 }
            return time.sampleTime
        }
    }

    private let queue = DispatchQueue(label: "CharaTalk.audioPlayback", qos: .userInitiated)
    private let registryLock = NSLock()
    private var cancellations: [UUID: AudioPlaybackCancellation] = [:]
    // All AVFoundation objects, including their final release, stay on queue.
    private var active: Stream?

    init() {
        queue.async {
            // Keep the migration cleanup for files from the former WAV-based
            // player, without doing disk I/O on the main actor.
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let directory = support.appendingPathComponent("Playback", isDirectory: true)
            if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                for file in files where file.pathExtension.lowercased() == "wav" {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
    }

    func enqueue(_ request: SpeechPlaybackRequest, streamID: UUID,
                 onEvent: @escaping @Sendable (SpeechPlaybackEvent) -> Void) {
        let context = AudioPlaybackContext()
        registryLock.lock()
        let cancellation = cancellations[streamID] ?? AudioPlaybackCancellation()
        cancellations[streamID] = cancellation
        registryLock.unlock()
        let interval = ConversationPerformance.begin("Audio worker queue wait")
        queue.async { [self] in
            context.withValue {
                ConversationPerformance.end("Audio worker queue wait", interval, outcome: .completed)
                enqueueOnQueue(request, streamID: streamID, cancellation: cancellation, context: context, onEvent: onEvent)
            }
        }
    }

    func stop(streamID: UUID) {
        registryLock.lock()
        let cancellation = cancellations.removeValue(forKey: streamID)
        registryLock.unlock()
        cancellation?.cancel()
        queue.async { [self] in
            guard active?.id == streamID else { return }
            terminate(event: .stopped)
        }
    }

    private func enqueueOnQueue(_ request: SpeechPlaybackRequest, streamID: UUID,
                                cancellation: AudioPlaybackCancellation, context: AudioPlaybackContext,
                                onEvent: @escaping @Sendable (SpeechPlaybackEvent) -> Void) {
        let interval = ConversationPerformance.begin("Audio playback setup")
        var outcome = ConversationPerformance.Outcome.failed
        defer { ConversationPerformance.end("Audio playback setup", interval, outcome: outcome) }
        do {
            try cancellation.check()
            context.performance?.value("audio_setup_on_main_thread", value: Thread.isMainThread ? 1 : 0, chunk: context.chunk)
            guard !request.pcm16.isEmpty, request.pcm16.count.isMultiple(of: 2),
                  request.pcm16.count / 2 <= Int(UInt32.max) else {
                throw IrodoriError.invalid("音声のPCMデータが不正です。")
            }
            let stream: Stream
            if let current = active, current.id == streamID {
                stream = current
            } else {
                if active != nil { terminate(event: .stopped) }
                stream = Stream(id: streamID)
                active = stream
                try ConversationPerformance.measure("Audio engine setup") {
                    #if os(iOS)
                    let session = AVAudioSession.sharedInstance()
                    if session.category != .playback && session.category != .playAndRecord {
                        try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
                    }
                    try session.setActive(true)
                    #endif
                    stream.engine.attach(stream.player)
                    stream.engine.attach(stream.pitch)
                    stream.engine.connect(stream.player, to: stream.pitch, format: stream.format)
                    stream.engine.connect(stream.pitch, to: stream.engine.mainMixerNode, format: stream.format)
                    stream.pitch.rate = request.rate
                    stream.player.volume = request.volume
                    stream.engine.prepare()
                    try stream.engine.start()
                }
                startMetering(stream)
            }
            try cancellation.check()
            // Response settings are snapshotted at the first buffer; do not
            // change rate/volume of audio already queued by a later enqueue.
            let (buffer, levels) = try ConversationPerformance.measure("PCM buffer preparation") {
                try makeBuffer(request.pcm16, format: stream.format)
            }
            try cancellation.check()
            let startFrame = max(stream.segments.last?.endFrame ?? 0, stream.currentFrame)
            let segment = Segment(id: request.id, buffer: buffer, levels: levels, startFrame: startFrame,
                                  context: context, callback: onEvent)
            stream.segments.append(segment)
            context.performance?.value("audio_queued_buffers", value: Double(stream.segments.count), chunk: context.chunk)
            let segmentID = request.id
            stream.player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                guard let self else { return }
                self.queue.async { [self] in complete(id: segmentID, streamID: streamID) }
            }
            if !stream.player.isPlaying { stream.player.play() }
            try cancellation.check()
            if stream.segments.count == 1 { started(segment, in: stream) }
            context.performance?.duration("expected_playback", seconds: Double(buffer.frameLength) / 48_000 / Double(stream.pitch.rate), chunk: context.chunk)
            outcome = .completed
        } catch {
            // Stop all buffers on this stream, but never a replacement stream.
            if active?.id == streamID { terminate(event: error is CancellationError ? .stopped : .failed(error)) }
            onEvent(error is CancellationError ? .stopped : .failed(error))
            outcome = ConversationPerformance.outcome(for: error)
        }
    }

    private func makeBuffer(_ pcm: Data, format: AVAudioFormat) throws -> (AVAudioPCMBuffer, [Float]) {
        let count = pcm.count / 2
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let samples = buffer.floatChannelData?[0] else { throw IrodoriError.invalid("音声バッファを確保できませんでした。") }
        buffer.frameLength = AVAudioFrameCount(count)
        var levels: [Float] = []
        // RMS every 20 ms, computed off the real-time audio thread. Metering
        // follows the player sample clock, including time-pitch rate changes.
        pcm.withUnsafeBytes { bytes in
            for begin in stride(from: 0, to: count, by: 960) {
                let end = min(begin + 960, count)
                var energy: Float = 0
                for index in begin..<end {
                    let value = Float(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))) / 32_768
                    samples[index] = value
                    energy += value * value
                }
                let db = 10 * log10(max(energy / Float(end - begin), 1e-12))
                levels.append(max(0, min(1, (db + 45) / 45)))
            }
        }
        return (buffer, levels)
    }

    private func started(_ segment: Segment, in stream: Stream) {
        guard !segment.started else { return }
        segment.started = true
        segment.context.withValue {
            segment.interval = ConversationPerformance.begin("Audio playback")
            ConversationPerformance.$previousPlaybackFinishedAt.withValue(stream.lastFinishedAt) {
                segment.context.performance?.audioStarted()
            }
        }
        segment.callback(.started)
    }

    private func complete(id: UUID, streamID: UUID) {
        guard let stream = active, stream.id == streamID,
              let segment = stream.segments.first, segment.id == id else { return }
        started(segment, in: stream)
        stream.segments.removeFirst()
        stream.lastFinishedAt = ProcessInfo.processInfo.systemUptime
        segment.context.withValue { ConversationPerformance.end("Audio playback", segment.interval, outcome: .completed) }
        segment.callback(.finished)
        if let next = stream.segments.first { started(next, in: stream) }
    }

    private func startMetering(_ stream: Stream) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let id = stream.id
        timer.schedule(deadline: .now() + .milliseconds(25), repeating: .milliseconds(25), leeway: .milliseconds(3))
        timer.setEventHandler { [weak self] in
            guard let self, let stream = self.active, stream.id == id else { return }
            guard stream.engine.isRunning, stream.segments.isEmpty || stream.player.isPlaying else {
                self.terminate(event: .failed(IrodoriError.invalid("音声エンジンが停止しました。もう一度再生してください。")))
                return
            }
            let frame = stream.currentFrame
            guard let segment = stream.segments.first(where: { frame >= $0.startFrame && frame < $0.endFrame }) else { return }
            let block = Int(max(0, frame - segment.startFrame)) / 960
            if block < segment.levels.count { segment.callback(.meter(segment.levels[block])) }
        }
        stream.timer = timer
        timer.resume()
    }

    private func terminate(event: SpeechPlaybackEvent) {
        guard let stream = active else { return }
        active = nil // Ignore callbacks caused by stop() itself.
        stream.timer?.cancel()
        stream.timer = nil
        stream.player.stop()
        stream.engine.stop()
        for segment in stream.segments {
            segment.context.withValue {
                let outcome: ConversationPerformance.Outcome
                if case .failed = event { outcome = .failed } else { outcome = .cancelled }
                ConversationPerformance.end("Audio playback", segment.interval, outcome: outcome)
            }
            segment.callback(event)
        }
        stream.segments.removeAll()
        registryLock.lock()
        let cancellation = cancellations.removeValue(forKey: stream.id)
        registryLock.unlock()
        cancellation?.cancel()
    }
}
