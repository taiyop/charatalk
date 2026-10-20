import Foundation

/// Playback preparation for the synthesizer's 48 kHz, mono, little-endian PCM16.
public enum SpeechPCM {
    /// Removes decoder padding only at the edges, not pauses inside a sentence.
    /// Retain 120 ms before speech and 160 ms after it to protect quiet consonants
    /// and decay, and to leave a short, natural pause between prepared segments.
    /// Malformed, silent, or entirely quiet input is left unchanged.
    public static func trimmingEdgeSilence(_ pcm16: Data) -> Data {
        guard !pcm16.isEmpty, pcm16.count.isMultiple(of: 2) else { return pcm16 }

        let sampleCount = pcm16.count / 2
        let blockSamples = 960 // 20 ms at 48 kHz.
        let leadSamples = 5_760 // 120 ms.
        let tailSamples = 7_680 // 160 ms, including the sentence pause.
        let thresholdAmplitude: Double = 0.002 * 32_768
        let thresholdEnergy = thresholdAmplitude * thresholdAmplitude

        return pcm16.withUnsafeBytes { bytes in
            var firstActive: Int?
            var lastActiveEnd = 0
            for begin in stride(from: 0, to: sampleCount, by: blockSamples) {
                let end = min(begin + blockSamples, sampleCount)
                var energy = 0.0
                for index in begin..<end {
                    let sample = Double(Int16(littleEndian:
                        bytes.loadUnaligned(fromByteOffset: index * 2, as: Int16.self)))
                    energy += sample * sample
                }
                if energy > thresholdEnergy * Double(end - begin) {
                    if firstActive == nil { firstActive = begin }
                    lastActiveEnd = end
                }
            }

            guard let firstActive else { return pcm16 }
            let start = max(0, firstActive - leadSamples)
            let end = min(sampleCount, lastActiveEnd + tailSamples)
            guard start > 0 || end < sampleCount else { return pcm16 }
            return Data(bytes: bytes.baseAddress!.advanced(by: start * 2), count: (end - start) * 2)
        }
    }
}
