import Foundation
import IrodoriTTS

/// Liquid AI の日本語特化軽量モデル LFM2.5-1.2B-JP の GGUF 量子化バリエーション
public enum LFM2ModelVariant: String, CaseIterable, Codable, Sendable, Identifiable {
    case q4_k_m = "Q4_K_M"
    case q4_0 = "Q4_0"
    case q6_k = "Q6_K"
    case q8_0 = "Q8_0"

    public var id: String { rawValue }

    public var shortLabel: String { rawValue }

    public var displayName: String {
        switch self {
        case .q4_k_m: return "Q4_K_M (標準・iPhone推奨)"
        case .q4_0: return "Q4_0 (最小容量・最軽量)"
        case .q6_k: return "Q6_K (高精度・バランス)"
        case .q8_0: return "Q8_0 (最高精度・高品質)"
        }
    }

    public var badgeText: String? {
        switch self {
        case .q4_k_m: return "iPhone推奨"
        case .q4_0: return "最軽量"
        case .q6_k: return "高精度"
        case .q8_0: return "最高品質"
        }
    }

    public var approximateSizeText: String {
        switch self {
        case .q4_k_m: return "731 MB"
        case .q4_0: return "696 MB"
        case .q6_k: return "963 MB"
        case .q8_0: return "1.25 GB"
        }
    }

    public var peakMemoryText: String {
        switch self {
        case .q4_k_m: return "約 0.9 GB"
        case .q4_0: return "約 0.85 GB"
        case .q6_k: return "約 1.15 GB"
        case .q8_0: return "約 1.45 GB"
        }
    }

    public var fileName: String {
        switch self {
        case .q4_k_m: return "LFM2.5-1.2B-JP-Q4_K_M.gguf"
        case .q4_0: return "LFM2.5-1.2B-JP-Q4_0.gguf"
        case .q6_k: return "LFM2.5-1.2B-JP-Q6_K.gguf"
        case .q8_0: return "LFM2.5-1.2B-JP-Q8_0.gguf"
        }
    }

    public var bytes: Int64 {
        switch self {
        case .q4_k_m: return 730_895_296
        case .q4_0: return 695_751_616
        case .q6_k: return 962_843_584
        case .q8_0: return 1_246_254_016
        }
    }

    public var sha256: String {
        switch self {
        case .q4_k_m: return "608beed14e975a4edd8932c42ac3e64cf1c97da4ee2c5f2c7b6bfbcdb1a90680"
        case .q4_0: return "0ea6afb49790861d3cee7e44dabc6cc0d28d2148a95283ab0fa64c375938e43c"
        case .q6_k: return "c4d871b37c432328f017e799cc172dbb6a44cb85b86b735b41db03b47a9e424a"
        case .q8_0: return "60585553df37d8fa396368aef63ffeb236b2fe7c6b430652307a006e0f451e2c"
        }
    }

    public static let revision = "170ae1cecf0e74b0b25bd704047160fba9f613c6"

    public var modelURL: URL {
        URL(string: "https://huggingface.co/LiquidAI/LFM2.5-1.2B-JP-GGUF/resolve/\(Self.revision)/\(fileName)")!
    }
}

public enum LFM2ModelBundle {
    public static func isInstalled(at root: URL, variant: LFM2ModelVariant = .q4_k_m) -> Bool {
        (try? validate(at: root, variant: variant)) != nil
    }

    public static func installedVariants(at root: URL) -> Set<LFM2ModelVariant> {
        var result = Set<LFM2ModelVariant>()
        let fm = FileManager.default
        for variant in LFM2ModelVariant.allCases {
            guard let fileURL = try? ModelBundle.safeURL(variant.fileName, under: root),
                  let size = (try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value,
                  size == variant.bytes else {
                continue
            }
            result.insert(variant)
        }
        return result
    }

    public static func validate(at root: URL, variant: LFM2ModelVariant = .q4_k_m, verifyHashes: Bool = false) throws {
        let fm = FileManager.default
        let fileURL = try ModelBundle.safeURL(variant.fileName, under: root)
        let size = (try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value
        guard size == variant.bytes else {
            throw IrodoriError.invalid("LFM2.5-1.2B-JP モデルが見つからないかサイズが不一致です: \(variant.fileName)")
        }
        if verifyHashes, try ModelBundle.checksum(fileURL) != variant.sha256 {
            throw IrodoriError.invalid("LFM2.5-1.2B-JP モデルのハッシュが一致しません: \(variant.fileName)")
        }
    }

    public static func delete(variant: LFM2ModelVariant, at root: URL) throws {
        let fm = FileManager.default
        let fileURL = try ModelBundle.safeURL(variant.fileName, under: root)
        if fm.fileExists(atPath: fileURL.path) {
            try fm.removeItem(at: fileURL)
        }
        if installedVariants(at: root).isEmpty && fm.fileExists(atPath: root.path) {
            try? fm.removeItem(at: root)
        }
    }

    public static func download(
        to destination: URL,
        variant: LFM2ModelVariant = .q4_k_m,
        progress: @escaping @Sendable (Int64, Int64, String) -> Void = { _, _, _ in }
    ) async throws {
        let files = FileManager.default
        if isInstalled(at: destination, variant: variant) {
            try validate(at: destination, variant: variant, verifyHashes: true)
            progress(variant.bytes, variant.bytes, "Complete")
            return
        }

        try files.createDirectory(at: destination, withIntermediateDirectories: true)
        let target = try ModelBundle.safeURL(variant.fileName, under: destination)

        try await ModelFileTransfer.download(
            from: variant.modelURL,
            bytes: variant.bytes,
            sha256: variant.sha256,
            to: target
        ) { received in
            progress(min(received, variant.bytes), variant.bytes, variant.fileName)
        }

        try validate(at: destination, variant: variant, verifyHashes: true)
    }
}
