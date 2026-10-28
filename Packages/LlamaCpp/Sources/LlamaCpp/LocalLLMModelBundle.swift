import Foundation
import IrodoriTTS

/// Liquid AI の多言語（日本語対応）軽量モデル LFM3-1.7B の GGUF 量子化バリエーション
public enum LocalLLMModelVariant: String, CaseIterable, Codable, Sendable, Identifiable {
    case q4_k_m = "Q4_K_M"
    case qad_q4_0 = "QAD-Q4_0"
    case q6_k = "Q6_K"
    case q8_0 = "Q8_0"

    public static let modelName = "LFM3-1.7B"

    public var id: String { rawValue }

    public var shortLabel: String { rawValue }

    public var displayName: String {
        switch self {
        case .q4_k_m: return "Q4_K_M (標準・iPhone推奨)"
        case .qad_q4_0: return "QAD Q4_0 (最小容量・量子化補正済み)"
        case .q6_k: return "Q6_K (高精度・バランス)"
        case .q8_0: return "Q8_0 (最高精度・高品質)"
        }
    }

    public var badgeText: String? {
        switch self {
        case .q4_k_m: return "iPhone推奨"
        case .qad_q4_0: return "最軽量"
        case .q6_k: return "高精度"
        case .q8_0: return "最高品質"
        }
    }

    public var approximateSizeText: String {
        switch self {
        case .q4_k_m: return "1.10 GB"
        case .qad_q4_0: return "1.05 GB"
        case .q6_k: return "1.43 GB"
        case .q8_0: return "1.85 GB"
        }
    }

    public var peakMemoryText: String {
        switch self {
        case .q4_k_m: return "約 1.3 GB"
        case .qad_q4_0: return "約 1.25 GB"
        case .q6_k: return "約 1.65 GB"
        case .q8_0: return "約 2.05 GB"
        }
    }

    public var fileName: String {
        switch self {
        case .q4_k_m: return "LFM3-1.7B-Q4_K_M.gguf"
        case .qad_q4_0: return "LFM3-1.7B-QAD-Q4_0.gguf"
        case .q6_k: return "LFM3-1.7B-Q6_K.gguf"
        case .q8_0: return "LFM3-1.7B-Q8_0.gguf"
        }
    }

    public var bytes: Int64 {
        switch self {
        case .q4_k_m: return 1_099_627_808
        case .qad_q4_0: return 1_049_615_680
        case .q6_k: return 1_427_638_304
        case .q8_0: return 1_846_238_496
        }
    }

    public var sha256: String {
        switch self {
        case .q4_k_m: return "3793e1e6e2266919d6e015287221b41100175a98eddaba92e111aed3b05c93c4"
        case .qad_q4_0: return "43a7d09a0e9cba91b63eb7052488b9564569bddfd65754d2e426465e572a7452"
        case .q6_k: return "54e1bd947c77167823d45bf495f1c3e2d226ca7fb242f83cfa141ee3a6ab55c6"
        case .q8_0: return "8f6b24182258205e9e01e21f1f24a1f208c1e8115578825d202ce39976af20b6"
        }
    }

    public static let revision = "b3f2ae5d73cd3c91bf40e8ba752c648aa05dffdf"

    public var modelURL: URL {
        URL(string: "https://huggingface.co/LiquidAI/LFM3-1.7B-GGUF/resolve/\(Self.revision)/\(fileName)")!
    }
}

public enum LocalLLMModelBundle {
    public static func isInstalled(at root: URL, variant: LocalLLMModelVariant = .q4_k_m) -> Bool {
        (try? validate(at: root, variant: variant)) != nil
    }

    public static func installedVariants(at root: URL) -> Set<LocalLLMModelVariant> {
        var result = Set<LocalLLMModelVariant>()
        let fm = FileManager.default
        for variant in LocalLLMModelVariant.allCases {
            guard let fileURL = try? ModelBundle.safeURL(variant.fileName, under: root),
                  let size = (try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value,
                  size == variant.bytes else {
                continue
            }
            result.insert(variant)
        }
        return result
    }

    public static func validate(at root: URL, variant: LocalLLMModelVariant = .q4_k_m, verifyHashes: Bool = false) throws {
        let fm = FileManager.default
        let fileURL = try ModelBundle.safeURL(variant.fileName, under: root)
        let size = (try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value
        guard size == variant.bytes else {
            throw IrodoriError.invalid("\(LocalLLMModelVariant.modelName) モデルが見つからないかサイズが不一致です: \(variant.fileName)")
        }
        if verifyHashes, try ModelBundle.checksum(fileURL) != variant.sha256 {
            throw IrodoriError.invalid("\(LocalLLMModelVariant.modelName) モデルのハッシュが一致しません: \(variant.fileName)")
        }
    }

    public static func delete(variant: LocalLLMModelVariant, at root: URL) throws {
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
        variant: LocalLLMModelVariant = .q4_k_m,
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
