import Foundation
import AVFoundation
import SwiftUI
import IrodoriTTS

public enum VoiceReferenceError: LocalizedError {
    case consentRequired
    case permissionDenied
    case recordingFailed(String)
    case invalidAudio(String)
    case notFound
    
    public var errorDescription: String? {
        switch self {
        case .consentRequired:
            return "声の利用許可（同意トグル）にチェックを入れてください。"
        case .permissionDenied:
            return "マイクへのアクセスが許可されていません。設定アプリからマイクの使用を許可してください。"
        case .recordingFailed(let reason):
            return "録音に失敗しました: \(reason)"
        case .invalidAudio(let reason):
            return "音声の形式が不正です: \(reason)"
        case .notFound:
            return "指定された参照音声が見つかりません。"
        }
    }
}

@MainActor
public final class VoiceReferenceManager: NSObject, ObservableObject, AVAudioPlayerDelegate, AVAudioRecorderDelegate {
    public static let shared = VoiceReferenceManager()
    
    @Published public private(set) var isRecording: Bool = false
    @Published public private(set) var recordingDuration: Double = 0.0
    @Published public private(set) var isPreviewPlaying: Bool = false
    @Published public private(set) var statusMessage: String = ""
    @Published public var errorMessage: String?
    
    private var recorder: AVAudioRecorder?
    private var recordingTimer: Timer?
    private var recordingStartTime: Date?
    private var currentRecordingURL: URL?
    
    private var previewPlayer: AVAudioPlayer?
    private let referencesDirectory: URL
    
    private override init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.referencesDirectory = appSupport.appendingPathComponent("References", isDirectory: true)
        try? FileManager.default.createDirectory(at: referencesDirectory, withIntermediateDirectories: true)
        super.init()
    }
    
    // MARK: - Import Audio File
    
    public func importAudio(from sourceURL: URL) async throws {
        guard AppSettings.shared.voiceConsent else {
            throw VoiceReferenceError.consentRequired
        }
        
        stopPreview()
        
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        
        // 1. ReferenceAudio によるフォーマットおよび長さの事前検証 (別スレッドで実行)
        do {
            _ = try await Task.detached {
                try ReferenceAudio.read(sourceURL)
            }.value
        } catch {
            throw VoiceReferenceError.invalidAudio("3〜10秒程度（0.16〜120秒）のクリアな音声ファイルを選択してください。（\(error.localizedDescription)）")
        }
        
        // 2. References フォルダにコピー
        let ext = sourceURL.pathExtension.isEmpty ? "wav" : sourceURL.pathExtension
        let newFileName = "reference_\(UUID().uuidString).\(ext)"
        let destinationURL = referencesDirectory.appendingPathComponent(newFileName)
        
        // 既存の古いファイルを削除
        cleanExistingReferenceFiles()
        
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        
        AppSettings.shared.referenceAudioFileName = newFileName
        statusMessage = "参照音声を登録しました。"
        
        // エンジン側へ登録反映
        try await SpeechTTSManager.shared.updateReferenceAudio()
    }
    
    // MARK: - Microphone Recording
    
    public func toggleRecording() async throws {
        if isRecording {
            try await stopRecording()
        } else {
            try await startRecording()
        }
    }
    
    public func startRecording() async throws {
        guard AppSettings.shared.voiceConsent else {
            throw VoiceReferenceError.consentRequired
        }
        guard !isRecording else { return }
        
        stopPreview()
        
        // 録音パーミッション確認（Corvelis/irodori-tts-iphone準拠）
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else {
            throw VoiceReferenceError.permissionDenied
        }
        
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
        #endif
        
        let tempURL = referencesDirectory.appendingPathComponent("temp_recording_\(UUID().uuidString).wav")
        self.currentRecordingURL = tempURL
        
        // Irodori TTS推奨: 48,000Hz モノラル 16bit PCM WAV
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        
        recorder = try AVAudioRecorder(url: tempURL, settings: settings)
        recorder?.delegate = self
        
        guard recorder?.record() == true else {
            throw VoiceReferenceError.recordingFailed("録音レコーダーの起動に失敗しました。")
        }
        
        isRecording = true
        recordingStartTime = Date()
        recordingDuration = 0.0
        statusMessage = "録音中… 3〜10秒話して停止してください"
        
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, let start = self.recordingStartTime else { return }
                self.recordingDuration = Date().timeIntervalSince(start)
                
                // 120秒制限で自動停止
                if self.recordingDuration >= 120.0 {
                    try? await self.stopRecording()
                }
            }
        }
        recordingTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    
    public func stopRecording() async throws {
        guard isRecording, let recorder = recorder, let tempURL = currentRecordingURL else { return }
        
        recordingTimer?.invalidate()
        recordingTimer = nil
        recorder.stop()
        self.recorder = nil
        isRecording = false
        
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        
        let duration = recordingDuration
        recordingDuration = 0.0
        
        guard duration >= 0.5 else {
            try? FileManager.default.removeItem(at: tempURL)
            throw VoiceReferenceError.recordingFailed("録音時間が短すぎます。3〜10秒程度発話してください。")
        }
        
        // バリデーション
        do {
            _ = try ReferenceAudio.read(tempURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw VoiceReferenceError.invalidAudio("録音データの検証に失敗しました。（\(error.localizedDescription)）")
        }
        
        // 永続ファイルへリネーム
        let newFileName = "reference_\(UUID().uuidString).wav"
        let finalURL = referencesDirectory.appendingPathComponent(newFileName)
        
        cleanExistingReferenceFiles()
        try FileManager.default.moveItem(at: tempURL, to: finalURL)
        
        AppSettings.shared.referenceAudioFileName = newFileName
        statusMessage = String(format: "録音（%.1f秒）を参照音声として登録しました。", duration)
        
        // エンジン側へ登録反映
        try await SpeechTTSManager.shared.updateReferenceAudio()
    }
    
    // MARK: - Preview Audio
    
    public func togglePreview() {
        if isPreviewPlaying {
            stopPreview()
        } else {
            playPreview()
        }
    }
    
    public func playPreview() {
        guard let url = AppSettings.shared.referenceAudioURL else { return }
        stopPreview()
        
        do {
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.duckOthers])
            try session.setActive(true)
            #endif
            
            previewPlayer = try AVAudioPlayer(contentsOf: url)
            previewPlayer?.delegate = self
            previewPlayer?.play()
            isPreviewPlaying = true
        } catch {
            errorMessage = "試聴の再生に失敗しました: \(error.localizedDescription)"
        }
    }
    
    public func stopPreview() {
        if let player = previewPlayer, player.isPlaying {
            player.stop()
        }
        previewPlayer = nil
        isPreviewPlaying = false
    }
    
    public nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPreviewPlaying = false
        }
    }
    
    // MARK: - Remove Reference
    
    public func deleteReference() async {
        stopPreview()
        cleanExistingReferenceFiles()
        AppSettings.shared.referenceAudioFileName = ""
        statusMessage = "参照音声を解除しました。"
        
        try? await SpeechTTSManager.shared.updateReferenceAudio()
    }
    
    private func cleanExistingReferenceFiles() {
        if let files = try? FileManager.default.contentsOfDirectory(at: referencesDirectory, includingPropertiesForKeys: nil) {
            for file in files {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
