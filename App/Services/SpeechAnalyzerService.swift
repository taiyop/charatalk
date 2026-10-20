@preconcurrency import AVFoundation
import CoreMedia
import Foundation
@preconcurrency import Speech
import Accelerate

/// SpeechAnalyzer / SpeechTranscriber と SileroVAD を使ったリアルタイム音声対話サービス
@available(iOS 18.0, *)
@MainActor
public final class SpeechAnalyzerService: ObservableObject {
    public static let shared = SpeechAnalyzerService()
    
    // MARK: - 公開状態プロパティ (UIバインディング)
    @Published public private(set) var isPreparing: Bool = false
    @Published public private(set) var isListening: Bool = false
    @Published public private(set) var isUserSpeaking: Bool = false
    @Published public private(set) var liveTranscript: String = ""
    @Published public private(set) var audioLevel: Float = 0.0
    @Published public private(set) var vadProbability: Float = 0.0
    @Published public var isHandsFreeEnabled: Bool = false
    
    // 発話完了時のコールバック（認識テキストを通知）
    public var onSpeechRecognized: ((String) -> Void)?
    
    // バックグラウンドで安全に動作する専用オーディオワーカー
    private var worker: AudioRecognitionWorker?
    private var isProcessingEndOfSpeech = false
    private var lastAudioLevelUpdateTime: Date = .distantPast
    
    public init() {}
    
    // MARK: - リスニング開始
    public func startListening() async throws {
        guard !isListening, !isPreparing else { return }
        isPreparing = true
        
        // 状態リセット（※この時点ではまだマイク入力準備中なので isListening = true にはしない）
        liveTranscript = ""
        isUserSpeaking = false
        audioLevel = 0.0
        vadProbability = 0.0
        isProcessingEndOfSpeech = false
        lastAudioLevelUpdateTime = .distantPast
        
        // 既存のワーカーが残っていれば停止
        worker?.stop()
        worker = nil
        
        defer {
            isPreparing = false
        }
        
        // 1. マイク権限の確認 (既に許可済みならサスペンドせず同期的に即通過)
        let micAllowed: Bool
        if AVAudioApplication.shared.recordPermission == .granted {
            micAllowed = true
        } else {
            micAllowed = await Self.requestMicrophonePermission()
        }
        guard micAllowed else {
            throw NSError(
                domain: "SpeechAnalyzerService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "マイクへのアクセスが許可されていません。設定アプリから許可してください。"]
            )
        }
        
        // 2. 音声認識権限の確認 (既に許可済みならサスペンドせず同期的に即通過)
        let speechAllowed: Bool
        if SFSpeechRecognizer.authorizationStatus() == .authorized {
            speechAllowed = true
        } else {
            speechAllowed = await Self.requestSpeechPermission()
        }
        guard speechAllowed else {
            throw NSError(
                domain: "SpeechAnalyzerService",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "音声認識へのアクセスが許可されていません。設定アプリから許可してください。"]
            )
        }
        
        // 権限確認中に外部から stopListening() された場合は中断
        guard isPreparing else { return }
        
        // ワーカーの生成（MainActorから独立したスレッドセーフなインスタンス）
        let worker = AudioRecognitionWorker()
        self.worker = worker
        
        // コールバック接続（ワーカーからMainActorへの安全な通知）
        worker.onTranscriptUpdated = { [weak self, weak worker] text in
            Task { @MainActor [weak self, weak worker] in
                guard let self = self, let worker = worker, self.isListening, self.worker === worker else { return }
                if self.liveTranscript != text {
                    self.liveTranscript = text
                }
            }
        }
        
        worker.onAudioMetricsUpdated = { [weak self, weak worker] level, prob, speaking in
            Task { @MainActor [weak self, weak worker] in
                guard let self = self, let worker = worker, self.isListening, self.worker === worker else { return }
                if self.isUserSpeaking != speaking {
                    self.isUserSpeaking = speaking
                }
                let now = Date()
                if now.timeIntervalSince(self.lastAudioLevelUpdateTime) >= 0.08 {
                    if abs(self.audioLevel - level) > 0.03 || (level == 0.0 && self.audioLevel != 0.0) {
                        self.audioLevel = level
                        self.vadProbability = prob
                        self.lastAudioLevelUpdateTime = now
                    }
                }
            }
        }
        
        worker.onSpeechDidEnd = { [weak self, weak worker] text in
            Task { @MainActor [weak self, weak worker] in
                guard let self = self, let worker = worker, self.isListening, self.worker === worker else { return }
                self.handleSpeechEnd(recognizedText: text)
            }
        }
        
