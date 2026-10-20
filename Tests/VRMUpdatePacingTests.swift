import Foundation

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

@main
struct VRMUpdatePacingTests {
    static let hz60 = 1.0 / 60.0
    static let hz30 = 1.0 / 30.0
    static let hz120 = 1.0 / 120.0

    static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw TestFailure(description: message) }
    }

    static func near(_ actual: Double,
                     _ expected: Double,
                     tolerance: Double = 1e-9,
                     _ message: String) throws {
        guard abs(actual - expected) <= tolerance else {
            throw TestFailure(description: "\(message): \(actual) != \(expected)")
        }
    }

    /// A deterministic generator for render jitter, so rates and conservation are repeatable.
    private struct SeededGenerator {
        var state: UInt64

        mutating func unit() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) * (1.0 / 9_007_199_254_740_992.0)
        }

        /// A jitter with a magnitude uniformly drawn from `minimum...maximum`, either sign.
        mutating func jitter(minimum: Double, maximum: Double) -> Double {
            let magnitude = minimum + unit() * (maximum - minimum)
            return (unit() * 2 - 1) * magnitude
        }
    }

    struct PacingRun {
        let steps: [Double]
        let delivered: Double
        let advanced: Double
        let pending: Double
        let schedulingPhase: Double
    }

    static func run(_ deltas: [Double], target: TimeInterval) -> PacingRun {
        var pacer = VRMUpdatePacer(minimumUpdateInterval: target)
        var steps: [Double] = []
        steps.reserveCapacity(deltas.count)
        var delivered = 0.0
        var advanced = 0.0
        for delta in deltas {
            delivered += delta
            if let step = pacer.advance(deltaTime: delta) {
                steps.append(step)
                advanced += step
            }
        }
        return PacingRun(steps: steps,
                         delivered: delivered,
                         advanced: advanced,
                         pending: pacer.pendingDeltaTime,
                         schedulingPhase: pacer.schedulingPhase)
    }

    static func jitteredDeltas(frameRate: Double,
                               frames: Int,
                               seed: UInt64) -> [Double] {
        var generator = SeededGenerator(state: seed)
        var deltas: [Double] = []
        deltas.reserveCapacity(frames)
        for _ in 0..<frames {
            deltas.append(1.0 / frameRate + generator.jitter(minimum: 0.001, maximum: 0.002))
        }
        return deltas
    }

    static func variableRateDeltas(frames: Int, seed: UInt64) -> [Double] {
        let rates = [90.0, 80.0, 120.0, 144.0, 100.0]
        var generator = SeededGenerator(state: seed)
        var deltas: [Double] = []
        deltas.reserveCapacity(frames)
        for frame in 0..<frames {
            deltas.append(1.0 / rates[frame % rates.count] +
                          generator.jitter(minimum: 0.001, maximum: 0.002))
        }
        return deltas
    }

    /// Checks that a run emits at the target average rate and that no real time is lost or
    /// counted twice. All the runs using it stay below the 0.1 s cap, so conservation is exact.
    static func checkConservation(_ run: PacingRun,
                                  target: TimeInterval,
                                  _ label: String) throws {
        let expectedSteps = run.delivered / target
        try expect(abs(Double(run.steps.count) - expectedSteps) <= 2,
                   "\(label) stepped \(run.steps.count) times, expected about \(expectedSteps)")
        try near(run.advanced + run.pending, run.delivered, tolerance: 1e-9,
                 "\(label): emitted time + pending time != input time")
        try expect(run.steps.allSatisfy { $0 > 0 && $0 <= VRMUpdatePacer.maximumStep },
                   "\(label) produced an out-of-range step")
        try expect(run.pending >= 0, "\(label) left negative pending time")
        try expect(abs(run.schedulingPhase) < target,
                   "\(label) left the scheduling phase outside one target interval")
    }

    static func main() throws {
        let tests: [(String, () throws -> Void)] = [
            ("60 Hz nominal steps every frame and preserves elapsed time", {
                var pacer = VRMUpdatePacer(minimumUpdateInterval: hz60)
                var delivered = 0.0
                var advanced = 0.0
                var steps = 0
                for _ in 0..<600 {
                    delivered += hz60
                    if let step = pacer.advance(deltaTime: hz60) {
                        steps += 1
                        advanced += step
                    }
                }
                try expect(steps == 600, "target 60 dropped frames at a nominal 60 Hz: \(steps)")
                try near(advanced, delivered, "simulation time drifted at a nominal 60 Hz")
                try expect(pacer.pendingDeltaTime == 0, "collected time left after a step")
            }),
            ("60 Hz with ±0.1 ms jitter still steps every frame", {
                // The regression: a negative jitter used to leave a frame just short of the
                // target, drop the remainder, and turn a 60 Hz target into roughly 40 fps.
                let jitters = [0.0001, -0.0001, 0.0, 0.00007, -0.00009, 0.00003]
                var pacer = VRMUpdatePacer(minimumUpdateInterval: hz60)
                var delivered = 0.0
                var advanced = 0.0
                var steps = 0
                for frame in 0..<6000 {
                    let delta = hz60 + jitters[frame % jitters.count]
                    delivered += delta
                    if let step = pacer.advance(deltaTime: delta) {
                        steps += 1
                        advanced += step
                    }
                }
                try expect(steps == 6000, "jittered 60 Hz target stepped \(steps) times, not 6000")
                try near(advanced, delivered, "jittered 60 Hz simulation time drifted")
            }),
            ("120 Hz frames step at a 60 Hz target", {
                var pacer = VRMUpdatePacer(minimumUpdateInterval: hz60)
                var delivered = 0.0
                var advanced = 0.0
                var steps = 0
                for _ in 0..<1200 {
                    delivered += hz120
                    if let step = pacer.advance(deltaTime: hz120) {
                        steps += 1
                        advanced += step
                        try near(step, hz60, tolerance: 1e-12, "120 Hz step was not two frames")
                    }
                }
                try expect(steps == 600, "120 Hz to 60 Hz stepped \(steps) times, not 600")
                try near(advanced, delivered, "120 Hz to 60 Hz simulation time drifted")
            }),
            ("120 Hz with jitter keeps the 60 Hz cadence", {
                let jitters = [0.0001, -0.0001, 0.0, 0.00008]
                var deltas: [Double] = []
                deltas.reserveCapacity(2400)
                for frame in 0..<2400 {
                    deltas.append(hz120 + jitters[frame % jitters.count])
                }
                let run = run(deltas, target: hz60)
                try checkConservation(run, target: hz60, "jittered 120 Hz to 60 Hz")
            }),
            ("90 Hz frames average a 60 Hz target with seeded 1-2 ms jitter", {
                let run = run(jitteredDeltas(frameRate: 90, frames: 9000, seed: 0x9_0_90),
                              target: hz60)
                try checkConservation(run, target: hz60, "90 Hz to 60 Hz")
            }),
            ("90 Hz without jitter alternates one and two frame gaps", {
                var pacer = VRMUpdatePacer(minimumUpdateInterval: hz60)
                var gaps: [Int] = []
                var framesSinceStep = 0
                for _ in 0..<300 {
                    framesSinceStep += 1
                    if pacer.advance(deltaTime: 1.0 / 90.0) != nil {
                        gaps.append(framesSinceStep)
                        framesSinceStep = 0
                    }
                }
                try expect(Array(gaps.prefix(6)) == [2, 1, 2, 1, 2, 1],
                           "90 Hz cadence was not 2, 1, 2, 1: \(gaps.prefix(6))")
                try expect(gaps.allSatisfy { $0 == 1 || $0 == 2 },
                           "90 Hz produced a gap longer than two frames: \(gaps)")
            }),
            ("80 Hz frames average a 60 Hz target with seeded 1-2 ms jitter", {
                let run = run(jitteredDeltas(frameRate: 80, frames: 8000, seed: 0x8_0_80),
                              target: hz60)
                try checkConservation(run, target: hz60, "80 Hz to 60 Hz")
            }),
            ("120 Hz frames average a 30 Hz target with seeded 1-2 ms jitter", {
                let run = run(jitteredDeltas(frameRate: 120, frames: 12000, seed: 0x1_20_30),
                              target: hz30)
                try checkConservation(run, target: hz30, "120 Hz to 30 Hz")
            }),
            ("variable render rates at or above 60 Hz keep a 60 Hz average", {
                let run = run(variableRateDeltas(frames: 10000, seed: 0xC0FFEE), target: hz60)
                try checkConservation(run, target: hz60, "variable rates")
            }),
            ("60 Hz frames step at a 30 Hz target", {
                var pacer = VRMUpdatePacer(minimumUpdateInterval: hz30)
                var delivered = 0.0
                var advanced = 0.0
                var steps = 0
                for _ in 0..<600 {
                    delivered += hz60
                    if let step = pacer.advance(deltaTime: hz60) {
                        steps += 1
                        advanced += step
                    }
                }
                try expect(steps == 300, "60 Hz to 30 Hz stepped \(steps) times, not 300")
                try near(advanced, delivered, "60 Hz to 30 Hz simulation time drifted")
            }),
            ("120 Hz frames step at a 30 Hz target", {
                var pacer = VRMUpdatePacer(minimumUpdateInterval: hz30)
                var delivered = 0.0
                var advanced = 0.0
                var steps = 0
                for _ in 0..<1200 {
                    delivered += hz120
                    if let step = pacer.advance(deltaTime: hz120) {
                        steps += 1
                        advanced += step
                    }
                }
                try expect(steps == 300, "120 Hz to 30 Hz stepped \(steps) times, not 300")
                try near(advanced, delivered, "120 Hz to 30 Hz simulation time drifted")
            }),
            ("60 and 30 Hz target changes preserve elapsed time without bursts", {
                let schedule: [(TimeInterval, Int)] = [
                    (hz60, 73), (hz30, 85), (hz60, 67), (hz30, 51), (hz60, 94), (hz30, 64)
                ]
                var pacer = VRMUpdatePacer(minimumUpdateInterval: hz60)
                var delivered = 0.0
                var advanced = 0.0
                var steps = 0
                for (interval, frames) in schedule {
                    pacer.minimumUpdateInterval = interval
                    for _ in 0..<frames {
                        delivered += hz60
                        if let step = pacer.advance(deltaTime: hz60) {
                            steps += 1
                            advanced += step
                            try expect(step > 0 && step <= VRMUpdatePacer.maximumStep,
                                       "target change produced an out-of-range step: \(step)")
                        }
                    }
                }
                try expect(steps > 0, "no steps across target changes")
                try near(advanced, delivered, "target changes lost or duplicated simulation time")
            }),
            ("a target change keeps collected time", {
                var pacer = VRMUpdatePacer(minimumUpdateInterval: hz30)
                try expect(pacer.advance(deltaTime: 0.010) == nil,
                           "10 ms stepped before the 30 Hz target")
                pacer.minimumUpdateInterval = hz60
                let step = try unwrap(pacer.advance(deltaTime: 0.010), "20 ms did not step at 60 Hz")
                try near(step, 0.020, tolerance: 1e-12,
                         "switching 30 to 60 Hz dropped time collected at 30 Hz")
            }),
            ("disabling throttling flushes collected time", {
                var pacer = VRMUpdatePacer(minimumUpdateInterval: hz60)
                try expect(pacer.advance(deltaTime: 0.010) == nil,
                           "10 ms stepped before the 60 Hz target")
                pacer.minimumUpdateInterval = 0
                let passthrough = try unwrap(pacer.advance(deltaTime: 0.010), "disabled pacer skipped a frame")
                try near(passthrough, 0.010, tolerance: 1e-12, "disabled pacer changed the delta")
                pacer.minimumUpdateInterval = hz60
                try expect(pacer.advance(deltaTime: 0.010) == nil,
                           "re-enabling throttling replayed time from before it was disabled")
            }),
            ("zero delta still ticks with no time and leaves collected time alone", {
                var pacer = VRMUpdatePacer(minimumUpdateInterval: hz60)
                let zero = try unwrap(pacer.advance(deltaTime: 0), "zero delta skipped the frame")
                try expect(zero == 0, "zero delta advanced time")
                try expect(pacer.advance(deltaTime: 0.010) == nil, "10 ms stepped early")
                let secondZero = try unwrap(pacer.advance(deltaTime: 0), "second zero delta skipped the frame")
                try expect(secondZero == 0, "second zero delta advanced time")
                let step = try unwrap(pacer.advance(deltaTime: 0.010), "20 ms did not step")
                try near(step, 0.020, tolerance: 1e-12, "zero-delta frames consumed collected time")
            }),
            ("disabled throttling passes deltas through unchanged", {
                var pacer = VRMUpdatePacer()
                for delta in [0.0, 0.000_001, 0.5, 2.0] {
                    let step = try unwrap(pacer.advance(deltaTime: delta), "disabled pacer skipped \(delta)")
                    try near(step, delta, tolerance: 0, "disabled pacer changed \(delta)")
                }
                try expect(pacer.pendingDeltaTime == 0, "disabled pacer collected time")
            }),
            ("invalid intervals disable throttling", {
                for interval in [-1.0, -Double.infinity, Double.nan, Double.infinity] {
                    var pacer = VRMUpdatePacer(minimumUpdateInterval: interval)
                    let step = try unwrap(pacer.advance(deltaTime: 0.5), "invalid interval skipped a frame")
                    try near(step, 0.5, tolerance: 0, "invalid interval \(interval) changed the delta")
                }
            }),
            ("non-finite and negative deltas contribute no time", {
                var pacer = VRMUpdatePacer(minimumUpdateInterval: hz60)
                try expect(pacer.advance(deltaTime: 0.010) == nil, "10 ms stepped early")
                for delta in [Double.nan, .infinity, -.infinity, -0.5, -0.0] {
                    let step = try unwrap(pacer.advance(deltaTime: delta), "invalid delta skipped the frame")
                    try expect(step == 0, "invalid delta \(delta) advanced time")
                }
                let step = try unwrap(pacer.advance(deltaTime: 0.010), "20 ms did not step")
                try near(step, 0.020, tolerance: 1e-12, "invalid deltas polluted collected time")
            }),
            ("a long gap is one capped step, not a catch-up backlog", {
                var pacer = VRMUpdatePacer(minimumUpdateInterval: hz60)
                let hitch = try unwrap(pacer.advance(deltaTime: 5.0), "long gap skipped completely")
                try near(hitch, VRMUpdatePacer.maximumStep, tolerance: 0, "long gap was not capped")
                try expect(pacer.pendingDeltaTime == 0, "long gap left a backlog")
                let next = try unwrap(pacer.advance(deltaTime: hz60), "frame after a gap was skipped")
                try near(next, hz60, tolerance: 1e-12, "frame after a gap replayed the backlog")

                var throttled30 = VRMUpdatePacer(minimumUpdateInterval: hz30)
                let hitch30 = try unwrap(throttled30.advance(deltaTime: 0.25), "30 Hz long gap skipped")
                try near(hitch30, VRMUpdatePacer.maximumStep, tolerance: 0, "30 Hz gap was not capped")
                try expect(throttled30.advance(deltaTime: hz60) == nil,
                           "30 Hz gap replayed immediately")
                let after30 = try unwrap(throttled30.advance(deltaTime: hz60), "30 Hz frame after gap skipped")
                try near(after30, 2 * hz60, tolerance: 1e-12, "30 Hz gap left extra time to replay")
            }),
            ("moderately long frame is capped and dropped", {
                var pacer = VRMUpdatePacer(minimumUpdateInterval: hz60)
                let step = try unwrap(pacer.advance(deltaTime: 0.25), "250 ms frame skipped")
                try near(step, VRMUpdatePacer.maximumStep, tolerance: 0, "250 ms frame exceeded the cap")
                try expect(pacer.pendingDeltaTime == 0, "250 ms frame left 150 ms to replay")
            }),
            ("reset forgets collected time", {
                var pacer = VRMUpdatePacer(minimumUpdateInterval: hz60)
                try expect(pacer.advance(deltaTime: 0.010) == nil, "10 ms stepped early")
                pacer.reset()
                try expect(pacer.pendingDeltaTime == 0, "reset left collected time")
                try expect(pacer.advance(deltaTime: 0.010) == nil, "reset did not discard 10 ms")
            })
        ]
        for (name, test) in tests {
            try test()
            print("PASS: \(name)")
        }
        print("\(tests.count) tests passed")
    }

    static func unwrap<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw TestFailure(description: message) }
        return value
    }
}
