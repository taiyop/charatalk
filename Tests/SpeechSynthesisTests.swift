import Foundation

// Standalone regression harness for App/Models/TTSSynthesisMode.swift and
// App/Services/SentenceSplitter.swift.
//
// `SentenceSplitter` imports the real IrodoriTTS module, so the README command
// compiles Sources/IrodoriTTS/SpeechText.swift into that module instead of
// replacing it with a mock. Checks throw on failure rather than relying on
// `assert`, so they stay active in release builds.

struct TestFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

@main
struct SpeechSynthesisTests {
    // MARK: - Fixtures

    /// Japanese text with three sentence-ending marks. `.wholeResponse` must
    /// keep every sentence and every mark in a single chunk.
    static let japaneseMultipleSentences = "こんにちは。元気ですか？今日はいい天気ですね！"

    /// English punctuation: `.wholeResponse` must not split at `?` or `!`, and
    /// must keep `.` even though the per-sentence splitter only breaks on `!`
    /// and `?`.
    static let englishMultipleSentences = "Hello world. How are you? I am fine!"

    static let textWithNewlines = "こんにちは。\n元気ですか？\n\nありがとう！"

    static let markdownHeading = "# 見出し\n本文です。\n\n## 次の見出し\n続き。"

    static let markdownLink = "詳細は[こちら](https://example.com/path)をご覧ください。"

    static let markdownCodeBlock = """
    前の文です。
    ```swift
    let secret = 42
    print(secret)
    ```
    後の文です。
    """

    static let markdownInlineCode = "コードは`print(1)`です。"

    static let markdownCombined = "## まとめ\n[リンク](https://example.com)と`コード`です。"

    /// Long enough to exceed both the old 600-character speech limit and the
    /// 70-character fallback split threshold. It contains newlines, `、`, and
    /// sentence-ending marks that a splitting implementation would cut on.
    static let longResponse: String = {
        var lines: [String] = (1...180).map { "これは\($0)番目の文です。" }
        lines.append("最後に、区切りの多い長い一文をここに置きます、そのまま全文を読み上げます、分割も切り捨てもしません、終わり。")
        return lines.joined(separator: "\n")
    }()

    /// Inputs with no speakable characters. Markdown would leave an empty or
    /// punctuation-only string, which must still produce no chunks.
    static let unspeakableInputs: [String] = [
        "",
        "   ",
        "\n\t  \n",
        "。。。！？",
        "!!!???",
        "…‥",
        "#$%&*",
        "😀🎉✨",
        "# ",
        "```\nlet value = 1\n```"
    ]

    // MARK: - Assertions

    static func expectTrue(_ label: String, _ condition: Bool) throws {
        guard condition else { throw TestFailure(message: "\(label): condition was false") }
    }

    static func expectEqual<T: Equatable>(_ label: String, _ actual: T, _ expected: T) throws {
        guard actual == expected else {
            throw TestFailure(
                message: "\(label): expected \(String(reflecting: expected)), got \(String(reflecting: actual))"
            )
        }
    }

    static func expectNil<T>(_ label: String, _ actual: T?) throws {
        guard actual == nil else {
            throw TestFailure(message: "\(label): expected nil, got \(String(reflecting: actual!))")
        }
    }

    static func expectContains(_ label: String, _ haystack: String, _ needle: String) throws {
        guard haystack.contains(needle) else {
            throw TestFailure(
                message: "\(label): expected text to contain \(String(reflecting: needle)), got \(String(reflecting: haystack))"
            )
        }
    }

    static func expectDoesNotContain(_ label: String, _ haystack: String, _ needle: String) throws {
        guard !haystack.contains(needle) else {
            throw TestFailure(
                message: "\(label): expected text not to contain \(String(reflecting: needle)), got \(String(reflecting: haystack))"
            )
        }
    }

    static func unwrap<T>(_ value: T?, _ label: String) throws -> T {
        guard let value else { throw TestFailure(message: "\(label): expected a value, got nil") }
        return value
    }

