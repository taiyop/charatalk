import Foundation
import SwiftUI

/// キャラクターを選んだ直後に、ローカルLLMと Irodori TTS を事前に読み込んでおく。
/// 初回の会話でもモデル読み込み・Metal 初期化の待ち時間が発生しないようにする。
@MainActor
public final class ConversationWarmup: ObservableObject {
    public static let shared = ConversationWarmup()

    public enum Phase: Equatable {
        case idle
        case warming(String)
        case ready
        case failed(String)
    }

    @Published public private(set) var phase: Phase = .idle

    private var task: Task<Void, Never>?

    public var isWarming: Bool {
        if case .warming = phase { return true }
        return false
    }

    /// 何度呼んでもよい。読み込み済みのモデルはそのまま使われ、試し生成だけが走る。
    public func start() {
        task?.cancel()
        let settings = AppSettings.shared
        let warmsLLM = settings.llmProviderType == .localLFM && LocalLLMManager.shared.isModelInstalled
        let warmsTTS = SpeechTTSManager.shared.isModelInstalled
        guard warmsLLM || warmsTTS else {
            phase = .ready
            return
        }

        let label = [warmsLLM ? "LLM" : nil, warmsTTS ? "音声合成" : nil].compactMap { $0 }.joined(separator: "・")
        phase = .warming("\(label)を準備しています…")
        let systemPrompt = settings.systemPrompt
        task = Task { [weak self] in
            let interval = ConversationPerformance.begin("Conversation warmup")
            var failures: [String] = []
            // GPU を取り合うが、片方ずつより早く両方が揃う
            async let llm: String? = warmsLLM ? Self.warmLLM(systemPrompt: systemPrompt) : nil
            async let tts: String? = warmsTTS ? Self.warmTTS() : nil
            if let message = await llm { failures.append(message) }
            if let message = await tts { failures.append(message) }
            ConversationPerformance.end("Conversation warmup", interval, outcome: failures.isEmpty ? .completed : .failed)

            guard let self, !Task.isCancelled else { return }
            self.phase = failures.isEmpty ? .ready : .failed(failures.joined(separator: "\n"))
        }
    }

    private static func warmLLM(systemPrompt: String) async -> String? {
        #if os(iOS) && canImport(LlamaCpp)
        do {
            try await LocalLLMManager.shared.prewarm(systemPrompt: systemPrompt)
            return nil
        } catch {
            return "LLMの準備に失敗しました: \(error.localizedDescription)"
        }
        #else
        return nil
        #endif
    }

    private static func warmTTS() async -> String? {
        #if os(iOS) && canImport(IrodoriSpeechCpp)
        do {
            try await SpeechTTSManager.shared.prewarm()
            return nil
        } catch {
            return "音声合成の準備に失敗しました: \(error.localizedDescription)"
        }
        #else
        return nil
        #endif
    }
}
