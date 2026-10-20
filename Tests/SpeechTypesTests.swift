import Foundation
import IrodoriTTS

private struct TestFailure: Error {
    let message: String
}

@main
struct SpeechTypesTests {
    static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw TestFailure(message: message) }
    }

    static func main() throws {
        let pcm = Data([0, 0, 1, 0, 255, 127, 0, 128])
        let chunk = PCMChunk(pcm16: pcm, sequence: 3)
        try expect(chunk.pcm16 == pcm && chunk.sequence == 3 && chunk.sampleRate == 48_000,
                   "Chunk metadata changed")
        print("PASS PCMChunk")

        let defaults = SynthesisResult(pcm16: pcm, preparedText: "こんにちは。",
                                       synthesisMilliseconds: 20, firstPCMMilliseconds: 10)
        try expect(defaults.sentenceCount == 1 && defaults.metrics.isEmpty && defaults.diagnostics.isEmpty,
                   "Result defaults changed")
        try expect(defaults.watermark == nil && defaults.memory == nil,
                   "Optional result metadata changed")
        try expect(defaults.preparedText == "こんにちは。" && defaults.firstPCMMilliseconds == 10,
                   "Result text/timing changed")
        print("PASS SynthesisResult defaults")

        var memory = MemoryObservation()
        memory.peakMiB = 42
        let detailed = SynthesisResult(pcm16: Data(repeating: 0, count: 96_000), preparedText: "test",
                                      synthesisMilliseconds: 500, firstPCMMilliseconds: 100,
                                      sentenceCount: 2,
                                      metrics: [["generationSeed": 123], ["generationSeed": -1],
                                                ["generationSeed": 1.5], ["other": 4],
                                                ["generationSeed": Double(UInt32.max)],
                                                ["generationSeed": Double(UInt32.max) + 1]],
                                      diagnostics: [["backend": "speech.cpp"]], memory: memory)
        try expect(detailed.generationSeeds == [123, UInt32.max], "Seed extraction changed")
        print("PASS generationSeeds")
        try expect(detailed.audioSeconds == 1 && detailed.rtf == 0.5 && detailed.sentenceCount == 2,
                   "Audio duration/RTF changed")
        try expect(detailed.memory?.peakMiB == 42 && detailed.diagnostics == [["backend": "speech.cpp"]],
                   "Result metadata changed")
        print("PASS result timing and metadata")

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("speech-types-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try defaults.writeWAV(to: url)
        let written = try Data(contentsOf: url)
        let expected = try ReferenceAudio.wavData(pcm16: pcm)
        try expect(written == expected && written.suffix(pcm.count) == pcm, "WAV output changed")
        print("PASS writeWAV")

        let registration = ReferenceRegistration(milliseconds: 25, cacheHit: true)
        try expect(registration.milliseconds == 25 && registration.cacheHit,
                   "Reference registration changed")
        print("PASS ReferenceRegistration")
    }
}
