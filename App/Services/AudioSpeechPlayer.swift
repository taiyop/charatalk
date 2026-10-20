import Foundation
import AVFoundation
import IrodoriTTS

/// Only observable UI state lives on the main actor. All AVAudioPlayer work,
/// including metering, stop and destruction, belongs to the backend's queue.
@MainActor
public final class AudioSpeechPlayer: ObservableObject {
    public static let shared = AudioSpeechPlayer()

    @Published public private(set) var isPlaying = false
    @Published public private(set) var currentMouthOpen: Float = 0

    private let session: SpeechPlaybackSession
    private var smoothedVolume: Float = 0

    private init() {
        session = SpeechPlaybackSession(backend: QueuedAudioPlaybackBackend())
    }

    /// Suspends until playback finishes. Stopping/replacing this request throws
    /// CancellationError; stale backend callbacks cannot complete a newer request.
    public func play(
        pcm16: Data,
        onPlaybackStarted: @escaping @MainActor @Sendable () -> Void = {}
    ) async throws {
        let rate = max(0.5, min(2, Float(AppSettings.shared.speechRate)))
        let volume = max(0, min(1, Float(AppSettings.shared.speechVolume)))
        try await session.play(pcm16: pcm16, rate: rate, volume: volume) { [weak self] event in
            guard let self else { return }
            switch event {
            case .started:
                self.smoothedVolume = 0
                self.currentMouthOpen = 0
                self.isPlaying = true
                onPlaybackStarted()
            case .meter(let normalized):
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
                self.resetState()
            }
        }
    }

    public func stop() {
        session.stop()
        resetState()
    }

    private func resetState() {
        if isPlaying { isPlaying = false }
        if currentMouthOpen != 0 { currentMouthOpen = 0 }
        smoothedVolume = 0
    }
}

/// GCD does not inherit task-local values. Capture only safe diagnostic metadata
/// at enqueue time and explicitly restore it on the audio queue.
private struct AudioPlaybackContext: Sendable {
    let performance = ConversationPerformance.current
    let chunk = ConversationPerformance.chunkIndex
    let previousFinishedAt = ConversationPerformance.previousPlaybackFinishedAt

