import Foundation
import AVFoundation
#if canImport(UIKit)
import UIKit
#endif
import IrodoriTTS
#if os(iOS) && canImport(IrodoriSpeechCpp)
import IrodoriSpeechCpp
#endif

public enum TTSError: LocalizedError {
    case modelNotInstalled
    case modelDownloadFailed(String)
    case synthesisFailed(String)
    case simulatorNotSupported
    
    public var errorDescription: String? {
        switch self {
        case .modelNotInstalled:
            return "音声合成モデルがダウンロードされていません。設定画面からモデルをダウンロードしてください。"
        case .modelDownloadFailed(let msg):
            return "音声合成モデルの取得に失敗しました: \(msg)"
        case .synthesisFailed(let msg):
            return "音声の生成に失敗しました: \(msg)"
        case .simulatorNotSupported:
            return "speech.cpp (Metal) による音声合成は実機iPhoneでのみ動作します。"
        }
    }
}

@MainActor
public final class SpeechTTSManager: ObservableObject {
    public static let shared = SpeechTTSManager()
    
    @Published public private(set) var isModelInstalled: Bool = false
    @Published public private(set) var isDownloading: Bool = false
    @Published public private(set) var downloadProgress: Double = 0.0
    @Published public private(set) var downloadStatusText: String = ""
    @Published public private(set) var isSynthesizing: Bool = false
    @Published public private(set) var referenceStatusText: String = ""
    
    #if os(iOS) && canImport(IrodoriSpeechCpp)
    @Published public private(set) var selectedVariant: SpeechCppModelVariant = .q6_k
    @Published public private(set) var installedVariants: Set<SpeechCppModelVariant> = []
    private let engine = SpeechCppEngine()
    private let residency = ExclusiveModelSession()
    #endif
    
    private let modelsDirectory: URL
    private var idleUnloadTask: Task<Void, Never>?
    private let idleUnloadDelayNanoseconds: UInt64 = 120 * 1_000_000_000 // 120秒間未使用でモデルをRAMから自動解放
    
    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        self.modelsDirectory = appSupport.appendingPathComponent("IrodoriModels", isDirectory: true)
        
        // 過去のセッションでtmpに残留したAudioSealのコンパイルキャッシュを掃除
        AudioWatermarkProcessor.cleanupStaleTemporaryModels()
        
        #if os(iOS) && canImport(IrodoriSpeechCpp)
        let installed = SpeechCppModelBundle.installedVariants(at: modelsDirectory)
        // 未完了の空ディレクトリが残っていたらクリーンアップ（有効なモデルが1つも無い場合のみ）
        if installed.isEmpty && FileManager.default.fileExists(atPath: modelsDirectory.path) {
            try? FileManager.default.removeItem(at: modelsDirectory)
        }
        // 初回アップデート時に既存のF16モデル等が取得済みであれば、そのまま引き継ぐ
        if UserDefaults.standard.object(forKey: "ttsModelVariant") == nil,
           let existing = SpeechCppModelVariant.allCases.first(where: { installed.contains($0) }) {
            AppSettings.shared.ttsModelVariant = existing
        }
        self.selectedVariant = AppSettings.shared.ttsModelVariant
        #endif
        
