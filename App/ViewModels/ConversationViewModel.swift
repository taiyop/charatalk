import Foundation
import SwiftUI
import AVFoundation
import IrodoriTTS
#if os(iOS) && canImport(IrodoriSpeechCpp)
import IrodoriSpeechCpp
#endif

@MainActor
public final class ConversationViewModel: ObservableObject {
    @Published public var inputText: String = ""
    @Published public var messages: [ChatMessage] = []
    @Published public var isBusy: Bool = false
    @Published public var statusMessage: String = ""
    @Published public var errorMessage: String?
    @Published public var showSettings: Bool = false
    
    /// マイクボタン等から開始された連続音声対話セッションがアクティブかどうか
    @Published public private(set) var isVoiceSessionActive: Bool = false
    
    /// AIが思考中（LLM推論中または最初のTTS音声合成準備中）かどうか
    @Published public private(set) var isThinking: Bool = false
    
    /// AIが音声再生・発話中かどうか（VRMリップシンク連動中）
    @Published public private(set) var isSpeaking: Bool = false

    @Published private var subtitleState = SpeechSubtitleState()

    /// 履歴とは独立して、字幕だけを音声の再生開始まで待機させる。
    public var subtitleMessage: ChatMessage? {
        subtitleState.visibleMessage(in: messages)
    }
    
    public let speechService = SpeechAnalyzerService.shared
    
    private let llmClient = LLMClient()
    private let ttsManager = SpeechTTSManager.shared
    private let audioPlayer = AudioSpeechPlayer.shared
    private let settings = AppSettings.shared
    
    // 現在実行中の音声合成・再生タスク
    private var currentSpeechTask: Task<Void, Never>?

    // LLM待機中の停止・リセットにも対応するターンID。
    // キャンセルに非協調的なプロバイダーからの遅い返答も無効化する。
    private var currentTurnID: UUID?
    
    // シミュレータ開発時の音声フォールバック用
    private var avSynthesizer: AVSpeechSynthesizer?
    #if targetEnvironment(simulator)
    private var simulatorSpeechStartObserver: SimulatorSpeechStartObserver?
    #endif
    
    public init() {
        // 初期ウェルカムメッセージ
        messages.append(ChatMessage(
            role: .assistant,
            content: "こんにちは！何かお話ししましょう。"
        ))
        
        // 設定のハンズフリーモードと同期
        speechService.isHandsFreeEnabled = settings.isHandsFreeMode
        
        // 音声認識（SpeechAnalyzer / SpeechTranscriber + SileroVAD）発話完了時のバインド
        speechService.onSpeechRecognized = { [weak self] recognizedText in
            guard let self = self else { return }
            Task { @MainActor in
                self.isVoiceSessionActive = true
                await self.processUserMessage(recognizedText)
            }
        }
    }
    
    public func sendCurrentMessage() {
        let typedText = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let recognizedText = speechService.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let isFromVoiceRecognition = typedText.isEmpty && !recognizedText.isEmpty
        let text = !typedText.isEmpty ? typedText : recognizedText
        guard !text.isEmpty, !isBusy else { return }
        
        inputText = ""
        if speechService.isListening || speechService.isPreparing {
            speechService.stopListening()
        }
        
        // 音声認識中のテキスト確定送信であれば音声セッションを維持、手動テキスト入力であればセッション終了
        if isFromVoiceRecognition {
            isVoiceSessionActive = true
        } else {
            isVoiceSessionActive = false
        }
        
        Task {
            await processUserMessage(text)
        }
    }
    
