import Foundation

private struct TestFailure: Error { let message: String }

@main
struct SpeechPlaybackProgressTests {
    static func expect(_ value: Bool, _ message: String) throws {
        if !value { throw TestFailure(message: message) }
    }

    static func main() throws {
        let tests: [(String, () throws -> Void)] = [
            ("early stop is not successful completion", {
                var progress = SpeechPlaybackProgress(duration: 4, rate: 1)
                progress.observe(currentTime: 1)
                try expect(!progress.reachedEnd(elapsed: 1), "early stop accepted")
            }),
            ("normal end survives currentTime reset", {
                var progress = SpeechPlaybackProgress(duration: 4, rate: 1)
                progress.observe(currentTime: 3.98)
                progress.observe(currentTime: 0)
                try expect(progress.reachedEnd(elapsed: 4), "normal end rejected")
            }),
            ("elapsed clock handles players that reset without a final progress sample", {
                let progress = SpeechPlaybackProgress(duration: 4, rate: 1)
                try expect(progress.reachedEnd(elapsed: 4), "elapsed end rejected")
            }),
            ("playback speed affects the expected finish", {
                let fast = SpeechPlaybackProgress(duration: 4, rate: 2)
                let slow = SpeechPlaybackProgress(duration: 4, rate: 0.5)
                try expect(fast.reachedEnd(elapsed: 2), "2x end rejected")
                try expect(!fast.reachedEnd(elapsed: 1), "2x early stop accepted")
                try expect(!slow.reachedEnd(elapsed: 4), "0.5x early stop accepted")
                try expect(slow.reachedEnd(elapsed: 8), "0.5x end rejected")
            }),
            ("invalid clocks and settings cannot complete playback", {
                for duration in [Double(0), -1, .nan, .infinity] {
                    try expect(!SpeechPlaybackProgress(duration: duration, rate: 1).reachedEnd(elapsed: 4), "invalid duration accepted")
                }
                for rate in [Float(0), -1, .nan, .infinity] {
                    try expect(!SpeechPlaybackProgress(duration: 4, rate: rate).reachedEnd(elapsed: 4), "invalid rate accepted")
                }
                var progress = SpeechPlaybackProgress(duration: 4, rate: 1)
                progress.observe(currentTime: .infinity)
                progress.observe(currentTime: .nan)
                progress.observe(currentTime: -1)
                try expect(!progress.reachedEnd(elapsed: 1), "invalid position accepted")
                for elapsed in [-1, Double.nan, .infinity] {
                    try expect(!progress.reachedEnd(elapsed: elapsed), "invalid elapsed accepted")
                }
            }),
            ("short valid audio can finish within a meter tick", {
                let progress = SpeechPlaybackProgress(duration: 0.02, rate: 1)
                try expect(progress.reachedEnd(elapsed: 0.025), "short audio rejected")
            })
        ]
        for (name, test) in tests { try test(); print("PASS: \(name)") }
        print("\(tests.count) tests passed")
    }
}