        // エンジン起動（マイクキャプチャ & 音声認識モデルの初期化）
        do {
            try await worker.start()
            // 起動待機中に stopListening() が呼ばれていた場合は直ちに停止
            guard self.isPreparing && self.worker === worker else {
                worker.stop()
                return
            }
            // マイク入力および認識の準備が完了してからリスニング状態にする
            self.isListening = true
        } catch {
            worker.stop()
            if self.worker === worker {
                self.worker = nil
                self.isListening = false
                self.isUserSpeaking = false
                self.audioLevel = 0.0
                self.vadProbability = 0.0
            }
            throw error
        }
    }
    
    // MARK: - リスニング停止
    public func stopListening() {
        guard isListening || isPreparing || worker != nil else { return }
        
        isPreparing = false
        worker?.stop()
        worker = nil
        
        isListening = false
        isUserSpeaking = false
        liveTranscript = ""
        audioLevel = 0.0
        vadProbability = 0.0
    }
    
    // MARK: - ユーザー発話完了（ターンテイク）処理
    private func handleSpeechEnd(recognizedText: String) {
        guard !isProcessingEndOfSpeech else { return }
        isProcessingEndOfSpeech = true
        
        let cleanedText = recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedText.isEmpty else {
            isProcessingEndOfSpeech = false
            return
        }
        
        print("[SpeechAnalyzerService] User finished speaking: \"\(cleanedText)\"")
        
        // AIの返答・音声再生中はマイク入力を一時停止する
        // （ハンズフリーモード時はConversationViewModel側で発話完了後にstartListening()が再呼び出しされる）
        stopListening()
        isProcessingEndOfSpeech = false
        
        onSpeechRecognized?(cleanedText)
    }
    
    // MARK: - 権限確認 (nonisolated: バックグラウンドキューからのコールバックでMainActorアサーション違反を起こさないため)
    nonisolated private static func requestMicrophonePermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }
    
    nonisolated private static func requestSpeechPermission() async -> Bool {
        let currentStatus = SFSpeechRecognizer.authorizationStatus()
        if currentStatus == .authorized {
            return true
        }
        if currentStatus == .denied || currentStatus == .restricted {
            return false
        }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
}

// MARK: - オーディオスレッド / バックグラウンドキューで安全に動作する非MainActorワーカー
/// MainActorから完全に分離し、libdispatchのキューアサーション違反を防ぐ
private final class AudioRecognitionWorker: @unchecked Sendable {
    // コールバック
    var onTranscriptUpdated: (@Sendable (String) -> Void)?
    var onAudioMetricsUpdated: (@Sendable (Float, Float, Bool) -> Void)?
    var onSpeechDidEnd: (@Sendable (String) -> Void)?
    
    private var audioEngine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    
    // シリアル処理用ディスパッチキュー（オーディオIOスレッドを一切ブロックしない）
    private let processingQueue = DispatchQueue(label: "com.charatalk.speech.worker", qos: .userInteractive)
    