    /// 音声聞き取り（SpeechAnalyzer / SpeechTranscriber + SileroVAD）の開始/停止トグル
    public func toggleVoiceListening() {
        if speechService.isListening || speechService.isPreparing {
            let recognizedText = speechService.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            speechService.stopListening()
            // 音声認識中に文字が聞き取れている状態でマイクボタンを押した場合は、発話確定としてそのまま送信する
            if !recognizedText.isEmpty && !isBusy {
                isVoiceSessionActive = true
                Task {
                    await processUserMessage(recognizedText)
                }
            } else {
                // 音声認識待機中または準備中にマイクボタンを押して停止した場合は、音声対話セッションを終了する
                isVoiceSessionActive = false
            }
        } else {
            // マイクボタンを押して音声聞き取りを開始（音声対話セッションをアクティブ化）
            isVoiceSessionActive = true
            stopSpeaking(resetVoiceSession: false)
            errorMessage = nil
            Task {
                do {
                    try await speechService.startListening()
                } catch {
                    isVoiceSessionActive = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
    
    /// 返答待ち・音声合成・発話を途中で停止する
    public func stopSpeaking(resetVoiceSession: Bool = false) {
        currentTurnID = nil
        currentSpeechTask?.cancel()
        currentSpeechTask = nil
        audioPlayer.stop()
        avSynthesizer?.stopSpeaking(at: .immediate)
        isBusy = false
        isThinking = false
        isSpeaking = false
        statusMessage = ""
        subtitleState.reset()
        if resetVoiceSession {
            isVoiceSessionActive = false
        }
    }
    
    /// 音声対話セッションを終了し、マイクを停止する
    public func stopVoiceSession() {
        isVoiceSessionActive = false
        if speechService.isListening || speechService.isPreparing {
            let pendingTranscript = speechService.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !pendingTranscript.isEmpty && inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                inputText = pendingTranscript
            }
            speechService.stopListening()
        }
    }
    
    /// 会話を初期状態にリセットする
    public func resetConversation() {
        stopSpeaking(resetVoiceSession: true)
        if speechService.isListening || speechService.isPreparing {
            speechService.stopListening()
        }
        isVoiceSessionActive = false
        inputText = ""
        errorMessage = nil
        statusMessage = ""
        messages = [
            ChatMessage(
                role: .assistant,
                content: "こんにちは！何かお話ししましょう。"
            )
        ]
    }
    
    private func processUserMessage(_ text: String) async {
        let performance = ConversationPerformance(provider: settings.llmProviderType.rawValue,
                                                  mode: settings.ttsSynthesisMode.rawValue)
        await ConversationPerformance.$current.withValue(performance) {
            await runUserTurn(text)
        }
    }

    private func runUserTurn(_ text: String) async {
        // 以前の音声再生があれば停止
        stopSpeaking()

        let turnID = UUID()
        currentTurnID = turnID
        
        isBusy = true
        isThinking = true
        isSpeaking = false
        errorMessage = nil
        
        let userMsg = ChatMessage(role: .user, content: text)
        messages.append(userMsg)
        
        // 1. 選択中のLLMに送信
        switch settings.llmProviderType {
        case .localLFM:
            statusMessage = "ローカルAIが考えています…"
        case .chatGPTSignIn:
            statusMessage = "ChatGPTが考えています…"
        case .gemini:
            statusMessage = "Geminiが考えています…"
        case .openAICompatible:
            statusMessage = "返答を考えています…"
        }
        
        let replyText: String
        let llmInterval = ConversationPerformance.begin("LLM response")
        do {
            replyText = try await llmClient.generateReply(
                systemPrompt: settings.systemPrompt,
                messages: messages,
                temperature: settings.temperature
            )
            ConversationPerformance.end("LLM response", llmInterval, outcome: .completed)
        } catch {
            ConversationPerformance.end("LLM response", llmInterval, outcome: ConversationPerformance.outcome(for: error))
            guard currentTurnID == turnID else { return }
            currentTurnID = nil
            isBusy = false
            isThinking = false
            isSpeaking = false
            statusMessage = ""
            isVoiceSessionActive = false
            errorMessage = error.localizedDescription
            return
        }

        // 停止・リセット後や新しいターンの開始後は、古い返答を
        // 履歴へ追加せず、合成・再生もしない。
        guard currentTurnID == turnID, !Task.isCancelled else { return }
        
        let speechPerformance = ConversationPerformance.current?.recordingReplyReady()
        // 2. アシスタント返答を履歴に追加
        let assistantMsg = ChatMessage(role: .assistant, content: replyText)
        subtitleState.prepare(for: assistantMsg.id)
        messages.append(assistantMsg)
        
        // 3. 設定した単位で音声合成と再生
        await ConversationPerformance.$current.withValue(speechPerformance) {
            guard self.currentTurnID == turnID else { return }
            let task = Task { [weak self] in
                guard let self = self else { return }
                await self.speakResponse(replyText, messageID: assistantMsg.id, turnID: turnID)
            }
            self.currentSpeechTask = task
            await task.value
        }
    }
    
    /// 文ごとは短文を適度にまとめ、最初のチャンクから同じプレーヤーへ
    /// 順次予約する。続くチャンクは最大2個先読みする。
    /// 全文モードは1回の合成・再生で読み上げる。
    private func speakResponse(_ text: String, messageID: UUID, turnID: UUID) async {
        // 音声なし・合成失敗・キャンセルでも返答の本文は確認できるようにする。
        defer {
            subtitleState.reveal(for: messageID)
            if currentTurnID == turnID {
                // 完了後の遅い開始通知でも発話中表示へ戻らないようにする。
                currentTurnID = nil
                currentSpeechTask = nil
            }
        }
        guard currentTurnID == turnID, !Task.isCancelled else { return }

        let chunks = ConversationPerformance.measure("Speech text preparation") {
            SentenceSplitter.chunks(text: text, mode: settings.ttsSynthesisMode)
        }
        guard !chunks.isEmpty else {
            isBusy = false
            isThinking = false
            isSpeaking = false
            statusMessage = ""
            resumeListeningIfNeeded()
            return
        }

        statusMessage = "音声を準備しています…"
        
        #if targetEnvironment(simulator)
        // シミュレータ環境フォールバック
        for (index, chunk) in chunks.enumerated() {
            guard !Task.isCancelled else { break }
            await playSimulatorSpeech(text: chunk) { [weak self] in
                self?.speechPlaybackStarted(messageID: messageID, turnID: turnID, index: index, total: chunks.count)
            }
        }
        if currentTurnID == turnID, !Task.isCancelled {
            isBusy = false
            isThinking = false
            isSpeaking = false
            statusMessage = ""
            resumeListeningIfNeeded()
        }
        #else
        // 実機環境: どちらの方式も Irodori TTS (speech.cpp) で合成
        guard ttsManager.isModelInstalled else {
            isBusy = false
            isThinking = false
            isSpeaking = false
            statusMessage = ""
            isVoiceSessionActive = false
            errorMessage = "Irodori TTSの音声モデルが未取得です。設定画面からモデルをダウンロードしてください。"
            return
        }
        
        let seedValue: UInt32 = settings.useRandomSeed ? UInt32.random(in: 0...UInt32.max) : UInt32(settings.speakerSeed)
        let caption = settings.ttsCaption
        let watermark = settings.watermarkEnabled
        #if os(iOS) && canImport(IrodoriSpeechCpp)
        let ttsOptions = settings.currentSynthesisOptions
        #endif
        
        let total = chunks.count
        // Pipeline synthesis is strictly serial and ordered. Keep this counter
        // aligned with its chunk indices for TTS-internal diagnostic context.
        var preparedCount = 0
        let playbackStream = audioPlayer.beginQueue()
        defer { audioPlayer.endQueue(playbackStream) }
        var playbackCompletions: [Int: SpeechPlaybackCompletion] = [:]
        statusMessage = total > 1 ? "音声を準備しています… (1/\(total))" : "音声を準備しています…"
        do {
            try await SpeechPlaybackPipeline.play(chunks: chunks, onEvent: { event in
                guard let performance = ConversationPerformance.current else { return }
                switch event {
                case .synthesisStarted(let index):
                    ConversationPerformance.$chunkIndex.withValue(index) {
                        ConversationPerformance.event("Speech synthesis requested")
                    }
                case .synthesisCompleted(let index, let elapsed):
                    performance.duration("chunk_synthesis", seconds: elapsed, chunk: index)
                case .playbackWaitCompleted(let index, let elapsed):
                    performance.duration("playback_buffer_wait", seconds: elapsed, chunk: index)
                case .playbackStarted(let index):
                    ConversationPerformance.$chunkIndex.withValue(index) {
                        ConversationPerformance.event("Speech playback requested")
                    }
                case .playbackCompleted(let index, let elapsed):
                    performance.duration("chunk_playback", seconds: elapsed, chunk: index)
                }
            }) { chunk in
                do {
                    let pcm = try await ConversationPerformance.$chunkIndex.withValue(preparedCount) {
                        #if os(iOS) && canImport(IrodoriSpeechCpp)
                        return try await self.ttsManager.synthesize(
                            text: chunk, caption: caption, seed: seedValue,
                            options: ttsOptions, watermark: watermark
                        )
                        #else
                        return try await self.ttsManager.synthesize(
                            text: chunk, caption: caption, seed: seedValue, watermark: watermark
                        )
                        #endif
                    }
                    preparedCount += 1
                    return pcm
                } catch {
                    if error is CancellationError || Task.isCancelled { throw CancellationError() }
                    throw IrodoriError.invalid("音声合成エラー: \(error.localizedDescription)")
                }
            } enqueue: { pcmData, index in
                playbackCompletions[index] = try ConversationPerformance.$chunkIndex.withValue(index) {
                    try self.audioPlayer.enqueue(pcm16: pcmData, streamID: playbackStream) {
                        self.speechPlaybackStarted(messageID: messageID, turnID: turnID, index: index, total: total)
                    }
                }
            } stopPlayback: {
                self.audioPlayer.endQueue(playbackStream)
            } play: { _, index in
                do {
                    guard let completion = playbackCompletions.removeValue(forKey: index) else {
                        throw IrodoriError.invalid("音声の再生予約が見つかりません。")
                    }
                    try await completion.wait()
                } catch {
                    if error is CancellationError || Task.isCancelled { throw CancellationError() }
                    throw IrodoriError.invalid("音声再生エラー: \(error.localizedDescription)")
                }
            }
        } catch {
            // Playback replacement/stop can cancel the session independently of
            // this task. Never let that old request overwrite the newer UI state.
            if currentTurnID != turnID || error is CancellationError || Task.isCancelled { return }
            isBusy = false
            isThinking = false
            isSpeaking = false
            statusMessage = ""
            isVoiceSessionActive = false
            errorMessage = error.localizedDescription
            return
        }
        
        if currentTurnID == turnID, !Task.isCancelled {
            isBusy = false
            isThinking = false
            isSpeaking = false
            statusMessage = ""
            resumeListeningIfNeeded()
        }
        #endif
    }

    private func speechPlaybackStarted(messageID: UUID, turnID: UUID, index: Int, total: Int) {
        // 停止済み、または別のターンへ進んだ後の通知では表示を変えない。
        guard currentTurnID == turnID, messages.last?.id == messageID else { return }
        subtitleState.reveal(for: messageID)
        isThinking = false
        isSpeaking = true
        statusMessage = total > 1 ? "お話し中… (\(index + 1)/\(total))" : "お話し中…"
    }
    
    /// AIのターン終了時に、マイクボタン押下による音声対話セッションまたはハンズフリー設定が有効なら自動でマイク入力待ちに復帰する
    private func resumeListeningIfNeeded() {
        guard isVoiceSessionActive || speechService.isHandsFreeEnabled else { return }
        
        Task {
            // スピーカー音の減衰・消音およびオーディオセッション安定のためのガード時間（200ms）
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled, !self.isBusy, !self.speechService.isListening, !self.speechService.isPreparing else { return }
            do {
                try await self.speechService.startListening()
            } catch {
                self.isVoiceSessionActive = false
                self.errorMessage = "マイクの再開に失敗しました: \(error.localizedDescription)"
            }
        }
    }
    
    #if targetEnvironment(simulator)
    private func playSimulatorSpeech(
        text: String,
        onPlaybackStarted: @escaping @MainActor @Sendable () -> Void
    ) async {
        if avSynthesizer == nil {
            avSynthesizer = AVSpeechSynthesizer()
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "ja-JP")
        utterance.rate = 0.52

        // speak() はキュー投入のみ。字幕は実際の didStart 通知まで待つ。
        let observer = SimulatorSpeechStartObserver(onStarted: onPlaybackStarted)
        simulatorSpeechStartObserver = observer
        avSynthesizer?.delegate = observer
        
        avSynthesizer?.speak(utterance)
        
        // シミュレータ用の擬似発話待機
        let duration = max(1.0, Double(text.count) * 0.15)
        let steps = Int(duration * 20)
        for _ in 0..<steps {
            if Task.isCancelled { break }
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }
    }
    #endif
}

#if targetEnvironment(simulator)
private final class SimulatorSpeechStartObserver: NSObject, AVSpeechSynthesizerDelegate {
    private let onStarted: @MainActor @Sendable () -> Void

    init(onStarted: @escaping @MainActor @Sendable () -> Void) {
        self.onStarted = onStarted
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let callback = onStarted
        Task { @MainActor in callback() }
    }
}
#endif
