import Foundation
import SwiftUI
#if os(iOS) && canImport(IrodoriSpeechCpp)
import IrodoriSpeechCpp
#endif
#if os(iOS) && canImport(LlamaCpp)
import LlamaCpp
#endif

/// LLMプロバイダー種別
public enum LLMProviderType: String, CaseIterable, Identifiable, Sendable {
    case localLFM = "localLFM"
    case chatGPTSignIn = "chatGPTSignIn"
    case gemini = "gemini"
    case openAICompatible = "openAICompatible"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .localLFM: return "ローカルLLM (LFM2.5-1.2B-JP)"
        case .chatGPTSignIn: return "Sign in with ChatGPT"
        case .gemini: return "Gemini (APIキー)"
        case .openAICompatible: return "OpenAI 互換 API (APIキー)"
        }
    }

    public var shortTitle: String {
        switch self {
        case .localLFM: return "ローカルLFM"
        case .chatGPTSignIn: return "ChatGPT"
        case .gemini: return "Gemini"
        case .openAICompatible: return "API Key"
        }
    }

    public var icon: String {
        switch self {
        case .localLFM: return "cpu"
        case .chatGPTSignIn: return "person.crop.circle.badge.checkmark"
        case .gemini: return "sparkles"
        case .openAICompatible: return "key.fill"
        }
    }
}

@MainActor
public final class AppSettings: ObservableObject {
    public static let shared = AppSettings()
    
    // MARK: - LLM Provider Selection
    @AppStorage("llmProviderType") public var llmProviderTypeRaw: String = LLMProviderType.localLFM.rawValue
    
    public var llmProviderType: LLMProviderType {
        get { LLMProviderType(rawValue: llmProviderTypeRaw) ?? .localLFM }
        set { llmProviderTypeRaw = newValue.rawValue }
    }
    
    // MARK: - Local LLM (LFM2.5-1.2B-JP)
    @AppStorage("lfm2ModelVariant") public var lfm2ModelVariantRaw: String = "Q4_K_M"
    
    #if os(iOS) && canImport(LlamaCpp)
    public var lfm2ModelVariant: LFM2ModelVariant {
        get { LFM2ModelVariant(rawValue: lfm2ModelVariantRaw) ?? .q4_k_m }
        set { lfm2ModelVariantRaw = newValue.rawValue }
    }
    #endif
    
    // MARK: - Sign in with ChatGPT
    // An empty preference selects the first model in the signed-in account's catalog.
    @AppStorage("chatGPTModelName") public var chatGPTModelName: String = ""
    @AppStorage("chatGPTReasoningEffort") public var chatGPTReasoningEffortRaw: String = ""
    @AppStorage("hideChatGPTAccountInfo") public var hideChatGPTAccountInfo: Bool = false

    public var chatGPTReasoningEffort: ChatGPTReasoningEffort {
        get { ChatGPTReasoningEffort(rawValue: chatGPTReasoningEffortRaw) ?? .automatic }
        set { chatGPTReasoningEffortRaw = newValue.rawValue }
    }
    
    // MARK: - Gemini
    @AppStorage("geminiAPIKey") public var geminiAPIKey: String = ""
    @AppStorage("geminiModelName") public var geminiModelName: String = GeminiInference.defaultModel
    @AppStorage("geminiThinkingEffort") public var geminiThinkingEffortRaw: String = ""

    public var geminiThinkingEffort: GeminiThinkingEffort {
        get { GeminiThinkingEffort(rawValue: geminiThinkingEffortRaw) ?? .automatic }
        set { geminiThinkingEffortRaw = newValue.rawValue }
    }

    // MARK: - LLM Settings (OpenAI Compatible)
    @AppStorage("openAIEndpoint") public var openAIEndpoint: String = "https://api.openai.com/v1/chat/completions"
    @AppStorage("openAIKey") public var openAIKey: String = ""
    @AppStorage("modelName") public var modelName: String = "gpt-4o-mini"
    @AppStorage("systemPrompt") public var systemPrompt: String = "あなたは優しく親しみやすいAIキャラクターの「シード」です。1〜2文程度の簡潔で自然な日本語で話しかけてください。"
    @AppStorage("temperature") public var temperature: Double = 0.7
    
    // MARK: - Irodori TTS Settings
    /// 量子化モデル種別 (F16 / Q8_0 / Q6_K / Q4_K)
    @AppStorage("ttsModelVariant") public var ttsModelVariantRaw: String = "Q6_K"
    @AppStorage("ttsSynthesisMode") public var ttsSynthesisModeRaw: String = TTSSynthesisMode.perSentence.rawValue
    @AppStorage("ttsCaption") public var ttsCaption: String = "落ち着いた、やさしい話し方。"
    @AppStorage("useRandomSeed") public var useRandomSeed: Bool = false
    @AppStorage("speakerSeed") public var speakerSeed: Int = 12345
    @AppStorage("watermarkEnabled") public var watermarkEnabled: Bool = false

