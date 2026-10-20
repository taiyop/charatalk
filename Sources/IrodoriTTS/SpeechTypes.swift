// Modified for CharaTalk: shared speech.cpp types extracted from the removed Core ML engine.
// Derived from Corvelis/irodori-tts-iphone; see NOTICE and THIRD_PARTY_NOTICES.md.
import Foundation

public struct PCMChunk: Sendable {
    public let pcm16: Data
    public let sampleRate = 48_000
    public let sequence: Int
    public init(pcm16: Data, sequence: Int) { self.pcm16 = pcm16; self.sequence = sequence }
}

public struct SynthesisResult: Sendable {
    public let pcm16: Data
    public let preparedText: String
    public let synthesisMilliseconds: Double
    public let firstPCMMilliseconds: Double
    public let sentenceCount: Int
    public let metrics: [[String: Double]]
    public let diagnostics: [[String: String]]
    public let watermark: WatermarkInfo?
    public let memory: MemoryObservation?
    public init(pcm16: Data, preparedText: String, synthesisMilliseconds: Double,
                firstPCMMilliseconds: Double, sentenceCount: Int = 1,
                metrics: [[String: Double]] = [], diagnostics: [[String: String]] = [],
                watermark: WatermarkInfo? = nil, memory: MemoryObservation? = nil) {
        self.pcm16 = pcm16; self.preparedText = preparedText
        self.synthesisMilliseconds = synthesisMilliseconds; self.firstPCMMilliseconds = firstPCMMilliseconds
        self.sentenceCount = sentenceCount; self.metrics = metrics; self.diagnostics = diagnostics
        self.watermark = watermark; self.memory = memory
    }
    /// One actual seed per generated sentence, including randomly selected seeds.
    public var generationSeeds: [UInt32] {
        metrics.compactMap { values in
            guard let seed = values["generationSeed"] else { return nil }
            return UInt32(exactly: seed)
        }
    }
    public var audioSeconds: Double { Double(pcm16.count) / 96_000 }
    public var rtf: Double { synthesisMilliseconds / 1000 / max(audioSeconds, 0.000001) }
    public func writeWAV(to url: URL) throws { try ReferenceAudio.writeWAV(pcm16: pcm16, to: url) }
}

public struct ReferenceRegistration: Sendable {
    public let milliseconds: Double
    public let cacheHit: Bool
    public init(milliseconds: Double, cacheHit: Bool) { self.milliseconds = milliseconds; self.cacheHit = cacheHit }
}
