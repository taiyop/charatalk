import Foundation
import SwiftUI
import Combine
#if canImport(UIKit)
import UIKit
#endif
#if os(iOS) && canImport(LlamaCpp)
import LlamaCpp
#endif

public enum LocalLLMError: LocalizedError {
    case modelNotInstalled
    case modelDownloadFailed(String)
    case generationFailed(String)
    case simulatorNotSupported

    public var errorDescription: String? {
        switch self {
        case .modelNotInstalled:
            return "ローカルLLM (LFM3-1.7B) のモデルがダウンロードされていません。設定画面からダウンロードしてください。"
        case .modelDownloadFailed(let msg):
            return "LFM3 モデルの取得に失敗しました: \(msg)"
        case .generationFailed(let msg):
            return "ローカルLLMでの生成に失敗しました: \(msg)"
        case .simulatorNotSupported:
            return "LFM3-1.7B の Metal 推論は実機 iPhone でのみ動作します。"
        }
    }
}

@MainActor
public final class LocalLLMManager: ObservableObject {
    public static let shared = LocalLLMManager()
    private static let variantDefaultsKey = "localLLMModelVariant"

    @Published public private(set) var isModelInstalled: Bool = false
    @Published public private(set) var isDownloading: Bool = false
    @Published public private(set) var downloadProgress: Double = 0.0
    @Published public private(set) var downloadStatusText: String = ""
    @Published public private(set) var isGenerating: Bool = false

    #if os(iOS) && canImport(LlamaCpp)
    @Published public private(set) var selectedVariant: LocalLLMModelVariant = .q4_k_m
    @Published public private(set) var installedVariants: Set<LocalLLMModelVariant> = []
    private let engine = LlamaCppEngine()
    #endif

