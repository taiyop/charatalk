// Modified for CharaTalk: synthesis, memory and lifecycle integration.
// Derived from Corvelis/irodori-tts-iphone; see root NOTICE and THIRD_PARTY_NOTICES.md.
import Foundation
import CryptoKit
import IrodoriTTS
import IrodoriSpeechNative

private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws { lock.lock(); defer { lock.unlock() }; if cancelled { throw CancellationError() } }
}

/// Optional iPhone backend. Explicit Metal execution; models stay loaded until release().
public final class SpeechCppEngine: @unchecked Sendable {
    private struct ReferenceFileKey: Equatable {
        let path: String
        let size: UInt64
        let modificationDate: Date?
    }

    private let queue = DispatchQueue(label: "IrodoriSpeechCpp.inference", qos: .userInitiated)
    private let native = IrodoriSpeechBridge()
    private var directory: URL?
    private var preparedVariant: SpeechCppModelVariant?
    private var referenceDigest: String?
    private var referenceFileKey: ReferenceFileKey?
    private var hasRegisteredReference = false
    private var processor: AudioWatermarkProcessor?
    private var information: [String: String] = [:]
    public init() {}

    private func perform<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in queue.async {
            // Completion means the autorelease pool has also drained.
            let outcome: Result<T, Error> = autoreleasepool { Result { try body() } }
            continuation.resume(with: outcome)
        }}
    }

    @discardableResult public func prepare(modelDirectory: URL, variant: SpeechCppModelVariant = .f16) async throws -> Double {
        #if targetEnvironment(simulator)
        throw IrodoriError.invalid("speech.cppの音声生成は実機iPhoneで実行してください。Simulatorでは画面の確認ができます。")
        #else
        try await perform {
            let root = modelDirectory.standardizedFileURL
            if self.directory == root && self.preparedVariant == variant { return 0 }
            self.native.releaseModel()
            self.processor = nil
            self.directory = nil
            self.preparedVariant = nil
            self.referenceDigest = nil
            self.referenceFileKey = nil
            self.hasRegisteredReference = false
            AudioWatermarkProcessor.cleanupStaleTemporaryModels()
            try SpeechCppModelBundle.validate(at: root, variant: variant)
            let start = ProcessInfo.processInfo.systemUptime
            do {
                let info = try self.native.prepareModel(root.appendingPathComponent(variant.fileName).path, metal4: true)
                self.information = info.compactMapValues { $0 as? String }
                // AudioWatermarkProcessor is lazily loaded only when watermark is enabled during synthesize().
                self.directory = root
                self.preparedVariant = variant
                return (ProcessInfo.processInfo.systemUptime - start) * 1000
            } catch {
                self.native.releaseModel(); self.processor = nil
                throw error
            }
        }
        #endif
    }

    @discardableResult public func registerReference(_ url: URL?) async throws -> ReferenceRegistration {
        try await perform {
            guard self.directory != nil else { throw IrodoriError.invalid("Prepare a model first") }
            let start = ProcessInfo.processInfo.systemUptime

            // Fast-path: check file metadata before decoding/resampling the reference audio file.
            var candidateKey: ReferenceFileKey?
            if let url {
                let path = url.standardizedFileURL.path
                if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                   let size = attrs[.size] as? UInt64 {
                    let modDate = attrs[.modificationDate] as? Date
                    candidateKey = ReferenceFileKey(path: path, size: size, modificationDate: modDate)
                }
            }
            if self.hasRegisteredReference && self.referenceFileKey == candidateKey && (url == nil || candidateKey != nil) {
                return ReferenceRegistration(milliseconds: (ProcessInfo.processInfo.systemUptime - start) * 1000, cacheHit: true)
            }

            let data = try url.map(ReferenceAudio.read) ?? Data()
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let hit = self.hasRegisteredReference && self.referenceDigest == digest
            if !hit {
                if data.isEmpty { try self.native.registerReference(nil) }
                else {
                    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("irodori-reference-\(UUID().uuidString).wav")
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    var invalid = false
                    var pcm = Data(count: data.count / 2)
                    data.withUnsafeBytes { source in pcm.withUnsafeMutableBytes { output in
                        for index in 0..<(data.count / 4) {
                            let sample = source.loadUnaligned(fromByteOffset: index * 4, as: Float.self)
                            guard sample.isFinite else { invalid = true; break }
                            let value = Int16(max(-32768, min(32767, (Double(sample) * 32768).rounded())))
                            output.storeBytes(of: value.littleEndian, toByteOffset: index * 2, as: Int16.self)
                        }
                    }}
                    guard !invalid else { throw IrodoriError.invalid("Reference audio contains non-finite samples") }
                    try ReferenceAudio.writeWAV(pcm16: pcm, to: temporary)
                    try self.native.registerReference(temporary.path)
                }
                self.referenceDigest = digest
            }
            self.referenceFileKey = candidateKey
            self.hasRegisteredReference = true
            return ReferenceRegistration(milliseconds: (ProcessInfo.processInfo.systemUptime - start) * 1000, cacheHit: hit)
        }
    }

    public struct SynthesisOptions: Sendable, Equatable {
        public var steps: Int
        public var speed: Float
        public var durationScale: Float
        public var swayCoeff: Float?
        public var cfgScaleText: Float?
        public var cfgScaleInstructions: Float?
        public var cfgScaleSpeaker: Float?

        public init(
            steps: Int = 4,
            speed: Float = 1.0,
            durationScale: Float = 1.0,
            swayCoeff: Float? = nil,
            cfgScaleText: Float? = nil,
            cfgScaleInstructions: Float? = nil,
            cfgScaleSpeaker: Float? = nil
        ) {
            self.steps = steps
            self.speed = speed
            self.durationScale = durationScale
            self.swayCoeff = swayCoeff
            self.cfgScaleText = cfgScaleText
            self.cfgScaleInstructions = cfgScaleInstructions
            self.cfgScaleSpeaker = cfgScaleSpeaker
        }

        public var dictionary: [String: Any] {
            var dict: [String: Any] = [
                "steps": steps,
                "speed": speed,
                "durationScale": durationScale
            ]
            if let swayCoeff { dict["swayCoeff"] = swayCoeff }
            if let cfgScaleText { dict["cfgScaleText"] = cfgScaleText }
            if let cfgScaleInstructions { dict["cfgScaleInstructions"] = cfgScaleInstructions }
            if let cfgScaleSpeaker { dict["cfgScaleSpeaker"] = cfgScaleSpeaker }
            return dict
        }
    }

    public func synthesize(_ text: String, caption: String = "", seed: UInt32? = nil,
                           options: SynthesisOptions = SynthesisOptions(),
                           watermark: WatermarkOptions? = WatermarkOptions(),
                           trackMemory: Bool = false,
                           onChunk: (@Sendable (PCMChunk) -> Void)? = nil) async throws -> SynthesisResult {
        let cancellation = CancellationFlag()
        return try await withTaskCancellationHandler(operation: {
            try await self.perform {
                self.native.resetCancellation()
                try cancellation.check()
                guard let root = self.directory else { throw IrodoriError.invalid("Prepare a model first") }
                let prepared = SpeechText.prepare(text)
                guard !prepared.isEmpty else { throw IrodoriError.invalid("No speakable text") }
                let memory = trackMemory ? ProcessMemorySampler() : nil
                defer { _ = memory?.finish() }
                let start = ProcessInfo.processInfo.systemUptime
                let stream: AudioWatermarkStream?
                if let watermark {
                    if self.processor == nil {
                        self.processor = try AudioWatermarkProcessor(modelDirectory: root)
                    }
                    stream = self.processor?.stream(options: watermark)
                } else {
                    stream = nil
                }
                var first = -1.0, sequence = 0
                var callbackError: Error?
                let emit: (Data) -> Void = { bytes in
                    if first < 0 { first = (ProcessInfo.processInfo.systemUptime - start) * 1000 }
                    onChunk?(PCMChunk(pcm16: bytes, sequence: sequence)); sequence += 1
                }
                let output: [String: Any]
                do {
                    output = try self.native.synthesize(
                        prepared,
                        caption: caption,
                        seed: seed ?? UInt32.random(in: .min ... .max),
                        options: options.dictionary,
                        onPcm: { bytes in
                            do {
                                try cancellation.check()
                                if let stream { try stream.append(bytes, onPCM: emit) } else { emit(bytes) }
                            } catch { callbackError = error; self.native.cancel() }
                        }
                    )
                } catch {
                    if let callbackError { throw callbackError }
                    try cancellation.check()
                    throw error
                }
                if let callbackError { throw callbackError }
                try cancellation.check()
                guard let original = output["pcm16"] as? Data else { throw IrodoriError.invalid("No audio returned") }
                if let stream { try stream.append(Data(), finish: true, onPCM: emit) }
                try cancellation.check()
                return SynthesisResult(pcm16: stream?.pcm16 ?? original, preparedText: prepared,
                    synthesisMilliseconds: (ProcessInfo.processInfo.systemUptime - start) * 1000,
                    firstPCMMilliseconds: first,
                    metrics: [(output["metrics"] as? [String: Double]) ?? [:]], diagnostics: [self.information],
                    watermark: stream?.watermark, memory: memory?.finish() ?? MemoryObservation())
            }
        }, onCancel: { cancellation.cancel(); self.native.cancel() })
    }

    public func release() async {
        _ = try? await perform {
            self.native.releaseModel()
            self.processor = nil
            self.directory = nil
            self.preparedVariant = nil
            self.referenceDigest = nil
            self.referenceFileKey = nil
            self.hasRegisteredReference = false
        }
    }
}