    /// Compile-time proof that the enum is `Sendable` (and usable across the
    /// speaker/actor boundary).
    static func requireSendable<T: Sendable>(_ value: T) -> T { value }

    static func label(for text: String) -> String {
        String(reflecting: String(text.prefix(40)))
    }

    // MARK: - Whole response

    static func testWholeResponseKeepsJapaneseMultipleSentencesTogether() throws {
        let chunks = SentenceSplitter.chunks(text: japaneseMultipleSentences, mode: .wholeResponse)

        try expectEqual("Japanese whole response", chunks, [japaneseMultipleSentences])
        try expectEqual("Japanese whole response count", chunks.count, 1)

        let chunk = try unwrap(chunks.first, "Japanese whole response first chunk")
        try expectContains("Japanese period preserved", chunk, "。")
        try expectContains("Japanese question mark preserved", chunk, "？")
        try expectContains("Japanese exclamation mark preserved", chunk, "！")

        let perSentence = SentenceSplitter.chunks(text: japaneseMultipleSentences, mode: .perSentence)
        try expectTrue("per-sentence splits Japanese text", perSentence.count > 1)
    }

    static func testWholeResponseKeepsEnglishPunctuation() throws {
        let chunks = SentenceSplitter.chunks(text: englishMultipleSentences, mode: .wholeResponse)

        try expectEqual("English whole response", chunks, [englishMultipleSentences])
        try expectEqual("English whole response count", chunks.count, 1)

        let chunk = try unwrap(chunks.first, "English whole response first chunk")
        try expectContains("English period preserved", chunk, ".")
        try expectContains("English question mark preserved", chunk, "?")
        try expectContains("English exclamation mark preserved", chunk, "!")
    }

    static func testWholeResponsePreservesNewlinesAndTrimsOuterWhitespace() throws {
        let chunks = SentenceSplitter.chunks(text: textWithNewlines, mode: .wholeResponse)
        try expectEqual("newlines preserved", chunks, [textWithNewlines])

        let chunk = try unwrap(chunks.first, "newline chunk")
        try expectContains("blank line preserved", chunk, "\n\n")
        try expectContains("first sentence preserved", chunk, "こんにちは。")
        try expectContains("last sentence preserved", chunk, "ありがとう！")

        let padded = " \n\tこんにちは。\n元気ですか？\n  "
        let trimmed = SentenceSplitter.chunks(text: padded, mode: .wholeResponse)
        try expectEqual("outer whitespace trimmed", trimmed, ["こんにちは。\n元気ですか？"])
    }

    static func testWholeResponseRemovesMarkdownLinksHeadingsAndCodeBlocks() throws {
        let heading = SentenceSplitter.chunks(text: markdownHeading, mode: .wholeResponse)
        try expectEqual(
            "heading markers removed",
            heading,
            ["見出し\n本文です。\n\n次の見出し\n続き。"]
        )
        try expectDoesNotContain("heading marker removed", try unwrap(heading.first, "heading chunk"), "#")

        let link = SentenceSplitter.chunks(text: markdownLink, mode: .wholeResponse)
        try expectEqual("link label kept without URL", link, ["詳細はこちらをご覧ください。"])
        try expectDoesNotContain("link URL removed", try unwrap(link.first, "link chunk"), "https://")
        try expectDoesNotContain("link brackets removed", try unwrap(link.first, "link chunk"), "[")

        let codeBlock = SentenceSplitter.chunks(text: markdownCodeBlock, mode: .wholeResponse)
        try expectEqual("code block whole response count", codeBlock.count, 1)
        let codeChunk = try unwrap(codeBlock.first, "code block chunk")
        try expectContains("text before code block kept", codeChunk, "前の文です。")
        try expectContains("text after code block kept", codeChunk, "後の文です。")
        try expectDoesNotContain("code block body removed", codeChunk, "secret")
        try expectDoesNotContain("code block declaration removed", codeChunk, "swift")
        try expectDoesNotContain("code block fence removed", codeChunk, "```")

        let inlineCode = SentenceSplitter.chunks(text: markdownInlineCode, mode: .wholeResponse)
        try expectEqual("inline code backticks removed", inlineCode, ["コードはprint(1)です。"])

        let combined = SentenceSplitter.chunks(text: markdownCombined, mode: .wholeResponse)
        try expectEqual("combined markdown one chunk", combined, ["まとめ\nリンクとコードです。"])
    }

