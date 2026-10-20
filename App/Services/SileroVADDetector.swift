import Foundation
import Accelerate

/// Silero VAD 互換の高性能・低遅延 音声区間検出器（Voice Activity Detector）
/// 16kHz mono の音声チャンク（512サンプル ≈ 32ms）を順次解析し、
/// 人間の発話区間と無音・環境ノイズを高精度に識別してターンテイク（発話完了）を判定します。
public final class SileroVADDetector {
    // MARK: - 設定パラメータ
    public var speechThreshold: Float = 0.48          // 発話判定の確率閾値
    public var silenceThreshold: Float = 0.32         // 無音判定の確率閾値
    public var silenceDurationThreshold: TimeInterval = 0.65 // 発話終了とみなす無音継続時間（秒）
    public var minimumSpeechDuration: TimeInterval = 0.09    // 有効な発話開始とみなす最短時間（秒: 約3チャンク）
    
    // MARK: - 内部状態
    public private(set) var isSpeaking: Bool = false
    public private(set) var currentProbability: Float = 0.0
    
    // サンプル数ベースの正確な経過時間管理（AVAudioEngineのバッファまとめ処理に影響されない）
    private var speechDuration: TimeInterval = 0.0
    private var silenceDuration: TimeInterval = 0.0
    private var transientSpeechInSilenceDuration: TimeInterval = 0.0
    private var warmupChunkCount: Int = 0
    
    // 短時間エネルギー追従用（環境ノイズの適応的学習 & 発話ピーク追跡）
    private var backgroundNoiseEnergy: Float = 0.0025
    private var smoothedEnergy: Float = 0.0025
    private var speechPeakEnergy: Float = 0.0
    
    public init() {}
    
    /// 状態をリセットする
    public func reset() {
        isSpeaking = false
        currentProbability = 0.0
        speechDuration = 0.0
        silenceDuration = 0.0
        transientSpeechInSilenceDuration = 0.0
        warmupChunkCount = 0
        backgroundNoiseEnergy = 0.0025
        smoothedEnergy = 0.0025
        speechPeakEnergy = 0.0
    }
    
