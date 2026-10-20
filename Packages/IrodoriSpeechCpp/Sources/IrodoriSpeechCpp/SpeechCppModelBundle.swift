// Modified for CharaTalk: model variants, download and validation integration.
// Derived from Corvelis/irodori-tts-iphone; see root NOTICE and THIRD_PARTY_NOTICES.md.
import Foundation
import IrodoriTTS

/// Irodori-TTS v4.1 Small MF の GGUF 量子化バリエーション (`speech.cpp` Metal 推論用)
public enum SpeechCppModelVariant: String, CaseIterable, Codable, Sendable, Identifiable {
    case f16 = "F16"
    case q8_0 = "Q8_0"
    case q6_k = "Q6_K"
    case q4_k = "Q4_K"

    public var id: String { rawValue }

    public var shortLabel: String { rawValue }

    public var displayName: String {
        switch self {
        case .f16: return "F16 (最高精度・品質重視)"
        case .q8_0: return "Q8_0 (精度・容量バランス)"
        case .q6_k: return "Q6_K (省メモリ・iPhone推奨)"
        case .q4_k: return "Q4_K (最小容量・最軽量)"
        }
    }

    public var badgeText: String? {
        switch self {
        case .f16: return "最高品質"
        case .q8_0: return "バランス"
        case .q6_k: return "iPhone推奨"
        case .q4_k: return "最小容量"
        }
    }

    public var approximateSizeText: String {
        switch self {
        case .f16: return "1.92 GB"
        case .q8_0: return "1.21 GB"
        case .q6_k: return "1.04 GB"
        case .q4_k: return "0.86 GB"
        }
    }

    public var sizeReductionText: String? {
        switch self {
        case .f16: return nil
        case .q8_0: return "-37%"
        case .q6_k: return "-46%"
        case .q4_k: return "-55%"
        }
    }

    public var peakMemoryText: String {
        switch self {
        case .f16: return "2.04 GB"
        case .q8_0: return "1.33 GB"
        case .q6_k: return "1.17 GB"
        case .q4_k: return "0.99 GB"
        }
    }

    public var benchmarkSummary: String {
        switch self {
        case .f16: return "容量 1.92GB / 最大RAM 2.04GB / RTFx 9.6x / CER 6.0%"
        case .q8_0: return "容量 1.21GB (-37%) / 最大RAM 1.33GB / RTFx 9.7x / CER 9.0%"
        case .q6_k: return "容量 1.04GB (-46%) / 最大RAM 1.17GB / RTFx 9.5x / CER 8.1%"
        case .q4_k: return "容量 0.86GB (-55%) / 最大RAM 0.99GB / RTFx 9.8x / CER 7.8%"
        }
    }

    public var fileName: String {
        switch self {
        case .f16: return "Irodori-TTS-866M-MF-v4.1-F16.gguf"
        case .q8_0: return "Irodori-TTS-866M-MF-v4.1-Q8_0.gguf"
        case .q6_k: return "Irodori-TTS-866M-MF-v4.1-Q6_K.gguf"
        case .q4_k: return "Irodori-TTS-866M-MF-v4.1-Q4_K.gguf"
        }
    }

    public var bytes: Int64 {
        switch self {
        case .f16: return 1_920_321_792
        case .q8_0: return 1_207_133_984
        case .q6_k: return 1_040_893_024
        case .q4_k: return 863_926_048
        }
    }

    public var sha256: String {
        switch self {
        case .f16: return "e237dc3eefe469b8bba87872beacf12fb7fe00dbdf85767edca8ec04ab910d13"
        case .q8_0: return "2d161b0bbcd74f906f6b07e03d031075f8ae916db1b8bd4daf16cb37b451086a"
        case .q6_k: return "2feadbb66d5c053cf7fddcd02514b2339c79af4afa38aa00357d9aa6dff0ff96"
        case .q4_k: return "1913bf74000a3300c703eb91c985a4e5c4d7a2bbeb0cc7fe07d1583c4fea9729"
        }
    }

