import Foundation
import IrodoriTTS

/// 日本語および多言語のテキストを、音声合成に適した1文単位に分割するユーティリティ
public struct SentenceSplitter {

    /// 選択した方式で合成するテキストを用意する。全文モードでは文や長さで分割しない。
    public static func chunks(text: String, mode: TTSSynthesisMode) -> [String] {
        switch mode {
        case .perSentence:
            return coalescingShortSentences(split(text: text))
        case .wholeResponse:
            let sanitized = SpeechText.markdown(text).trimmingCharacters(in: .whitespacesAndNewlines)
            return containsSpeakableCharacters(sanitized) ? [sanitized] : []
        }
    }

    /// At most two short sentences (each <=24 characters, <=48 including the
    /// separator). Never absorb a long sentence or a comma/ellipsis fragment.
    /// The small cap bounds the extra first-chunk latency and PCM lookahead;
    /// whole-response mode and the low-level sentence splitter are unchanged.
    private static func coalescingShortSentences(_ sentences: [String]) -> [String] {
        var chunks: [String] = []
        var index = 0
        while index < sentences.count {
            let first = sentences[index]
            if index + 1 < sentences.count,
               first.count <= 24, sentences[index + 1].count <= 24,
               first.count + 1 + sentences[index + 1].count <= 48,
               let last = first.last, "。！？!?".contains(last),
               let nextLast = sentences[index + 1].last, !"…‥、,".contains(nextLast) {
                // Keep a separator for English/newline-delimited text; keep
                // all original punctuation so the TTS retains natural pauses.
                chunks.append(first + " " + sentences[index + 1])
                index += 2
            } else {
                chunks.append(first)
                index += 1
            }
        }
        return chunks
    }
    
    /// テキストを1文単位の配列に分割する
    /// - Parameters:
    ///   - text: 入力テキスト（LLMの応答テキスト等）
    ///   - maxSentenceLength: 句点がない長文を読点で分割する閾値文字数（デフォルト70文字）
    /// - Returns: 分割された文の配列
    public static func split(text: String, maxSentenceLength: Int = 70) -> [String] {
        // 1. マークダウン記法の除去・整形（コードブロックやリンク表記の読み上げ化）
        let sanitized = SpeechText.markdown(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty else { return [] }
        
        var sentences: [String] = []
        var current = ""
        let chars = Array(sanitized)
        let count = chars.count
        var i = 0
        
        func isPunctuationEnd(_ c: Character) -> Bool {
            return c == "。" || c == "！" || c == "!" || c == "？" || c == "?" || c == "\n"
        }
        
        func isSecondaryBreak(_ c: Character) -> Bool {
            return c == "、" || c == "," || c == " " || c == "　"
        }
        
        while i < count {
            let c = chars[i]
            current.append(c)
            
            if isPunctuationEnd(c) {
                // 連続する終端記号（例: 「！？」や「！！！」、改行）を同じ文末にまとめる
                while i + 1 < count && isPunctuationEnd(chars[i + 1]) {
                    i += 1
                    current.append(chars[i])
                }
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if containsSpeakableCharacters(trimmed) {
                    sentences.append(trimmed)
                }
                current = ""
            } else if c == "…" || c == "‥" {
                // 連続する三点リーダーをまとめる
                while i + 1 < count && (chars[i + 1] == "…" || chars[i + 1] == "‥") {
                    i += 1
                    current.append(chars[i])
                }
                // 次が終端記号でなければ、余韻としての区切りとみなす
                if i + 1 < count && !isPunctuationEnd(chars[i + 1]) {
                    let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                    if containsSpeakableCharacters(trimmed) {
                        sentences.append(trimmed)
                    }
                    current = ""
                }
            } else if current.count >= maxSentenceLength && isSecondaryBreak(c) {
                // 句点がないまま一定文字数を超えた場合は読点で安全に分割
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if containsSpeakableCharacters(trimmed) {
                    sentences.append(trimmed)
                }
                current = ""
            }
            
            i += 1
        }
        
        let remaining = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if containsSpeakableCharacters(remaining) {
            sentences.append(remaining)
        }
        
        return sentences
    }
    
    /// 音声合成エンジンで発話可能な文字（ひらがな、カタカナ、漢字、英数字）が含まれているか判定
    public static func containsSpeakableCharacters(_ text: String) -> Bool {
        return text.range(
            of: #"[A-Za-z0-9\u3040-\u30ff\u3400-\u9fff\uff10-\uff19\uff21-\uff3a\uff41-\uff5a\uff66-\uff9f]"#,
            options: .regularExpression
        ) != nil
    }
}
