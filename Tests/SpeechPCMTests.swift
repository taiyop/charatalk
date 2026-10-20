import Foundation

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

@main
struct SpeechPCMTests {
    static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw TestFailure(description: message) }
    }

    static func pcm(_ samples: [Int16]) -> Data {
        var result = Data(capacity: samples.count * 2)
        for sample in samples {
            var littleEndian = sample.littleEndian
            withUnsafeBytes(of: &littleEndian) { result.append(contentsOf: $0) }
        }
        return result
    }

    static func samples(_ pcm: Data) -> [Int16] {
        pcm.withUnsafeBytes { bytes in
            (0..<(pcm.count / 2)).map {
                Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self))
            }
        }
    }

    static func silence(_ milliseconds: Int) -> [Int16] {
        Array(repeating: 0, count: milliseconds * 48)
    }

    static func tone(_ milliseconds: Int, amplitude: Int16 = 3_000) -> [Int16] {
        (0..<(milliseconds * 48)).map { $0.isMultiple(of: 2) ? amplitude : -amplitude }
    }

    static func main() throws {
        let tests: [(String, () throws -> Void)] = [
            ("decoder edge padding removed, original speech preserved", {
                let voice = tone(300)
                let original = pcm(silence(600) + voice + silence(800))
                let trimmed = SpeechPCM.trimmingEdgeSilence(original)
                try expect(trimmed == pcm(silence(120) + voice + silence(160)),
                           "retain exactly 120 ms lead / 160 ms tail around aligned activity")
                try expect(original.count == 1_700 * 48 * 2, "input mutated")
            }),
            ("two segments have bounded boundary silence", {
                let original = pcm(silence(800) + tone(300) + silence(900))
                let trimmed = SpeechPCM.trimmingEdgeSilence(original)
                let joined = samples(trimmed + trimmed)
                let active = joined.indices.filter { joined[$0] != 0 }
                var longestGap = 0
                for (before, after) in zip(active, active.dropFirst()) {
                    longestGap = max(longestGap, after - before - 1)
                }
                try expect(longestGap == 280 * 48, "sentence boundary should have 280 ms, not 1.7 s")
            }),
            ("internal pauses are unchanged", {
                let voice = tone(100) + silence(900) + tone(100)
                let trimmed = SpeechPCM.trimmingEdgeSilence(pcm(silence(500) + voice + silence(500)))
                try expect(trimmed == pcm(silence(120) + voice + silence(160)), "internal pause clipped")
            }),
            ("empty and malformed input is unchanged", {
                for data in [Data(), Data([0]), Data([1, 2, 3])] {
                    try expect(SpeechPCM.trimmingEdgeSilence(data) == data, "invalid input modified")
                }
            }),
            ("silence and entirely quiet speech remain unchanged", {
                for data in [pcm(silence(500)), pcm(tone(500, amplitude: 20))] {
                    try expect(SpeechPCM.trimmingEdgeSilence(data) == data, "quiet clip discarded")
                }
            }),
            ("subthreshold noise does not extend padding", {
                let voice = tone(100)
                let original = pcm(tone(600, amplitude: 20) + voice + tone(600, amplitude: 20))
                try expect(SpeechPCM.trimmingEdgeSilence(original) ==
                           pcm(tone(120, amplitude: 20) + voice + tone(160, amplitude: 20)),
                           "low background noise treated as speech")
            }),
            ("soft onset and decay are retained", {
                let voice = tone(80, amplitude: 40) + tone(100) + tone(120, amplitude: 40)
                let trimmed = SpeechPCM.trimmingEdgeSilence(pcm(silence(600) + voice + silence(600)))
                try expect(trimmed == pcm(silence(40) + voice + silence(40)), "quiet consonant/decay clipped")
            }),
            ("no padding does not add silence", {
                let original = pcm(tone(100))
                try expect(SpeechPCM.trimmingEdgeSilence(original) == original, "unpadded audio modified")
            }),
            ("unaligned activity keeps complete speech and block safety margin", {
                let voice = tone(113)
                let trimmed = samples(SpeechPCM.trimmingEdgeSilence(pcm(silence(603) + voice + silence(703))))
                guard let first = trimmed.firstIndex(where: { $0 != 0 }),
                      let last = trimmed.lastIndex(where: { $0 != 0 }) else {
                    throw TestFailure(description: "speech removed")
                }
                try expect(Array(trimmed[first...last]) == voice, "speech samples changed")
                try expect((120 * 48..<140 * 48).contains(first), "unsafe leading margin")
                try expect((160 * 48..<180 * 48).contains(trimmed.count - last - 1), "unsafe trailing margin")
            }),
            ("partial final block and full PCM16 range are safe", {
                let original = pcm(silence(500) + [-32_768, 32_767])
                let trimmed = SpeechPCM.trimmingEdgeSilence(original)
                try expect(trimmed == pcm(silence(120) + [-32_768, 32_767]), "final samples lost")
            }),
            ("sliced data with nonzero indices is supported", {
                let original = pcm(silence(600) + tone(100) + silence(600))
                var prefixed = Data([42, 43])
                prefixed.append(original)
                let slice = prefixed.dropFirst(2)
                try expect(SpeechPCM.trimmingEdgeSilence(slice) == SpeechPCM.trimmingEdgeSilence(original),
                           "Data indices mistaken for raw sample offsets")
            })
        ]
        for (name, test) in tests {
            try test()
            print("PASS: \(name)")
        }
        print("\(tests.count) tests passed")
    }
}