    static func testWholeResponseReturnsEmptyForUnspeakableInput() throws {
        for input in unspeakableInputs {
            let chunks = SentenceSplitter.chunks(text: input, mode: .wholeResponse)
            try expectEqual("unspeakable \(label(for: input))", chunks, [])
        }

        let emojiWithText = SentenceSplitter.chunks(text: "こんにちは😀", mode: .wholeResponse)
        try expectEqual("emoji does not suppress speech", emojiWithText, ["こんにちは😀"])
    }

    static func testWholeResponseKeepsLongResponseIntact() throws {
        try expectTrue("long fixture exceeds 600 characters", longResponse.count > 600)

        let chunks = SentenceSplitter.chunks(text: longResponse, mode: .wholeResponse)
        try expectEqual("long response is one chunk", chunks.count, 1)

        let chunk = try unwrap(chunks.first, "long response chunk")
        try expectEqual("long response has no loss", chunk, longResponse)
        try expectEqual("long response character count", chunk.count, longResponse.count)
        try expectContains("long response prefix", chunk, "これは1番目の文です。")
        try expectContains("long response suffix", chunk, "終わり。")
        try expectContains("long response newline", chunk, "\n")
        try expectContains("long response comma run", chunk, "分割も切り捨てもしません")
    }

    static func testWholeResponseKeepsSingleSentence() throws {
        let samples: [(name: String, text: String)] = [
            ("Japanese without punctuation", "こんにちは"),
            ("Japanese with punctuation", "今日はいい天気ですね。"),
            ("English", "Hello"),
            ("English with punctuation", "Hello!")
        ]

        for sample in samples {
            let chunks = SentenceSplitter.chunks(text: sample.text, mode: .wholeResponse)
            try expectEqual("single sentence \(sample.name)", chunks, [sample.text])
        }
    }

    // MARK: - Per sentence

    static func testPerSentenceMatchesExistingSplit() throws {
        let fixtures = [
            japaneseMultipleSentences,
            englishMultipleSentences,
            textWithNewlines,
            markdownHeading,
            markdownLink,
            markdownCodeBlock,
            markdownInlineCode,
            markdownCombined,
            longResponse,
            "こんにちは",
            "今日はいい天気ですね。",
            "Hello",
            "**強調**と__下線__",
            "これはとても長い文章で、句点がなく、読点だけが続く場合の分割を確認するための入力です。"
        ] + unspeakableInputs

        for input in fixtures {
            let expected = SentenceSplitter.split(text: input)
            let actual = SentenceSplitter.chunks(text: input, mode: .perSentence)
            try expectEqual("per-sentence matches split for \(label(for: input))", actual, expected)
        }

        let split = SentenceSplitter.split(text: japaneseMultipleSentences)
        try expectEqual(
            "per-sentence keeps sentence marks",
            split,
            ["こんにちは。", "元気ですか？", "今日はいい天気ですね！"]
        )
    }

    static func testPerSentenceKeepsExistingLongTextBehaviour() throws {
        let perSentence = SentenceSplitter.chunks(text: longResponse, mode: .perSentence)
        try expectEqual("long per-sentence matches split", perSentence, SentenceSplitter.split(text: longResponse))
        try expectTrue("long per-sentence is split", perSentence.count > 1)
        try expectDoesNotContain("long per-sentence has no markdown fence", perSentence.joined(), "```")

        let firstChunk = String(repeating: "あ", count: 75) + "、"
        let commaSeparated = firstChunk + "続き"
        try expectEqual(
            "per-sentence splits at a comma after 70 characters",
            SentenceSplitter.chunks(text: commaSeparated, mode: .perSentence),
            [firstChunk, "続き"]
        )
        try expectEqual(
            "whole response does not split at the long-text threshold",
            SentenceSplitter.chunks(text: commaSeparated, mode: .wholeResponse),
            [commaSeparated]
        )
    }