    // SFSpeechRecognizer コールバック専用オペレーションキュー（MainQueueを使わずバックグラウンドで受ける）
    private let recognitionOperationQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.charatalk.speech.recognition"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInteractive
        return q
    }()
    
    // Silero VAD & バッファ（processingQueue上でアクセス）
    private let vadDetector = SileroVADDetector()
    private var vadSampleBuffer: [Float] = []
    private let vadChunkSize = 512 // 16kHz で約32ms
    private var currentTranscript: String = ""
    private var committedPrefixTranscript: String = ""
    private var lastTranscriptUpdateTime: Date?
    private var lastSpeechAudioTime: Date?
    private var lastStrongSpeechAudioTime: Date?
    private var vadSpeechDidEnd: Bool = false
    private var vadSpeechEndTime: Date?
    private var recognizerDidFinalize: Bool = false
    private var isFinalizingSpeech: Bool = false
    private var transcriptWatchdogTimer: DispatchSourceTimer?
    private var finalizationTimer: DispatchSourceTimer?
    private var isStopped = false
    
    // iOS 26+ 用 SpeechAnalyzer バックエンド
    private var modernBackend: Any?
    private var usesModernBackend = false
    
    // iOS 18+ 用 SFSpeechRecognizer バックエンド
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    
    // 日本語の日常挨拶・丁寧語表現が語途中で分割（「どういたしまして」→「どういた」等）されないよう言語モデルにヒントを与える
    private static let japaneseContextualPhrases: [String] = [
        "どういたしまして",
        "ありがとうございます",
        "ありがとうございました",
        "よろしくお願いします",
        "よろしくお願いいたします",
        "お疲れ様です",
        "お疲れ様でした",
        "おはようございます",
        "こんにちは",
        "こんばんは",
        "おやすみなさい",
        "ごめんなさい",
        "すみません",
        "かしこまりました",
        "なるほどですね"
    ]
    
    init() {
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP"))
        recognizer?.queue = recognitionOperationQueue
        speechRecognizer = recognizer
    }
    
    func start() async throws {
        processingQueue.sync {
            isStopped = false
            currentTranscript = ""
            committedPrefixTranscript = ""
            lastTranscriptUpdateTime = nil
            lastSpeechAudioTime = nil
            lastStrongSpeechAudioTime = nil
            vadSpeechDidEnd = false
            vadSpeechEndTime = nil
            recognizerDidFinalize = false
            isFinalizingSpeech = false
            cancelWatchdogTimer()
            cancelFinalizationTimer()
            vadDetector.reset()
            vadSampleBuffer.removeAll(keepingCapacity: true)
        }
        
        // 1. オーディオセッションの設定 (.default モードで標準マイクゲインを確保し、VoiceProcessingIOによる過度なゲート抑制を回避)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        
        // 2. AVAudioEngine の設定
        let engine = AVAudioEngine()
        self.audioEngine = engine
        let inputNode = engine.inputNode
        
        // 既存のタップがあれば安全に解除
        inputNode.removeTap(onBus: 0)
        
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw NSError(
                domain: "AudioRecognitionWorker",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "マイクのオーディオフォーマットが無効です（サンプルレートまたはチャンネル数が0です）。"]
            )
        }
        
        // 16kHz モノラル Float32 フォーマット（Silero VAD 用）
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false) else {
            throw NSError(
                domain: "AudioRecognitionWorker",
                code: -4,
                userInfo: [NSLocalizedDescriptionKey: "VAD用オーディオフォーマットの生成に失敗しました。"]
            )
        }
        self.targetFormat = targetFormat
        
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw NSError(
                domain: "AudioRecognitionWorker",
                code: -5,
                userInfo: [NSLocalizedDescriptionKey: "オーディオコンバータの初期化に失敗しました。"]
            )
        }
        self.converter = converter
        
        // 3. バックエンドの初期化 & タップ登録
        // iOS 26.0+ では SpeechAnalyzer / SpeechTranscriber のオンデバイスアセットがインストール済みの場合のみ使用し、
        // 未導入時は即座に SFSpeechRecognizer にフォールバックする
        var startedModern = false
        if #available(iOS 26.0, *) {
            let backend = ModernSpeechBackend()
            do {
                try await backend.start { [weak self] text, isUtteranceFinal in
                    guard let self = self else { return }
                    self.processingQueue.async {
                        self.handleTranscriptUpdate(text, isFinal: isUtteranceFinal)
                    }
                }
                self.modernBackend = backend
                self.usesModernBackend = true
                startedModern = true
            } catch {
                print("[AudioRecognitionWorker] ModernSpeechBackend unavailable, falling back to SFSpeechRecognizer: \(error.localizedDescription)")
                backend.stop()
                self.modernBackend = nil
                self.usesModernBackend = false
            }
        }
        
        if startedModern {
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
                guard let self = self else { return }
                self.processingQueue.async {
                    self.processBuffer(buffer, inputFormat: inputFormat, targetFormat: targetFormat)
                }
            }
        } else {
            processingQueue.sync {
                self.startSFSpeechRecognitionSession(preservingPrefix: false)
            }
            
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
                guard let self = self else { return }
                self.processingQueue.async {
                    guard !self.isStopped else { return }
                    if !self.isFinalizingSpeech {
                        self.recognitionRequest?.append(buffer)
                    }
                    self.processBuffer(buffer, inputFormat: inputFormat, targetFormat: targetFormat)
                }
            }
        }
        
        engine.prepare()
        try engine.start()
    }
    
    func stop() {
        if let engine = audioEngine {
            if engine.isRunning {
                engine.stop()
            }
            engine.inputNode.removeTap(onBus: 0)
        }
        audioEngine = nil
        
        if #available(iOS 26.0, *) {
            if let backend = modernBackend as? ModernSpeechBackend {
                backend.stop()
            }
            modernBackend = nil
            usesModernBackend = false
        }
        
        processingQueue.async { [weak self] in
            guard let self = self else { return }
            self.isStopped = true
            self.isFinalizingSpeech = false
            self.cancelWatchdogTimer()
            self.cancelFinalizationTimer()
            self.recognitionRequest?.endAudio()
            self.recognitionRequest = nil
            self.recognitionTask?.cancel()
            self.recognitionTask = nil
            self.converter = nil
            self.vadSampleBuffer.removeAll(keepingCapacity: false)
            self.currentTranscript = ""
            self.committedPrefixTranscript = ""
            self.lastTranscriptUpdateTime = nil
            self.lastSpeechAudioTime = nil
            self.lastStrongSpeechAudioTime = nil
            self.vadSpeechDidEnd = false
            self.vadSpeechEndTime = nil
            self.recognizerDidFinalize = false
        }
    }
    
    func resetVAD() {
        processingQueue.async { [weak self] in
            guard let self = self else { return }
            self.cancelWatchdogTimer()
            self.cancelFinalizationTimer()
            self.vadDetector.reset()
            self.vadSampleBuffer.removeAll(keepingCapacity: true)
            self.currentTranscript = ""
            self.committedPrefixTranscript = ""
            self.lastTranscriptUpdateTime = nil
            self.lastSpeechAudioTime = nil
            self.lastStrongSpeechAudioTime = nil
            self.vadSpeechDidEnd = false
            self.vadSpeechEndTime = nil
            self.recognizerDidFinalize = false
            self.isFinalizingSpeech = false
            if #available(iOS 26.0, *) {
                if let backend = self.modernBackend as? ModernSpeechBackend {
                    backend.resetTranscript()
                }
            }
        }
    }
    
    // MARK: - SFSpeechRecognizer セッション管理（processingQueue上で実行）
    private func startSFSpeechRecognitionSession(preservingPrefix: Bool) {
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        
        if !preservingPrefix {
            committedPrefixTranscript = ""
        }
        
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.contextualStrings = Self.japaneseContextualPhrases
        self.recognitionRequest = request
        
        self.recognitionTask = speechRecognizer?.recognitionTask(with: request) { [weak self, weak request] result, error in
            guard let self = self else { return }
            self.processingQueue.async {
                guard !self.isStopped, self.recognitionRequest === request else { return }
                
                if let result = result {
                    let segmentText = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                    let fullText: String
                    if !self.committedPrefixTranscript.isEmpty {
                        let cleanPrefix = self.committedPrefixTranscript.hasSuffix("。")
                            ? String(self.committedPrefixTranscript.dropLast())
                            : self.committedPrefixTranscript
                        if segmentText.isEmpty {
                            fullText = self.committedPrefixTranscript
                        } else if segmentText.hasPrefix(cleanPrefix) {
                            fullText = segmentText
                        } else {
                            fullText = cleanPrefix + segmentText
                        }
                    } else {
                        fullText = segmentText
                    }
                    
                    let now = Date()
                    let isCurrentlySpeaking = self.vadDetector.isSpeaking ||
                        (self.lastSpeechAudioTime.map { now.timeIntervalSince($0) < 0.45 } ?? false)
                    
                    if result.isFinal && !self.isFinalizingSpeech && isCurrentlySpeaking && !fullText.isEmpty {
                        // ユーザーがまだ発話継続中（「どういた」の直後に「しまして」を話している最中など）に
                        // SFSpeechRecognizer が一旦セグメントを確定した場合は、それまでの文字列をプレフィックスとして保持しセッションをシームレスに継続する
                        self.handleTranscriptUpdate(fullText, isFinal: false)
                        self.committedPrefixTranscript = self.currentTranscript
                        self.startSFSpeechRecognitionSession(preservingPrefix: true)
                        return
                    }
                    
                    if !fullText.isEmpty {
                        self.handleTranscriptUpdate(fullText, isFinal: result.isFinal)
                    } else if result.isFinal && !self.currentTranscript.isEmpty {
                        self.recognizerDidFinalize = true
                        if self.isFinalizingSpeech {
                            self.completeFinalizationIfNeeded()
                        } else {
                            self.evaluateSpeechCompletion()
                        }
                    }
                }
                
                if let error = error {
                    print("[AudioRecognitionWorker] SFSpeechRecognizer task finished/error: \(error.localizedDescription)")
                    guard !self.isStopped else { return }
                    if self.isFinalizingSpeech {
                        self.completeFinalizationIfNeeded()
                        return
                    }
                    let existing = self.currentTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
                    let now = Date()
                    let isCurrentlySpeaking = self.vadDetector.isSpeaking ||
                        (self.lastSpeechAudioTime.map { now.timeIntervalSince($0) < 0.45 } ?? false)
                    if !existing.isEmpty && isCurrentlySpeaking {
                        self.committedPrefixTranscript = existing
                        self.startSFSpeechRecognitionSession(preservingPrefix: true)
                    } else if !existing.isEmpty {
                        // 既に認識済みテキストがある状態で発話終了後にタスクが完了した場合は即座に確定送信する
                        self.recognizerDidFinalize = true
                        self.completeFinalizationIfNeeded()
                    } else {
                        // 無音タイムアウト等で認識テキストが空のまま終了した場合は自動でリクエストを再開して待機を継続する
                        self.startSFSpeechRecognitionSession(preservingPrefix: false)
                    }
                }
            }
        }
    }
    
    // MARK: - 文字認識更新 & 自動送信判定（processingQueue上で実行）
    private static func normalizedCoreText(_ text: String) -> String {
        let stripped = text.unicodeScalars.filter { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar) &&
            !CharacterSet.punctuationCharacters.contains(scalar)
        }
        return String(String.UnicodeScalarView(stripped))
    }
    
    private func handleTranscriptUpdate(_ text: String, isFinal: Bool) {
        guard !isStopped else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        let now = Date()
        let prevCore = Self.normalizedCoreText(currentTranscript)
        let newCore = Self.normalizedCoreText(trimmed)
        
        // ファイナライズ（endAudioフラッシュ）中や認識後半で、まれに直前の確定文字列の先頭部分のみに短く巻き戻る現象を防ぐ
        if !prevCore.isEmpty && !newCore.isEmpty && prevCore.count > newCore.count && prevCore.hasPrefix(newCore) {
            if isFinal {
                recognizerDidFinalize = true
                if isFinalizingSpeech {
                    completeFinalizationIfNeeded()
                }
            }
            return
        }
        
        // 句読点や空白のみの自動補完（「こんにちは」→「こんにちは。」など）では無音タイマーをリセットしない
        if newCore != prevCore || lastTranscriptUpdateTime == nil {
            lastTranscriptUpdateTime = now
        }
        
        if currentTranscript != trimmed {
            currentTranscript = trimmed
            onTranscriptUpdated?(trimmed)
        }
        
        if isFinal {
            recognizerDidFinalize = true
        }
        
        if isFinalizingSpeech {
            if isFinal {
                completeFinalizationIfNeeded()
            }
            return
        }
        
        startTranscriptWatchdogIfNeeded()
        evaluateSpeechCompletion(now: now)
    }
    
    private func startTranscriptWatchdogIfNeeded() {
        guard transcriptWatchdogTimer == nil, !isStopped, !isFinalizingSpeech else { return }
        let timer = DispatchSource.makeTimerSource(queue: processingQueue)
        timer.schedule(deadline: .now() + 0.15, repeating: 0.15)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.evaluateSpeechCompletion(now: Date())
        }
        transcriptWatchdogTimer = timer
        timer.resume()
    }
    
    private func cancelWatchdogTimer() {
        transcriptWatchdogTimer?.cancel()
        transcriptWatchdogTimer = nil
    }
    
    private func cancelFinalizationTimer() {
        finalizationTimer?.cancel()
        finalizationTimer = nil
    }
    
    /// 発話終了判定後、直前まで文字認識が更新されていた場合のみ短時間フラッシュし、既に文字列が安定している場合は即座に確定させる
    private func beginFinalizingSpeech(now: Date = Date()) {
        guard !isStopped, !isFinalizingSpeech else { return }
        let existing = currentTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !existing.isEmpty else { return }
        
        let timeSinceLastTranscript = lastTranscriptUpdateTime.map { now.timeIntervalSince($0) } ?? 1.0
        
        // 既に確定済み、または無音区間中に最後の文字更新から0.30秒以上経過して文字列が安定している場合は待ち時間ゼロで即座に確定
        if recognizerDidFinalize || timeSinceLastTranscript >= 0.30 {
            finishSpeechRecognition(with: existing)
            return
        }
        
        isFinalizingSpeech = true
        cancelWatchdogTimer()
        
        // 直前まで文字が動いていた場合のみ短時間（最大0.15秒）フラッシュして語尾を取りこぼさないようにする
        let timer = DispatchSource.makeTimerSource(queue: processingQueue)
        timer.schedule(deadline: .now() + 0.15)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.completeFinalizationIfNeeded()
        }
        finalizationTimer = timer
        timer.resume()
        
        if usesModernBackend, #available(iOS 26.0, *) {
            if let backend = modernBackend as? ModernSpeechBackend {
                backend.finalize { [weak self] in
                    guard let self = self else { return }
                    self.processingQueue.async {
                        self.completeFinalizationIfNeeded()
                    }
                }
            } else {
                completeFinalizationIfNeeded()
            }
        } else {
            recognitionRequest?.endAudio()
            recognitionTask?.finish()
        }
    }
    
    private func completeFinalizationIfNeeded() {
        guard !isStopped else { return }
        cancelFinalizationTimer()
        let finalText = currentTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !finalText.isEmpty else {
            isFinalizingSpeech = false
            return
        }
        finishSpeechRecognition(with: finalText)
    }
    
    private func finishSpeechRecognition(with finalText: String) {
        guard !isStopped else { return }
        isStopped = true
        isFinalizingSpeech = false
        cancelWatchdogTimer()
        cancelFinalizationTimer()
        onSpeechDidEnd?(finalText)
    }
    
    private func evaluateSpeechCompletion(now: Date = Date(), forceIfTranscriptExists: Bool = false) {
        guard !isStopped, !isFinalizingSpeech else { return }
        let finalText = currentTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !finalText.isEmpty else { return }
        
        if forceIfTranscriptExists {
            finishSpeechRecognition(with: finalText)
            return
        }
        
        let timeSinceLastTranscript = lastTranscriptUpdateTime.map { now.timeIntervalSince($0) } ?? 0.0
        let timeSinceLastSpeechAudio = lastSpeechAudioTime.map { now.timeIntervalSince($0) } ?? timeSinceLastTranscript
        let timeSinceStrongSpeech = lastStrongSpeechAudioTime.map { now.timeIntervalSince($0) } ?? timeSinceLastTranscript
        let isVADSpeaking = vadDetector.isSpeaking
        
        // 1) VADが無音遷移を検知し、最後の発話音声から0.55秒以上・最後の文字更新から0.22秒以上経過したとき
        let shouldFinishByVAD = !isVADSpeaking &&
            vadSpeechDidEnd &&
            timeSinceLastSpeechAudio >= 0.55 &&
            timeSinceLastTranscript >= 0.22
        
        // 2) 音声認識エンジン自体が発話全体の確定(isFinal)を通知し、VADが無音かつ最後の文字更新から0.18秒以上経過したとき
        let shouldFinishByRecognizerFinal = !isVADSpeaking &&
            recognizerDidFinalize &&
            timeSinceLastTranscript >= 0.18 &&
            timeSinceLastSpeechAudio >= 0.45
        
        // 3) VADが無音状態で、最後の発話音声から0.65秒以上かつ文字認識が更新された後0.75秒以上経過したとき（小声発話時のフォールバック）
        let shouldFinishByTranscriptSilence = !isVADSpeaking &&
            timeSinceLastTranscript >= 0.75 &&
            timeSinceLastSpeechAudio >= 0.65
        
        // 4) 環境ノイズ等でVADが発話中と判定し続けていても、強い発話エネルギーが0.85秒以上なく認識テキストが1.25秒以上変化していないとき
        let shouldFinishByTranscriptStability = timeSinceLastTranscript >= 1.25 &&
            timeSinceStrongSpeech >= 0.85
        
        if shouldFinishByVAD || shouldFinishByRecognizerFinal || shouldFinishByTranscriptSilence || shouldFinishByTranscriptStability {
            beginFinalizingSpeech(now: now)
        }
    }
    
    private func processBuffer(_ buffer: AVAudioPCMBuffer, inputFormat: AVAudioFormat, targetFormat: AVAudioFormat) {
        guard !isStopped, !isFinalizingSpeech, let converter = self.converter else { return }
        
        let ratio = 16000.0 / inputFormat.sampleRate
        let frameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else { return }
        
        var error: NSError?
        nonisolated(unsafe) var didProvideBuffer = false
        converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
            if !didProvideBuffer {
                didProvideBuffer = true
                outStatus.pointee = .haveData
                return buffer
            } else {
                outStatus.pointee = .noDataNow
                return nil
            }
        }
        
        if error != nil {
            return
        }
        
        if usesModernBackend, #available(iOS 26.0, *) {
            if let backend = modernBackend as? ModernSpeechBackend {
                backend.feed(float32Buffer: convertedBuffer)
            }
        }
        
        guard let channelData = convertedBuffer.floatChannelData?[0] else { return }
        let count = Int(convertedBuffer.frameLength)
        guard count > 0 else { return }
        let samples = Array(UnsafeBufferPointer(start: channelData, count: count))
        
        vadSampleBuffer.append(contentsOf: samples)
        
        while vadSampleBuffer.count >= vadChunkSize {
            let chunk = Array(vadSampleBuffer.prefix(vadChunkSize))
            vadSampleBuffer.removeFirst(vadChunkSize)
            
            let result = vadDetector.process(samples: chunk)
            let now = Date()
            
            // 実際に音声確率が発話閾値以上のチャンクのみを最終発話時刻として記録する（無音カウントダウン中に更新し続けないようにする）
            if result.probability >= vadDetector.speechThreshold {
                self.lastSpeechAudioTime = now
            }
            if result.probability >= 0.65 {
                self.lastStrongSpeechAudioTime = now
            }
            
            var rms: Float = 0.0
            vDSP_rmsqv(chunk, 1, &rms, vDSP_Length(chunk.count))
            let level = min(1.0, rms * 10.0)
            
            // 音声認識が文字を出力している最中も発話中として扱う
            let isTranscriptActive = if let lastUpdate = self.lastTranscriptUpdateTime {
                now.timeIntervalSince(lastUpdate) < 0.45
            } else {
                false
            }
            let effectiveSpeaking = result.isSpeaking || isTranscriptActive
            
            self.onAudioMetricsUpdated?(level, result.probability, effectiveSpeaking)
            
            if result.speechDidEnd {
                self.vadSpeechDidEnd = true
                self.vadSpeechEndTime = now
            } else if result.isSpeaking {
                // 発話継続中または再発話時は終了フラグを即座にクリアする（「どういた」の後の「しまして」で早期終了しないようにする）
                self.vadSpeechDidEnd = false
                self.vadSpeechEndTime = nil
            }
            
            let finalText = self.currentTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !finalText.isEmpty {
                self.evaluateSpeechCompletion(now: now)
                if self.isStopped || self.isFinalizingSpeech {
                    break
                }
            } else if self.vadSpeechDidEnd {
                // 咳払い・環境音などで文字認識結果が空のまま1.2秒経過した場合はフラグをリセット
                if let endTime = self.vadSpeechEndTime, now.timeIntervalSince(endTime) > 1.2 {
                    self.vadSpeechDidEnd = false
                    self.vadSpeechEndTime = nil
                }
            }
        }
    }
}

