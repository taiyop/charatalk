import Foundation

/// Turns the render frames a model is ticked on into the steps its simulation advances by,
/// throttling the steps to a target rate without slowing the simulation down.
///
/// Render deltas jitter around the display's frame time: a 90 Hz display gives deltas of
/// `1.0 / 90.0`, two of which are just over `1.0 / 60.0` and one of which is short. The pacer
/// keeps two clocks apart:
///
/// - ``pendingDeltaTime`` is the real time since the last step. A step advances the simulation
///   by all of it, so throttling never slows the simulation down.
/// - ``schedulingPhase`` is the time collected toward the next step. It keeps the leftover
///   after a step - the phase above the target interval - so 90 Hz frames settle into the
///   1, 2, 1, 2 frame cadence a 60 Hz target asks for. The leftover never reaches the
///   simulation, so it is not counted twice.
///
/// A long gap, such as a frame that took a quarter of a second, is one hitch rather than a
/// backlog: the step is capped at ``maximumStep``, the excess time is dropped, and the
/// scheduling phase restarts instead of replaying the missed cadence.
public struct VRMUpdatePacer: Equatable, Sendable {
    /// The longest step ``advance(deltaTime:)`` returns, in seconds.
    public static let maximumStep: TimeInterval = 0.1

    /// How far short of the target a frame may fall and still step, as a fraction of the
    /// target interval, capped at ``maximumTolerance``. Render jitter is far smaller than this.
    private static let toleranceFraction: TimeInterval = 0.05
    private static let maximumTolerance: TimeInterval = 0.002

    /// The minimum interval between steps, in seconds. Zero disables throttling, and so does
    /// a negative or non-finite value.
    public var minimumUpdateInterval: TimeInterval {
        didSet {
            if !Self.isThrottlingEnabled(minimumUpdateInterval) {
                reset()
            }
        }
    }

    /// The real time collected since the last step. Nil steps leave it untouched.
    public private(set) var pendingDeltaTime: TimeInterval = 0

    /// The time collected toward the next step, less the target intervals already stepped.
    ///
    /// Its magnitude stays below one target interval; a small negative value means the last
    /// step was taken within the near-deadline tolerance. Only the schedule uses it.
    public private(set) var schedulingPhase: TimeInterval = 0

    public init(minimumUpdateInterval: TimeInterval = 0) {
        self.minimumUpdateInterval = minimumUpdateInterval
    }

    /// The time `deltaTime` should advance the simulation by, or nil when this frame is
    /// skipped because too little time has collected yet.
    ///
    /// A zero - or negative or non-finite, which carry no usable time - delta returns zero
    /// rather than nil, so the caller still gets its frame with nothing to advance, as it did
    /// with throttling off.
    public mutating func advance(deltaTime: TimeInterval) -> TimeInterval? {
        let delta = Self.sanitized(deltaTime)

        guard Self.isThrottlingEnabled(minimumUpdateInterval) else {
            reset()
            return delta
        }
        guard delta > 0 else { return 0 }

        pendingDeltaTime += delta
        schedulingPhase += delta
        guard pendingDeltaTime.isFinite, schedulingPhase.isFinite else {
            reset()
            return Self.maximumStep
        }

        let interval = minimumUpdateInterval
        let tolerance = min(interval * Self.toleranceFraction, Self.maximumTolerance)
        guard schedulingPhase + tolerance >= interval else { return nil }

        // A step advances by all the real time since the last one, not by the target
        // interval, so the simulation keeps pace with the display rather than slowing down.
        let clamped = pendingDeltaTime > Self.maximumStep
        let step = clamped ? Self.maximumStep : pendingDeltaTime
        pendingDeltaTime = 0

        // Carry the cadence phase, not the simulation time, across steps. Whole target
        // intervals are dropped, so a frame spanning several of them cannot make the next
        // frames catch up; a step capped by a hitch restarts the cadence outright.
        if clamped {
            schedulingPhase = 0
        } else {
            schedulingPhase = (schedulingPhase - interval).truncatingRemainder(dividingBy: interval)
        }
        return step
    }

    /// Forgets the time collected so far.
    public mutating func reset() {
        pendingDeltaTime = 0
        schedulingPhase = 0
    }

    private static func isThrottlingEnabled(_ interval: TimeInterval) -> Bool {
        interval.isFinite && interval > 0
    }

    private static func sanitized(_ deltaTime: TimeInterval) -> TimeInterval {
        deltaTime.isFinite && deltaTime > 0 ? deltaTime : 0
    }
}