    func withValue<T>(_ body: () throws -> T) rethrows -> T {
        try ConversationPerformance.$current.withValue(performance) {
            try ConversationPerformance.$chunkIndex.withValue(chunk) {
                try ConversationPerformance.$previousPlaybackFinishedAt.withValue(previousFinishedAt) {
                    try body()
                }
            }
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

/// The delegate never transports an AVAudioPlayer across executors, only the
/// request ID captured by its callbacks and a monotonic completion timestamp.
private final class AudioPlaybackDelegate: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    let completed: @Sendable (Bool, TimeInterval) -> Void
    let failed: @Sendable (any Error, TimeInterval) -> Void
    private let lock = NSLock()
    private var terminal: (event: SpeechPlaybackEvent, time: TimeInterval)?

    init(completed: @escaping @Sendable (Bool, TimeInterval) -> Void,
         failed: @escaping @Sendable (any Error, TimeInterval) -> Void) {
        self.completed = completed
        self.failed = failed
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let time = ProcessInfo.processInfo.systemUptime
        record(flag ? .finished : .failed(IrodoriError.invalid("音声の再生が中断されました。")), at: time)
        completed(flag, time)
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        let time = ProcessInfo.processInfo.systemUptime
        let error = error ?? IrodoriError.invalid("音声のデコードに失敗しました。")
        record(.failed(error), at: time)
        failed(error, time)
    }

    // Record the verdict before dispatching it: the polling timer may already
    // be queued ahead of the delegate's notification on the audio queue.
    private func record(_ event: SpeechPlaybackEvent, at time: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        if let terminal, case .failed = terminal.event { return }
        if terminal == nil { terminal = (event, time) }
        else if case .failed = event { terminal = (event, time) }
    }

    func terminalResult() -> (event: SpeechPlaybackEvent, time: TimeInterval)? {
        lock.lock()
        defer { lock.unlock() }
        return terminal
    }
}

/// AVFoundation objects and mutable playback state are queue-confined. The only
/// cross-queue mutable state is the cancellation registry, guarded by a lock;
/// cancelling while prepareToPlay/play blocks never waits on that audio work.
private final class QueuedAudioPlaybackBackend: SpeechPlaybackBackend, @unchecked Sendable {
    private final class ActivePlayback {
        let id: UUID
        var player: AVAudioPlayer?
        let delegate: AudioPlaybackDelegate
        let callback: @Sendable (SpeechPlaybackEvent) -> Void
        let context: AudioPlaybackContext
        let interval: ConversationPerformance.Interval?
        let startedAt: TimeInterval
        var progress: SpeechPlaybackProgress

        init(id: UUID, player: AVAudioPlayer, delegate: AudioPlaybackDelegate,
             callback: @escaping @Sendable (SpeechPlaybackEvent) -> Void,
             context: AudioPlaybackContext, interval: ConversationPerformance.Interval?) {
            self.id = id
            self.player = player
            self.delegate = delegate
            self.callback = callback
            self.context = context
            self.interval = interval
            self.startedAt = ProcessInfo.processInfo.systemUptime
            self.progress = SpeechPlaybackProgress(duration: player.duration, rate: player.rate)
        }
    }

    private let queue = DispatchQueue(label: "CharaTalk.audioPlayback", qos: .userInitiated)
    private let registryLock = NSLock()
    private var cancellations: [UUID: AudioPlaybackCancellation] = [:]
    // Accessed only on queue, including AVAudioPlayer's final release.
    private var active: ActivePlayback?
    private var meterTimer: DispatchSourceTimer?
    private var lastCompletion: (turnID: String, time: TimeInterval)?

    init() {
        queue.async {
            // Preserve the existing migration cleanup, but never do disk I/O on UI startup.
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let directory = support.appendingPathComponent("Playback", isDirectory: true)
            if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                for file in files where file.pathExtension.lowercased() == "wav" {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
    }

    func start(_ request: SpeechPlaybackRequest,
               onEvent: @escaping @Sendable (SpeechPlaybackEvent) -> Void) {
        let enqueueInterval = ConversationPerformance.begin("Audio enqueue")
        defer { ConversationPerformance.end("Audio enqueue", enqueueInterval, outcome: .completed) }
        let context = AudioPlaybackContext()
        let cancellation = AudioPlaybackCancellation()
        registryLock.lock()
        cancellations[request.id] = cancellation
        registryLock.unlock()
        let queueInterval = ConversationPerformance.begin("Audio worker queue wait")
        queue.async { [self] in
            context.withValue {
                ConversationPerformance.end("Audio worker queue wait", queueInterval, outcome: .completed)
                startOnQueue(request, cancellation: cancellation, context: context, onEvent: onEvent)
            }
        }
    }

    func stop(id: UUID) {
        registryLock.lock()
        let cancellation = cancellations[id]
        registryLock.unlock()
        cancellation?.cancel()
        queue.async { [self] in
            finish(id: id, event: .stopped, at: ProcessInfo.processInfo.systemUptime)
        }
    }

    private func unregister(_ id: UUID) {
        registryLock.lock()
        cancellations.removeValue(forKey: id)
        registryLock.unlock()
    }

    private func startOnQueue(_ request: SpeechPlaybackRequest,
                              cancellation: AudioPlaybackCancellation,
                              context: AudioPlaybackContext,
                              onEvent: @escaping @Sendable (SpeechPlaybackEvent) -> Void) {
        let setupInterval = ConversationPerformance.begin("Audio playback setup")
        var outcome = ConversationPerformance.Outcome.failed
        defer { ConversationPerformance.end("Audio playback setup", setupInterval, outcome: outcome) }
        var preparingPlayer: AVAudioPlayer?
        do {
            try cancellation.check()
            if let active { finish(id: active.id, event: .stopped, at: ProcessInfo.processInfo.systemUptime) }
            context.performance?.value("audio_setup_on_main_thread", value: Thread.isMainThread ? 1 : 0, chunk: context.chunk)
            #if os(iOS)
            try ConversationPerformance.measure("Audio session setup") {
                let session = AVAudioSession.sharedInstance()
                if session.category != .playback && session.category != .playAndRecord {
                    try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
                    try session.setActive(true)
                } else if session.category == .playback && session.mode != .spokenAudio {
                    try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
                    try session.setActive(true)
                }
            }
            #endif
            try cancellation.check()
            let wav = try ConversationPerformance.measure("WAV preparation") {
                try ReferenceAudio.wavData(pcm16: request.pcm16)
            }
            let player = try ConversationPerformance.measure("Audio player creation") {
                try AVAudioPlayer(data: wav, fileTypeHint: AVFileType.wav.rawValue)
            }
            preparingPlayer = player
            let id = request.id
            let delegate = AudioPlaybackDelegate(completed: { [weak self] success, time in
                guard let self else { return }
                self.queue.async { [self] in
                    let event: SpeechPlaybackEvent = success ? .finished : .failed(IrodoriError.invalid("音声の再生が中断されました。"))
                    finish(id: id, event: event, at: time)
                }
            }, failed: { [weak self] error, time in
                guard let self else { return }
                self.queue.async { [self] in finish(id: id, event: .failed(error), at: time) }
            })
            player.delegate = delegate
            player.isMeteringEnabled = true
            player.enableRate = true
            player.rate = request.rate
            player.volume = request.volume
            let prepared = ConversationPerformance.measure("Audio prepare to play") { player.prepareToPlay() }
            guard prepared else { throw IrodoriError.invalid("音声の再生準備に失敗しました。") }
            try cancellation.check()
            let accepted = ConversationPerformance.measure("Audio player start") { player.play() }
            guard accepted else { throw IrodoriError.invalid("音声の再生開始に失敗しました。") }
            try cancellation.check()

            active = ActivePlayback(id: id, player: player, delegate: delegate, callback: onEvent,
                                    context: context, interval: ConversationPerformance.begin("Audio playback"))
            preparingPlayer = nil
            // Use the backend-observed finish time, not the later MainActor
            // continuation, so UI backpressure is included in inter-chunk gaps.
            let previous = lastCompletion.flatMap { completion in
                completion.turnID == context.performance?.id && context.chunk > 0 ? completion.time : nil
            }
            ConversationPerformance.$previousPlaybackFinishedAt.withValue(previous ?? context.previousFinishedAt) {
                context.performance?.audioStarted()
            }
            context.performance?.duration("expected_playback", seconds: player.duration / Double(player.rate), chunk: context.chunk)
            onEvent(.started)
            startMetering(id: id)
            outcome = .completed
        } catch {
            preparingPlayer?.delegate = nil
            ConversationPerformance.measure("Audio player stop") { preparingPlayer?.stop() }
            ConversationPerformance.measure("Audio player release") { preparingPlayer = nil }
            unregister(request.id)
            outcome = ConversationPerformance.outcome(for: error)
            onEvent(error is CancellationError ? .stopped : .failed(error))
        }
    }

    private func startMetering(id: UUID) {
        meterTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(25), repeating: .milliseconds(25), leeway: .milliseconds(3))
        timer.setEventHandler { [weak self] in
            guard let self, let active = self.active, active.id == id, let player = active.player else { return }
            if let terminal = active.delegate.terminalResult() {
                self.finish(id: id, event: terminal.event, at: terminal.time)
                return
            }
            active.progress.observe(currentTime: player.currentTime)
            // GCD workers do not provide a RunLoop. Completion must not depend
            // on delegate delivery there; this timer is also a bounded fallback.
            guard player.isPlaying else {
                let now = ProcessInfo.processInfo.systemUptime
                let event: SpeechPlaybackEvent = active.progress.reachedEnd(elapsed: now - active.startedAt)
                    ? .finished : .failed(IrodoriError.invalid("音声の再生が途中で停止しました。"))
                self.finish(id: id, event: event, at: now)
                return
            }
            player.updateMeters()
            let normalized = max(0, min(1, (player.averagePower(forChannel: 0) + 45) / 45))
            active.callback(.meter(normalized))
        }
        meterTimer = timer
        timer.resume()
    }

    private func finish(id: UUID, event: SpeechPlaybackEvent, at time: TimeInterval) {
        guard let ending = active, ending.id == id else { return }
        var event = event
        var time = time
        if case .finished = event, let terminal = ending.delegate.terminalResult() {
            event = terminal.event
            time = terminal.time
        }
        active = nil
        meterTimer?.cancel()
        meterTimer = nil
        unregister(id)
        ending.context.withValue {
            let outcome: ConversationPerformance.Outcome
            switch event {
            case .finished:
                outcome = .completed
                if let turnID = ending.context.performance?.id { lastCompletion = (turnID, time) }
            case .stopped:
                outcome = .cancelled
                lastCompletion = nil
            default:
                outcome = .failed
                lastCompletion = nil
            }
            ConversationPerformance.end("Audio playback", ending.interval, outcome: outcome)
            ending.player?.delegate = nil
            ConversationPerformance.measure("Audio player stop") { ending.player?.stop() }
            ConversationPerformance.measure("Audio player release") { ending.player = nil }
            ending.callback(event)
        }
    }
}