// MARK: - iOS 26+ 専用 SpeechAnalyzer & SpeechTranscriber バックエンド
@available(iOS 26.0, *)
private final class ModernSpeechBackend: @unchecked Sendable {
    private var speechAnalyzer: SpeechAnalyzer?
    private var speechTranscriber: SpeechTranscriber?
    private var analyzerFormat: AVAudioFormat?
    private var formatConverter: AVAudioConverter?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    
    private let lock = NSLock()
    private var finalizedTranscript: String = ""
    
    func start(onTranscript: @escaping @Sendable (String, Bool) -> Void) async throws {
        guard SpeechTranscriber.isAvailable else {
            throw NSError(domain: "ModernSpeechBackend", code: -10, userInfo: [NSLocalizedDescriptionKey: "SpeechTranscriber is not available"])
        }
        
        let requestedLocale = Locale(identifier: "ja-JP")
        let resolvedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) ?? requestedLocale
        
        // リアルタイムの途中結果（volatileResults / fastResults）をテキスト欄へ即座に表示するため progressiveTranscription を使用
        let transcriber = SpeechTranscriber(locale: resolvedLocale, preset: .progressiveTranscription)
        
        // 重要: アセットが .installed でない場合（.supported / .downloading / .unsupported）、
        // prepareToAnalyze がハングしたり認識結果が空になるため、バックグラウンドで取得要求のみ出して SFSpeechRecognizer へ即フォールバックする
        let assetStatus = await AssetInventory.status(forModules: [transcriber])
        guard assetStatus == .installed else {
            if assetStatus == .supported {
                Task.detached(priority: .utility) {
                    if let req = try? await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                        try? await req.downloadAndInstall()
                    }
                }
            }
            throw NSError(
                domain: "ModernSpeechBackend",
                code: -11,
                userInfo: [NSLocalizedDescriptionKey: "SpeechTranscriber locale asset is not installed yet (status: \(assetStatus))"]
            )
        }
        
        // SpeechAnalyzerが要求するオーディオフォーマット（16kHz Mono Int16等）を取得して事前準備
        guard let bestFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw NSError(domain: "ModernSpeechBackend", code: -12, userInfo: [NSLocalizedDescriptionKey: "No compatible audio format for SpeechTranscriber"])
        }
        self.analyzerFormat = bestFormat
        
        if let float32Format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
           float32Format != bestFormat {
            self.formatConverter = AVAudioConverter(from: float32Format, to: bestFormat)
        }
        
        self.speechTranscriber = transcriber
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.speechAnalyzer = analyzer
        
        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
        self.continuation = cont
        
        try await analyzer.prepareToAnalyze(in: bestFormat)
        try await analyzer.start(inputSequence: stream)
        
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard !Task.isCancelled, let self = self else { break }
                    let segmentText = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    let isSegmentFinal = result.isFinal
                    
                    let combined: String = self.lock.withLock {
                        if isSegmentFinal {
                            if !segmentText.isEmpty {
                                let cleanPrefix = self.finalizedTranscript.hasSuffix("。")
                                    ? String(self.finalizedTranscript.dropLast())
                                    : self.finalizedTranscript
                                if !cleanPrefix.isEmpty && segmentText.hasPrefix(cleanPrefix) {
                                    self.finalizedTranscript = segmentText
                                } else if !self.finalizedTranscript.hasSuffix(segmentText) {
                                    self.finalizedTranscript = cleanPrefix + segmentText
                                }
                            }
                            return self.finalizedTranscript
                        } else {
                            let cleanPrefix = self.finalizedTranscript.hasSuffix("。")
                                ? String(self.finalizedTranscript.dropLast())
                                : self.finalizedTranscript
                            if !cleanPrefix.isEmpty && segmentText.hasPrefix(cleanPrefix) {
                                return segmentText
                            }
                            return cleanPrefix + segmentText
                        }
                    }
                    
                    let trimmed = combined.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        // SpeechTranscriber の result.isFinal は部分セグメント（「どういた」等）の確定を意味するため、
                        // ストリーミング中は発話全体の完了(true)として扱わず、後続の語尾（「しまして」等）の認識を継続させる
                        onTranscript(trimmed, false)
                    }
                }
            } catch {
                print("[ModernSpeechBackend] Error in transcriber results: \(error)")
            }
        }
    }
    
    func resetTranscript() {
        lock.withLock {
            finalizedTranscript = ""
        }
    }
    
    func feed(float32Buffer: AVAudioPCMBuffer) {
        guard let targetFormat = analyzerFormat else { return }
        
        if float32Buffer.format == targetFormat {
            continuation?.yield(AnalyzerInput(buffer: float32Buffer))
            return
        }
        
        guard let converter = formatConverter else { return }
        let ratio = targetFormat.sampleRate / float32Buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(float32Buffer.frameLength) * ratio) + 32
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
        
        var error: NSError?
        nonisolated(unsafe) var didProvide = false
        converter.convert(to: outBuffer, error: &error) { _, outStatus in
            if !didProvide {
                didProvide = true
                outStatus.pointee = .haveData
                return float32Buffer
            } else {
                outStatus.pointee = .noDataNow
                return nil
            }
        }
        
        if error == nil && outBuffer.frameLength > 0 {
            continuation?.yield(AnalyzerInput(buffer: outBuffer))
        }
    }
    
    /// 入力ストリームを閉じ、SpeechAnalyzer 内の未確定バッファを最後までフラッシュして確定させる
    func finalize(completion: @escaping @Sendable () -> Void) {
        continuation?.finish()
        continuation = nil
        let analyzer = speechAnalyzer
        let task = resultsTask
        Task {
            try? await analyzer?.finalizeAndFinishThroughEndOfInput()
            _ = await task?.value
            completion()
        }
    }
    
    func stop() {
        resultsTask?.cancel()
        resultsTask = nil
        continuation?.finish()
        continuation = nil
        
        let analyzer = speechAnalyzer
        speechAnalyzer = nil
        speechTranscriber = nil
        formatConverter = nil
        analyzerFormat = nil
        resetTranscript()
        
        Task {
            await analyzer?.cancelAndFinishNow()
        }
    }
}