    private let modelsDirectory: URL
    private var idleUnloadTask: Task<Void, Never>?
    private let idleUnloadDelayNanoseconds: UInt64 = 120 * 1_000_000_000 // 120秒未使用でRAMから自動解放

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.modelsDirectory = appSupport.appendingPathComponent("LocalLLMModels", isDirectory: true)
        try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)

        #if os(iOS) && canImport(LlamaCpp)
        if let savedVariantRaw = UserDefaults.standard.string(forKey: Self.variantDefaultsKey),
           let variant = LocalLLMModelVariant(rawValue: savedVariantRaw) {
            self.selectedVariant = variant
        } else {
            self.selectedVariant = .q4_k_m
        }
        #endif

        checkModelInstallation()
        setupMemoryObservers()
    }

    private func setupMemoryObservers() {
        #if canImport(UIKit) && os(iOS) && canImport(LlamaCpp)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, !self.isGenerating else { return }
                await self.releaseLoadedModel()
            }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, !self.isGenerating else { return }
                await self.releaseLoadedModel()
            }
        }
        #endif
    }

    public func checkModelInstallation() {
        #if os(iOS) && canImport(LlamaCpp)
        installedVariants = LocalLLMModelBundle.installedVariants(at: modelsDirectory)
        isModelInstalled = installedVariants.contains(selectedVariant)
        #else
        isModelInstalled = false
        #endif
    }

    #if os(iOS) && canImport(LlamaCpp)
    public func isVariantInstalled(_ variant: LocalLLMModelVariant) -> Bool {
        installedVariants.contains(variant)
    }

    public func selectVariant(_ variant: LocalLLMModelVariant) {
        guard variant != selectedVariant else { return }
        selectedVariant = variant
        UserDefaults.standard.set(variant.rawValue, forKey: Self.variantDefaultsKey)
        checkModelInstallation()
        if !isGenerating {
            Task {
                await releaseLoadedModel()
            }
        }
    }
    #endif

    public func releaseLoadedModel() async {
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
        #if os(iOS) && canImport(LlamaCpp)
        await engine.release()
        #endif
    }

    private func scheduleIdleUnload() {
        idleUnloadTask?.cancel()
        let delay = idleUnloadDelayNanoseconds
        idleUnloadTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, let self = self, !self.isGenerating else { return }
            await self.releaseLoadedModel()
        }
    }

    public func deleteModel(variant: LocalLLMModelVariant? = nil) {
        #if os(iOS) && canImport(LlamaCpp)
        let targetVariant = variant ?? selectedVariant
        Task {
            await releaseLoadedModel()
            try? LocalLLMModelBundle.delete(variant: targetVariant, at: modelsDirectory)
            checkModelInstallation()
        }
        #endif
    }

    public func downloadModel(variant: LocalLLMModelVariant? = nil) async throws {
        #if targetEnvironment(simulator)
        throw LocalLLMError.simulatorNotSupported
        #elseif os(iOS) && canImport(LlamaCpp)
        guard !isDownloading else { return }
        let targetVariant = variant ?? selectedVariant
        if targetVariant != selectedVariant {
            selectedVariant = targetVariant
            UserDefaults.standard.set(targetVariant.rawValue, forKey: Self.variantDefaultsKey)
        }

        isDownloading = true
        downloadProgress = 0.0
        downloadStatusText = "LFM3 (\(targetVariant.shortLabel)) を取得中…"
        defer {
            isDownloading = false
            checkModelInstallation()
        }

        do {
            try await LocalLLMModelBundle.download(to: modelsDirectory, variant: targetVariant) { [weak self] completed, total, _ in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    let fraction = Double(completed) / Double(max(total, 1))
                    self.downloadProgress = fraction
                    let completedMB = Double(completed) / (1024 * 1024)
                    let totalMB = Double(total) / (1024 * 1024)
                    self.downloadStatusText = String(
                        format: "LFM3 %@ (%.0f%%) - %.1f / %.1f MB",
                        targetVariant.shortLabel,
                        fraction * 100,
                        completedMB,
                        totalMB
                    )
                }
            }
            downloadStatusText = "完了しました"
            checkModelInstallation()
        } catch {
            downloadStatusText = "エラーが発生しました"
            throw LocalLLMError.modelDownloadFailed(error.localizedDescription)
        }
        #else
        throw LocalLLMError.simulatorNotSupported
        #endif
    }

    #if os(iOS) && canImport(LlamaCpp)
    /// 初回の会話を待たせないよう、モデルをRAMに載せて1トークンだけ生成しておく（Metal の初期化も済ませる）。
    /// 会話が始まるまでは自動解放しない。
    public func prewarm(systemPrompt: String) async throws {
        guard isModelInstalled, !isGenerating else { return }
        idleUnloadTask?.cancel()
        let variant = selectedVariant
        let modelFileURL = modelsDirectory.appendingPathComponent(variant.fileName)
        try await engine.prepare(modelFile: modelFileURL, variant: variant, contextLength: 4096)
        _ = try await engine.generate(
            messages: [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": "こんにちは"]
            ],
            temperature: 0.1,
            maxTokens: 1
        )
    }

    public func generate(
        systemPrompt: String,
        messages: [ChatMessage],
        temperature: Double = 0.1,
        maxTokens: Int = 256,
        onToken: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        guard isModelInstalled else {
            throw LocalLLMError.modelNotInstalled
        }

        idleUnloadTask?.cancel()
        isGenerating = true
        defer {
            isGenerating = false
            scheduleIdleUnload()
        }

        let variant = selectedVariant
        let modelFileURL = modelsDirectory.appendingPathComponent(variant.fileName)

        try await engine.prepare(modelFile: modelFileURL, variant: variant, contextLength: 4096)

        var chatMessages: [[String: String]] = []
        if !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            chatMessages.append([
                "role": "system",
                "content": systemPrompt
            ])
        }

        for msg in messages {
            chatMessages.append([
                "role": msg.role.rawValue,
                "content": msg.content
            ])
        }

        return try await engine.generate(
            messages: chatMessages,
            temperature: Float(temperature),
            maxTokens: maxTokens,
            onToken: onToken
        )
    }
    #endif
}