    public static let revision = "9db7da1bec3d1069ef8e29732e0497be60c7b047"

    public var modelURL: URL {
        URL(string: "https://huggingface.co/sakasegawa/Irodori-TTS-v4.1-Small-MF-GGUF/resolve/\(Self.revision)/\(fileName)")!
    }
}

public enum SpeechCppModelBundle {
    public static let fileName = SpeechCppModelVariant.f16.fileName
    public static let bytes: Int64 = SpeechCppModelVariant.f16.bytes
    public static let sha256 = SpeechCppModelVariant.f16.sha256
    public static let modelURL = SpeechCppModelVariant.f16.modelURL
    public static let watermarkManifest = ModelVariant.standard.manifestURL

    private struct File: Codable { let path: String; let bytes: Int64; let sha256: String }
    private struct Manifest: Codable { let format: String; let files: [File] }
    private static let watermarkPaths: Set<String> = Set(["audioseal.json"] + ["audioseal_generator", "audioseal_detector"].flatMap { name in
        ["Manifest.json", "Data/com.apple.CoreML/model.mlmodel", "Data/com.apple.CoreML/weights/weight.bin"].map { "\(name).mlpackage/\($0)" }
    })

    public static func isInstalled(at root: URL, variant: SpeechCppModelVariant = .f16) -> Bool {
        (try? validate(at: root, variant: variant)) != nil
    }

    public static func installedVariants(at root: URL) -> Set<SpeechCppModelVariant> {
        guard isWatermarkInstalled(at: root) else { return [] }
        var result = Set<SpeechCppModelVariant>()
        let fm = FileManager.default
        for variant in SpeechCppModelVariant.allCases {
            guard let ggufURL = try? ModelBundle.safeURL(variant.fileName, under: root),
                  let size = (try? fm.attributesOfItem(atPath: ggufURL.path)[.size] as? NSNumber)?.int64Value,
                  size == variant.bytes else {
                continue
            }
            result.insert(variant)
        }
        return result
    }