        checkModelInstallation()
        setupMemoryObservers()
    }
    
    private func setupMemoryObservers() {
        #if canImport(UIKit) && os(iOS) && canImport(IrodoriSpeechCpp)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, !self.isSynthesizing else { return }
                await self.releaseLoadedModel()
            }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, !self.isSynthesizing else { return }
                await self.releaseLoadedModel()
            }
        }
        #endif
    }
    
    /// 常駐しているTTSモデルをRAMから解放する（ディスク上のモデルファイルは保持）
    public func releaseLoadedModel() async {
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
        #if os(iOS) && canImport(IrodoriSpeechCpp)
        await residency.release()
        #endif
    }
    
    private func scheduleIdleUnload() {
        idleUnloadTask?.cancel()
        let delay = idleUnloadDelayNanoseconds
        idleUnloadTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, let self = self, !self.isSynthesizing else { return }
            await self.releaseLoadedModel()
        }
    }
    
    public func checkModelInstallation() {
        #if os(iOS) && canImport(IrodoriSpeechCpp)
        selectedVariant = AppSettings.shared.ttsModelVariant
        installedVariants = SpeechCppModelBundle.installedVariants(at: modelsDirectory)
        isModelInstalled = installedVariants.contains(selectedVariant)
        #else
        isModelInstalled = false
        #endif
    }
    
    #if os(iOS) && canImport(IrodoriSpeechCpp)
    public func isVariantInstalled(_ variant: SpeechCppModelVariant) -> Bool {
        installedVariants.contains(variant)
    }
    
    public func selectVariant(_ variant: SpeechCppModelVariant) {
        guard variant != selectedVariant || AppSettings.shared.ttsModelVariant != variant else { return }
        AppSettings.shared.ttsModelVariant = variant
        selectedVariant = variant
        checkModelInstallation()
        // 別の量子化モデルに切り替えた場合、現在RAMに常駐しているモデルを解放
        if !isSynthesizing {
            Task {
                await releaseLoadedModel()
            }
        }
    }
    #endif
    
    public func deleteModel(variant: SpeechCppModelVariant? = nil) {
        #if os(iOS) && canImport(IrodoriSpeechCpp)
        let targetVariant = variant ?? selectedVariant
        Task {
            await residency.release()
            try? SpeechCppModelBundle.delete(variant: targetVariant, at: modelsDirectory)
            checkModelInstallation()
        }
        #endif
    }
    
    public func updateReferenceAudio() async throws {
        #if os(iOS) && canImport(IrodoriSpeechCpp)
        guard isModelInstalled else { return }
        let refURL = AppSettings.shared.referenceAudioURL
        let variant = selectedVariant
        
        let reg = try await residency.withModel(
            identifier: "speech.cpp:\(modelsDirectory.path):\(variant.rawValue)",
            load: { [weak self] in
                guard let self = self else { return }
                try await self.engine.prepare(modelDirectory: self.modelsDirectory, variant: variant)
            },
            release: { [weak self] in
                await self?.engine.release()
            },
            operation: { [weak self] in
                guard let self = self else { throw TTSError.synthesisFailed("Engine was deallocated") }
                return try await self.engine.registerReference(refURL)
            }
        )
        
        if refURL != nil {
            self.referenceStatusText = String(format: "登録完了 (%.0f ms%@)", reg.milliseconds, reg.cacheHit ? "・キャッシュ" : "")
        } else {
            self.referenceStatusText = "参照音声なし (デフォルト話者)"
        }
        #endif
    }
    
    public func downloadModel(variant: SpeechCppModelVariant? = nil) async throws {
        #if targetEnvironment(simulator)
        throw TTSError.simulatorNotSupported
        #elseif os(iOS) && canImport(IrodoriSpeechCpp)
        guard !isDownloading else { return }
        let targetVariant = variant ?? selectedVariant
        if targetVariant != selectedVariant {
            AppSettings.shared.ttsModelVariant = targetVariant
            selectedVariant = targetVariant
        }
        
        isDownloading = true
        downloadProgress = 0.0
        downloadStatusText = "\(targetVariant.shortLabel) モデルのダウンロードを開始しています…"
        defer {
            isDownloading = false
            checkModelInstallation()
        }
        
        do {
            try await SpeechCppModelBundle.download(to: modelsDirectory, variant: targetVariant) { [weak self] completed, total, currentFile in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    let fraction = Double(completed) / Double(max(total, 1))
                    self.downloadProgress = fraction
                    let completedMB = Double(completed) / (1024 * 1024)
                    let totalMB = Double(total) / (1024 * 1024)
                    self.downloadStatusText = String(format: "%@ 取得中 (%.0f%%) - %.1f / %.1f MB", targetVariant.shortLabel, fraction * 100, completedMB, totalMB)
                }
            }
            downloadStatusText = "完了しました"
            checkModelInstallation()
            try? await updateReferenceAudio()
        } catch {
            downloadStatusText = "エラーが発生しました"
            throw TTSError.modelDownloadFailed(error.localizedDescription)
        }
        #else
        throw TTSError.simulatorNotSupported
        #endif
    }
    
    #if os(iOS) && canImport(IrodoriSpeechCpp)
    /// 初回の発話を待たせないよう、モデルの読み込み・参照音声の登録・短い試し合成（Metal の初期化）を済ませておく。
    /// 会話が始まるまでは自動解放しない。
    public func prewarm() async throws {
        #if !targetEnvironment(simulator)
        guard isModelInstalled, !isSynthesizing else { return }
        idleUnloadTask?.cancel()
        let refURL = AppSettings.shared.referenceAudioURL
        let caption = AppSettings.shared.ttsCaption
        let options = AppSettings.shared.currentSynthesisOptions
        let variant = selectedVariant
        try await residency.withModel(
            identifier: "speech.cpp:\(modelsDirectory.path):\(variant.rawValue)",
            load: { [weak self] in
                guard let self = self else { return }
                _ = try await ConversationPerformance.measureAsync("TTS model load") {
                    try await self.engine.prepare(modelDirectory: self.modelsDirectory, variant: variant)
                }
            },
            release: { [weak self] in
                await self?.engine.release()
            },
            operation: { [weak self] in
                guard let self = self else { throw TTSError.synthesisFailed("Engine was deallocated") }
                try await self.engine.registerReference(refURL)
                _ = try await ConversationPerformance.measureAsync("TTS prewarm synthesis") {
                    try await self.engine.synthesize(
                        "はい。",
                        caption: caption,
                        seed: 12345,
                        options: options,
                        watermark: nil,
                        trackMemory: false
                    )
                }
            }
        )
        #endif
    }

    public func synthesize(
        text: String,
        caption: String,
        seed: UInt32 = 12345,
        options: SpeechCppEngine.SynthesisOptions? = nil,
        watermark: Bool = false
    ) async throws -> Data {
        #if targetEnvironment(simulator)
        // シミュレータではダミーPCMまたはAVSpeechSynthesizer用のメッセージ
        throw TTSError.simulatorNotSupported
        #else
        guard isModelInstalled else {
            throw TTSError.modelNotInstalled
        }
        
        let requestInterval = ConversationPerformance.begin("TTS request")
        var requestOutcome = ConversationPerformance.Outcome.failed
        idleUnloadTask?.cancel()
        isSynthesizing = true
        if #available(iOS 18.0, *) {
            VRMCharacterController.shared.setSynthesisThrottling(true)
        }
        defer {
            isSynthesizing = false
            if #available(iOS 18.0, *) {
                VRMCharacterController.shared.setSynthesisThrottling(false)
            }
            scheduleIdleUnload()
            ConversationPerformance.end("TTS request", requestInterval, outcome: requestOutcome)
        }
        
        let refURL = AppSettings.shared.referenceAudioURL
        let resolvedOptions = options ?? AppSettings.shared.currentSynthesisOptions
        let variant = selectedVariant
        
        do {
            let pcm = try await residency.withModel(
                identifier: "speech.cpp:\(modelsDirectory.path):\(variant.rawValue)",
                load: { [weak self] in
                    guard let self = self else { return }
                    _ = try await ConversationPerformance.measureAsync("TTS model load") {
                        try await self.engine.prepare(modelDirectory: self.modelsDirectory, variant: variant)
                    }
                },
                release: { [weak self] in
                    await self?.engine.release()
                },
                operation: { [weak self] in
                    guard let self = self else { throw TTSError.synthesisFailed("Engine was deallocated") }
                    _ = try await ConversationPerformance.measureAsync("TTS reference preparation") {
                        try await self.engine.registerReference(refURL)
                    }
                    let result = try await ConversationPerformance.measureAsync("TTS native synthesis") {
                        try await self.engine.synthesize(
                            text,
                            caption: caption,
                            seed: seed,
                            options: resolvedOptions,
                            watermark: watermark ? WatermarkOptions() : nil,
                            trackMemory: false
                        )
                    }
                    // Prepare off the playback boundary, as before.
                    let pcm = ConversationPerformance.measure("PCM preparation") {
                        SpeechPCM.trimmingEdgeSilence(result.pcm16)
                    }
                    if let performance = ConversationPerformance.current {
                        let index = ConversationPerformance.chunkIndex
                        let audioSeconds = Double(pcm.count / 2) / 48_000
                        performance.duration("synthesized_audio", seconds: audioSeconds, chunk: index)
                        performance.duration("native_first_pcm", seconds: result.firstPCMMilliseconds / 1_000, chunk: index)
                        if audioSeconds > 0 {
                            performance.value("synthesis_rtf", value: result.synthesisMilliseconds / 1_000 / audioSeconds, chunk: index)
                        }
                        // Allowlisted numeric timings only, never native text/diagnostics.
                        for metrics in result.metrics {
                            if let milliseconds = metrics["textEncoderMs"] {
                                performance.duration("tts_text_encoder", seconds: milliseconds / 1_000, chunk: index)
                            }
                            if let milliseconds = metrics["ditSamplingMs"] {
                                performance.duration("tts_dit_sampling", seconds: milliseconds / 1_000, chunk: index)
                            }
                            if let milliseconds = metrics["decoderMs"] {
                                performance.duration("tts_decoder", seconds: milliseconds / 1_000, chunk: index)
                            }
                        }
                    }
                    return pcm
                }
            )
            requestOutcome = .completed
            return pcm
        } catch {
            requestOutcome = ConversationPerformance.outcome(for: error)
            throw error
        }
        #endif
    }
    #else
    public func synthesize(text: String, caption: String, seed: UInt32 = 12345, watermark: Bool = false) async throws -> Data {
        throw TTSError.simulatorNotSupported
    }
    #endif
}
