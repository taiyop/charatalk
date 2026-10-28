import Foundation
import os

/// Local, metadata-only diagnostics. Task-local context follows the existing
/// conversation and lookahead tasks without publishing more SwiftUI state.
struct ConversationPerformance: Sendable {
    @TaskLocal static var current: ConversationPerformance? = nil
    @TaskLocal static var chunkIndex: Int = -1
    @TaskLocal static var previousPlaybackFinishedAt: TimeInterval? = nil

    private static let logger = Logger(subsystem: "com.aituber.charatalk", category: "ConversationPerformance")
    private static let signposter = OSSignposter(logger: logger)

    let id: String
    let startedAt: TimeInterval
    private var replyReadyAt: TimeInterval?

    enum Outcome: String {
        case completed, failed, cancelled
    }

    struct Interval: Sendable {
        fileprivate let trace: ConversationPerformance
        fileprivate let chunk: Int
        fileprivate let startedAt: TimeInterval
        fileprivate let state: OSSignpostIntervalState
    }

    /// Provider/mode must be application enum raw values, never a URL, model
    /// response, credential, prompt, caption, or user-entered string.
    init(provider: String, mode: String) {
        id = UUID().uuidString
        startedAt = ProcessInfo.processInfo.systemUptime
        let turnID = id
        Self.logger.info("turn=\(turnID, privacy: .public) event=turn_started provider=\(provider, privacy: .public) mode=\(mode, privacy: .public) thermal_state=\(ProcessInfo.processInfo.thermalState.rawValue)")
    }

    func recordingReplyReady() -> Self {
        var trace = self
        trace.replyReadyAt = ProcessInfo.processInfo.systemUptime
        return trace
    }

    static func begin(_ phase: StaticString) -> Interval? {
        guard let trace = current else { return nil }
        let chunk = chunkIndex
        let state = signposter.beginInterval(phase, id: signposter.makeSignpostID(),
                                             "turn=\(trace.id, privacy: .public) chunk=\(chunk)")
        return Interval(trace: trace, chunk: chunk,
                        startedAt: ProcessInfo.processInfo.systemUptime, state: state)
    }

    static func end(_ phase: StaticString, _ interval: Interval?, outcome: Outcome) {
        guard let interval else { return }
        signposter.endInterval(phase, interval.state, "outcome=\(outcome.rawValue, privacy: .public)")
        let milliseconds = max(0, ProcessInfo.processInfo.systemUptime - interval.startedAt) * 1_000
        logger.info("turn=\(interval.trace.id, privacy: .public) phase=\(String(describing: phase), privacy: .public) chunk=\(interval.chunk) milliseconds=\(milliseconds, format: .fixed(precision: 2)) outcome=\(outcome.rawValue, privacy: .public)")
    }

    static func measure<T>(_ phase: StaticString, operation: () throws -> T) rethrows -> T {
        let interval = begin(phase)
        do {
            let value = try operation()
            end(phase, interval, outcome: .completed)
            return value
        } catch {
            end(phase, interval, outcome: outcome(for: error))
            throw error
        }
    }

    static func measureAsync<T: Sendable>(
        _ phase: StaticString, operation: @Sendable () async throws -> T
    ) async rethrows -> T {
        let interval = begin(phase)
        do {
            let value = try await operation()
            end(phase, interval, outcome: .completed)
            return value
        } catch {
            end(phase, interval, outcome: outcome(for: error))
            throw error
        }
    }

    static func outcome(for error: Error) -> Outcome {
        error is CancellationError || Task.isCancelled ? .cancelled : .failed
    }

    func duration(_ metric: StaticString, seconds: TimeInterval, chunk: Int = -1) {
        guard seconds.isFinite, seconds >= 0 else { return }
        let milliseconds = seconds * 1_000
        Self.logger.info("turn=\(self.id, privacy: .public) metric=\(String(describing: metric), privacy: .public) chunk=\(chunk) milliseconds=\(milliseconds, format: .fixed(precision: 2))")
    }

    func value(_ metric: StaticString, value: Double, chunk: Int = -1) {
        guard value.isFinite else { return }
        Self.logger.info("turn=\(self.id, privacy: .public) metric=\(String(describing: metric), privacy: .public) chunk=\(chunk) value=\(value, format: .fixed(precision: 3))")
    }

    static func event(_ name: StaticString) {
        guard let trace = current else { return }
        signposter.emitEvent(name, "turn=\(trace.id, privacy: .public) chunk=\(chunkIndex)")
    }

    /// First node.play() acceptance, or an observed transition to the next
    /// prequeued buffer. This is not measured acoustic/Bluetooth output timing.
    func audioStarted() {
        let now = ProcessInfo.processInfo.systemUptime
        let chunk = Self.chunkIndex
        Self.event("Audio start accepted")
        if let previous = Self.previousPlaybackFinishedAt {
            duration("inter_chunk_gap", seconds: now - previous, chunk: chunk)
        }
        if chunk == 0 {
            duration("turn_to_first_audio", seconds: now - startedAt, chunk: chunk)
            if let replyReadyAt {
                duration("reply_to_first_audio", seconds: now - replyReadyAt, chunk: chunk)
            }
            value("thermal_state_at_first_audio", value: Double(ProcessInfo.processInfo.thermalState.rawValue), chunk: chunk)
        }
    }
}