    /// 16kHz Mono Floatサンプル（512サンプル推奨）を評価する
    /// - Parameter samples: 音声PCMサンプル（-1.0〜1.0）
    /// - Returns: (発話中フラグ, 発話確率 0.0〜1.0, 発話終了が検知されたか)
    public func process(samples: [Float]) -> (isSpeaking: Bool, probability: Float, speechDidEnd: Bool) {
        guard !samples.isEmpty else {
            return (isSpeaking, 0.0, false)
        }
        
        // チャンクの実時間（512サンプル @ 16kHz = 0.032秒）
        let dt = Double(samples.count) / 16000.0
        
        // 1. RMSエネルギー計算 (Accelerate vDSP)
        var rms: Float = 0.0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
        
        // 2. ゼロ交差率（Zero Crossing Rate: 音声の高周波・子音・母音判定）
        var zeroCrossings = 0
        for i in 1..<samples.count {
            if (samples[i] >= 0 && samples[i - 1] < 0) || (samples[i] < 0 && samples[i - 1] >= 0) {
                zeroCrossings += 1
            }
        }
        let zcr = Float(zeroCrossings) / Float(samples.count)
        
        // 3. 環境ノイズエネルギーの適応的フロアリング
        smoothedEnergy = smoothedEnergy * 0.58 + rms * 0.42
        
        if !isSpeaking && warmupChunkCount < 8 {
            warmupChunkCount += 1
            if rms > 0.0001 && rms < 0.025 {
                backgroundNoiseEnergy = backgroundNoiseEnergy * 0.75 + rms * 0.25
            }
        } else if rms < backgroundNoiseEnergy {
            backgroundNoiseEnergy = backgroundNoiseEnergy * 0.97 + rms * 0.03
        } else if !isSpeaking {
            backgroundNoiseEnergy = backgroundNoiseEnergy * 0.97 + rms * 0.03
        } else if speechPeakEnergy > 0.005 && smoothedEnergy < speechPeakEnergy * 0.25 {
            // 発話中ステータスでもエネルギーが発話ピークの25%未満に落ちている場合は環境ノイズ床を緩やかに追従させデッドロックを防ぐ
            backgroundNoiseEnergy = backgroundNoiseEnergy * 0.98 + rms * 0.02
        }
        backgroundNoiseEnergy = max(0.0002, min(backgroundNoiseEnergy, 0.035))
        
        // 4. SNR（Signal-to-Noise Ratio）と日本語子音・語尾減衰を考慮した発話確率の推論
        let snr = smoothedEnergy / backgroundNoiseEnergy
        // 語尾（「〜しまして」等）は語頭母音ピークより音量が下がるため、ピークの15%未満まで落ち込んだ場合を発話後の環境音とみなす
        let droppedFarBelowSpeechPeak = isSpeaking && speechPeakEnergy > 0.007 && smoothedEnergy < speechPeakEnergy * 0.15
        
        // 人間の声のZCR帯域（低音の母音〜日本語の摩擦音「し・す」等: 約0.004〜0.65）とエネルギーから発話確率（0.0〜1.0）を算出
        var prob: Float = 0.0
        if droppedFarBelowSpeechPeak {
            prob = min(0.25, max(0.0, (smoothedEnergy / max(0.007, speechPeakEnergy)) * 0.8))
        } else if snr > 1.8 && smoothedEnergy > 0.003 {
            let snrFactor = min(1.0, (snr - 1.35) / 3.8)
            let zcrFactor: Float = (zcr >= 0.004 && zcr <= 0.65) ? 1.0 : 0.60
            prob = min(1.0, max(0.0, snrFactor * zcrFactor))
        } else {
            prob = min(0.25, max(0.0, smoothedEnergy * 15.0))
        }
        
        self.currentProbability = prob
        var speechDidEnd = false
        
        // 5. ステートマシン判定（サンプル時間ベース・ヒステリシスデッドゾーンなし）
        if prob >= speechThreshold {
            // 音声検知
            if !isSpeaking {
                speechDuration += dt
                if speechDuration >= minimumSpeechDuration {
                    isSpeaking = true
                    silenceDuration = 0.0
                    transientSpeechInSilenceDuration = 0.0
                    speechPeakEnergy = smoothedEnergy
                }
            } else {
                speechDuration += dt
                if smoothedEnergy > speechPeakEnergy {
                    speechPeakEnergy = speechPeakEnergy * 0.60 + smoothedEnergy * 0.40
                } else {
                    speechPeakEnergy = max(backgroundNoiseEnergy * 2.5, speechPeakEnergy * 0.988)
                }
                
                // 語中の促音・破裂音閉鎖区間（「た」「て」「っ」等の200ms未満の微細無音）からの復帰は即座に無音タイマーをリセットする。
                // 200ms以上の無音が既に続いている場合のみ、単発クリックノイズ（1チャンク=32ms）を除外するため2チャンク（約64ms）の連続音声でリセットする。
                if silenceDuration > 0.0 {
                    if silenceDuration < 0.20 {
                        silenceDuration = 0.0
                        transientSpeechInSilenceDuration = 0.0
                    } else {
                        transientSpeechInSilenceDuration += dt
                        if transientSpeechInSilenceDuration >= 0.06 {
                            silenceDuration = 0.0
                            transientSpeechInSilenceDuration = 0.0
                        }
                    }
                }
            }
        } else {
            // 発話閾値未満（無音または減衰区間）
            if isSpeaking {
                transientSpeechInSilenceDuration = 0.0
                if prob <= silenceThreshold {
                    silenceDuration += dt
                } else {
                    // silenceThreshold〜speechThresholdの中間帯域でもタイマーが停止しないよう進行させる
                    silenceDuration += dt * 0.75
                }
                speechPeakEnergy = max(backgroundNoiseEnergy * 2.0, speechPeakEnergy * 0.988)
                
                // 無音が閾値以上継続した場合、発話終了と判定
                if silenceDuration >= silenceDurationThreshold {
                    speechDidEnd = true
                    isSpeaking = false
                    speechDuration = 0.0
                    silenceDuration = 0.0
                    transientSpeechInSilenceDuration = 0.0
                    speechPeakEnergy = 0.0
                }
            } else {
                speechDuration = max(0.0, speechDuration - dt * 2.0)
            }
        }
        
        return (isSpeaking, prob, speechDidEnd)
    }
}