    public var ttsSynthesisMode: TTSSynthesisMode {
        get { TTSSynthesisMode(rawValue: ttsSynthesisModeRaw) ?? .perSentence }
        set { ttsSynthesisModeRaw = newValue.rawValue }
    }
    
    // MARK: - Irodori TTS Inference Config
    /// サンプリングステップ数 (1〜16, デフォルト: 4)
    @AppStorage("ttsSteps") public var ttsSteps: Int = 4
    /// モデル生成速度 (0.5〜2.0, デフォルト: 1.0)
    @AppStorage("ttsSpeed") public var ttsSpeed: Double = 1.0
    /// 発話長スケール (0.5〜1.5, デフォルト: 1.0)
    @AppStorage("ttsDurationScale") public var ttsDurationScale: Double = 1.0
    /// Swayサンプリング係数 (-1.0〜1.0, デフォルト: 0.0)
    @AppStorage("ttsSwayCoeff") public var ttsSwayCoeff: Double = 0.0
    /// ガイダンススケール手動設定
    @AppStorage("ttsUseCustomGuidance") public var ttsUseCustomGuidance: Bool = false
    @AppStorage("ttsCfgScaleText") public var ttsCfgScaleText: Double = 2.0
    @AppStorage("ttsCfgScaleInstructions") public var ttsCfgScaleInstructions: Double = 2.0
    @AppStorage("ttsCfgScaleSpeaker") public var ttsCfgScaleSpeaker: Double = 1.5
    
    // MARK: - Voice Reference (音声クローン/話者適応)
    @AppStorage("referenceAudioFileName") public var referenceAudioFileName: String = ""
    @AppStorage("voiceConsent") public var voiceConsent: Bool = false
    
    // MARK: - Voice Conversation (SpeechAnalyzer & SileroVAD)
    @AppStorage("isHandsFreeMode") public var isHandsFreeMode: Bool = false
    
    // MARK: - Audio Playback & Lip Sync
    @AppStorage("speechRate") public var speechRate: Double = 1.0 // 0.8 - 1.5
    @AppStorage("speechVolume") public var speechVolume: Double = 1.0 // 0.0 - 1.0
    @AppStorage("lipSyncBoost") public var lipSyncBoost: Double = 6.0 // 1.0 - 15.0
    
    // MARK: - VRM Settings
    @AppStorage("customVrmFileName") public var customVrmFileName: String = ""
    
    private init() {}
    
    public var effectiveEndpointURL: URL? {
        var trimmed = openAIEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if !trimmed.hasPrefix("http://") && !trimmed.hasPrefix("https://") {
            trimmed = "https://" + trimmed
        }
        return URL(string: trimmed)
    }
    
    public var referenceAudioURL: URL? {
        guard !referenceAudioFileName.isEmpty else { return nil }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let url = appSupport.appendingPathComponent("References", isDirectory: true).appendingPathComponent(referenceAudioFileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    
    public func resetTTSConfigToDefaults() {
        ttsSteps = 4
        ttsSpeed = 1.0
        ttsDurationScale = 1.0
        ttsSwayCoeff = 0.0
        ttsUseCustomGuidance = false
        ttsCfgScaleText = 2.0
        ttsCfgScaleInstructions = 2.0
        ttsCfgScaleSpeaker = 1.5
    }
    
    #if os(iOS) && canImport(IrodoriSpeechCpp)
    public var ttsModelVariant: SpeechCppModelVariant {
        get { SpeechCppModelVariant(rawValue: ttsModelVariantRaw) ?? .q6_k }
        set { ttsModelVariantRaw = newValue.rawValue }
    }

    public var currentSynthesisOptions: SpeechCppEngine.SynthesisOptions {
        SpeechCppEngine.SynthesisOptions(
            steps: ttsSteps,
            speed: Float(ttsSpeed),
            durationScale: Float(ttsDurationScale),
            swayCoeff: ttsSwayCoeff != 0 ? Float(ttsSwayCoeff) : nil,
            cfgScaleText: ttsUseCustomGuidance ? Float(ttsCfgScaleText) : nil,
            cfgScaleInstructions: ttsUseCustomGuidance ? Float(ttsCfgScaleInstructions) : nil,
            cfgScaleSpeaker: ttsUseCustomGuidance ? Float(ttsCfgScaleSpeaker) : nil
        )
    }
    #endif
}
