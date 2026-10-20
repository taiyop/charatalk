import Foundation

/// Best-effort completion fallback for players whose delegate needs a RunLoop.
/// A stopped player is not automatically a successfully completed player.
public struct SpeechPlaybackProgress: Sendable {
    private let duration: TimeInterval
    private let rate: Double
    private var furthestTime: TimeInterval = 0
    // Two 25ms meter ticks accommodate end-of-buffer and scheduling jitter.
    private static let endTolerance: TimeInterval = 0.050

    public init(duration: TimeInterval, rate: Float) {
        self.duration = duration
        self.rate = Double(rate)
    }

    public mutating func observe(currentTime: TimeInterval) {
        guard currentTime.isFinite, currentTime >= 0 else { return }
        furthestTime = max(furthestTime, currentTime)
    }

    public func reachedEnd(elapsed: TimeInterval) -> Bool {
        guard duration.isFinite, duration > 0, rate.isFinite, rate > 0,
              elapsed.isFinite, elapsed >= 0 else { return false }
        // Some players reset currentTime at completion; retain progress and
        // also consider monotonic elapsed time. This is not an acoustic clock.
        return furthestTime >= duration - Self.endTolerance * rate ||
            elapsed >= duration / rate - Self.endTolerance
    }
}