    // MARK: - Mode metadata

    static func testModeRawValuesRoundTrip() throws {
        let modes = TTSSynthesisMode.allCases
        try expectEqual("case count", modes.count, 2)
        try expectEqual("declaration order", modes.map(\.rawValue), ["perSentence", "wholeResponse"])

        for mode in modes {
            let roundTripped = TTSSynthesisMode(rawValue: mode.rawValue)
            try expectEqual("raw value round-trip \(mode.rawValue)", roundTripped, mode)
        }

        try expectNil("unknown raw value", TTSSynthesisMode(rawValue: "sentence"))
        try expectNil("empty raw value", TTSSynthesisMode(rawValue: ""))
        try expectNil("hyphenated raw value", TTSSynthesisMode(rawValue: "per-sentence"))
        try expectNil("wrong case raw value", TTSSynthesisMode(rawValue: "PERSENTENCE"))
    }

    static func testModeIdentifiersAndLabels() throws {
        let modes = TTSSynthesisMode.allCases

        let ids = modes.map(\.id)
        try expectEqual("identifiers are unique", Set(ids).count, modes.count)
        for mode in modes {
            try expectTrue("identifier is not empty", !mode.id.isEmpty)
            try expectEqual(
                "identifier has no outer whitespace",
                mode.id,
                mode.id.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            try expectEqual("identifier is stable", mode.id, mode.id)
        }

        let labels = modes.map(\.displayName)
        try expectEqual("labels are unique", Set(labels).count, modes.count)
        for mode in modes {
            try expectTrue("label is not empty", !mode.displayName.isEmpty)
            try expectEqual(
                "label has no outer whitespace",
                mode.displayName,
                mode.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            try expectEqual("label is stable", mode.displayName, mode.displayName)
        }

        for mode in modes {
            _ = requireSendable(mode)
        }
    }

    // MARK: - Runner

    static func main() {
        let tests: [(name: String, body: () throws -> Void)] = [
            ("wholeResponseKeepsJapaneseMultipleSentencesTogether", testWholeResponseKeepsJapaneseMultipleSentencesTogether),
            ("wholeResponseKeepsEnglishPunctuation", testWholeResponseKeepsEnglishPunctuation),
            ("wholeResponsePreservesNewlinesAndTrimsOuterWhitespace", testWholeResponsePreservesNewlinesAndTrimsOuterWhitespace),
            ("wholeResponseRemovesMarkdownLinksHeadingsAndCodeBlocks", testWholeResponseRemovesMarkdownLinksHeadingsAndCodeBlocks),
            ("wholeResponseReturnsEmptyForUnspeakableInput", testWholeResponseReturnsEmptyForUnspeakableInput),
            ("wholeResponseKeepsLongResponseIntact", testWholeResponseKeepsLongResponseIntact),
            ("wholeResponseKeepsSingleSentence", testWholeResponseKeepsSingleSentence),
            ("perSentenceMatchesExistingSplit", testPerSentenceMatchesExistingSplit),
            ("perSentenceKeepsExistingLongTextBehaviour", testPerSentenceKeepsExistingLongTextBehaviour),
            ("modeRawValuesRoundTrip", testModeRawValuesRoundTrip),
            ("modeIdentifiersAndLabels", testModeIdentifiersAndLabels)
        ]

        var failures: [String] = []
        for test in tests {
            do {
                try test.body()
                print("PASS \(test.name)")
            } catch {
                let message = (error as? TestFailure)?.message ?? "unexpected error: \(error)"
                failures.append("\(test.name): \(message)")
                print("FAIL \(test.name): \(message)")
            }
        }

        print("")
        if failures.isEmpty {
            print("\(tests.count) tests passed")
            exit(0)
        }
        print("\(tests.count - failures.count) passed, \(failures.count) failed")
        for failure in failures {
            print("  - \(failure)")
        }
        exit(1)
    }
}