    private static func isWatermarkInstalled(at root: URL) -> Bool {
        let fm = FileManager.default
        for path in watermarkPaths {
            guard let file = try? ModelBundle.safeURL(path, under: root),
                  let size = (try? fm.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value,
                  size > 0 else {
                return false
            }
        }
        return true
    }

    public static func validate(at root: URL, variant: SpeechCppModelVariant = .f16, verifyHashes: Bool = false) throws {
        let fm = FileManager.default
        let ggufFile = try ModelBundle.safeURL(variant.fileName, under: root)
        let ggufSize = (try? fm.attributesOfItem(atPath: ggufFile.path)[.size] as? NSNumber)?.int64Value
        guard ggufSize == variant.bytes else {
            throw IrodoriError.invalid("Missing or invalid speech.cpp model: \(variant.fileName)")
        }
        if verifyHashes, try ModelBundle.checksum(ggufFile) != variant.sha256 {
            throw IrodoriError.invalid("Model checksum mismatch: \(variant.fileName)")
        }

        // Verify AudioSeal watermark files
        let manifestURL = try ModelBundle.safeURL("speech-cpp-manifest.json", under: root)
        if let manifestData = try? Data(contentsOf: manifestURL),
           let manifest = try? JSONDecoder().decode(Manifest.self, from: manifestData) {
            let markerEntries = manifest.files.filter { watermarkPaths.contains($0.path) }
            guard Set(markerEntries.map(\.path)) == watermarkPaths else {
                throw IrodoriError.invalid("Invalid speech.cpp watermark manifest")
            }
            for entry in markerEntries {
                let file = try ModelBundle.safeURL(entry.path, under: root)
                let size = (try? fm.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value
                guard entry.bytes > 0, entry.sha256.count == 64, size == entry.bytes else {
                    throw IrodoriError.invalid("Missing or invalid AudioSeal model: \(entry.path)")
                }
                if verifyHashes, try ModelBundle.checksum(file) != entry.sha256 {
                    throw IrodoriError.invalid("AudioSeal checksum mismatch: \(entry.path)")
                }
            }
        } else {
            for path in watermarkPaths {
                let file = try ModelBundle.safeURL(path, under: root)
                let size = (try? fm.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
                guard size > 0 else {
                    throw IrodoriError.invalid("Missing AudioSeal model: \(path)")
                }
            }
        }
    }

    /// Deletes only the specified GGUF variant. If no GGUF variants remain afterwards, removes the directory.
    public static func delete(variant: SpeechCppModelVariant, at root: URL) throws {
        let fm = FileManager.default
        let ggufURL = try ModelBundle.safeURL(variant.fileName, under: root)
        if fm.fileExists(atPath: ggufURL.path) {
            try fm.removeItem(at: ggufURL)
        }
        if installedVariants(at: root).isEmpty && fm.fileExists(atPath: root.path) {
            try? fm.removeItem(at: root)
        }
    }

    /// Only the GGUF and AudioSeal components are fetched; the Core ML TTS weights are not needed.
    /// Existing installed variants and AudioSeal files in `destination` are preserved.
    public static func download(to destination: URL,
                                variant: SpeechCppModelVariant = .f16,
                                importingGGUF: URL? = nil,
                                progress: @escaping @Sendable (Int64, Int64, String) -> Void = { _, _, _ in }) async throws {
        let files = FileManager.default
        if isInstalled(at: destination, variant: variant) {
            try validate(at: destination, variant: variant, verifyHashes: true)
            progress(variant.bytes, variant.bytes, "Complete")
            return
        }

        let (data, response) = try await URLSession.shared.data(from: watermarkManifest)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw IrodoriError.invalid("AudioSeal manifest download failed") }
        let sourceManifest = try ModelBundle.manifest(from: data)
        let markers = sourceManifest.files.filter { watermarkPaths.contains($0.path) }
        guard Set(markers.map(\.path)) == watermarkPaths else { throw IrodoriError.invalid("Incomplete AudioSeal manifest") }

        let ggufEntry = File(path: variant.fileName, bytes: variant.bytes, sha256: variant.sha256)
        let entries = [ggufEntry] + markers.map { File(path: $0.path, bytes: $0.bytes, sha256: $0.sha256) }

        try files.createDirectory(at: destination, withIntermediateDirectories: true)

        let total = entries.reduce(Int64(0)) { $0 + $1.bytes }
        var completed: Int64 = 0
        for entry in entries {
            try Task.checkCancellation()
            let target = try ModelBundle.safeURL(entry.path, under: destination)
            if entry.path == variant.fileName, let importingGGUF {
                guard (try files.attributesOfItem(atPath: importingGGUF.path)[.size] as? NSNumber)?.int64Value == variant.bytes,
                      try ModelBundle.checksum(importingGGUF) == variant.sha256 else {
                    throw IrodoriError.invalid("Irodori v4.1 Small MF \(variant.rawValue) GGUF checksum mismatch")
                }
                if files.fileExists(atPath: target.path) { try files.removeItem(at: target) }
                try files.copyItem(at: importingGGUF, to: target)
            } else {
                let base = completed
                let url = entry.path == variant.fileName ? variant.modelURL : watermarkManifest.deletingLastPathComponent().appendingPathComponent(entry.path)
                try await ModelFileTransfer.download(from: url, bytes: entry.bytes, sha256: entry.sha256, to: target) {
                    progress(base + min($0, entry.bytes), total, entry.path)
                }
            }
            completed += entry.bytes
            progress(completed, total, entry.path)
        }

        try JSONEncoder().encode(Manifest(format: "irodori-speech-cpp-v1", files: entries))
            .write(to: destination.appendingPathComponent("speech-cpp-manifest.json"), options: .atomic)
        try validate(at: destination, variant: variant, verifyHashes: true)
        try Task.checkCancellation()
    }
}
