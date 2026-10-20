import Foundation

// Standalone regression harness for the real
// App/ViewModels/ConversationViewModel.swift conversation-turn lifecycle.
//
// The view model is compiled unchanged. Its App service dependencies are
// replaced by Tests/ConversationTurnTestDoubles.swift, and the real
// Sources/IrodoriTTS/SpeechPlaybackPipeline.swift is built into a temporary
// IrodoriTTS module. There is no network, model download, audio device,
// microphone, XCTest target, sleep, or source-text inspection: every
// asynchronous step is settled by an explicit gate.
//
// Compile/run: see Tests/README.md, "Conversation turn lifecycle".
//
// Coverage:
// - stop while the LLM is outstanding discards the late reply and never
//   reaches TTS/audio or overwrites errors
// - reset while the LLM is outstanding leaves only the welcome message
// - a stale reply/error after stop cannot change a newer turn's
//   busy/thinking/status/subtitle state
// - a successful turn reveals the real reply caption when the audio backend
//   reports an actual started event
// - clearing public `isBusy` while audio is still queued no longer blocks the
//   genuine started notification from revealing the caption
// - a started callback for a stopped/invalidated turn cannot update a newer
//   turn's UI

private struct TestFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

private struct StaleLLMError: LocalizedError, Sendable {
    var errorDescription: String? { "古いターンのエラー" }
}

private let welcomeText = "こんにちは！何かお話ししましょう。"

@MainActor
final class TurnTestEnvironment {
    let viewModel: ConversationViewModel
    let settings = AppSettings.shared
    let backend = FakeLLMBackend.shared
    let tts = SpeechTTSManager.shared
    let audio = AudioSpeechPlayer.shared
    let speech = SpeechAnalyzerService.shared

    init() async {
        await backend.reset()
        tts.reset()
        audio.reset()
        speech.reset()
        settings.reset()
        viewModel = ConversationViewModel()
    }

    func tearDown() async {
        viewModel.stopSpeaking(resetVoiceSession: true)
        audio.stop()
        await backend.reset()
        await drainMainActor()
        tts.reset()
        audio.reset()
        speech.reset()
        settings.reset()
    }
}

/// Yields the main actor enough times for work already queued by a released
/// gate to run. This is not a timing device: every path under test settles on
/// an explicit continuation before this is called.
@MainActor
private func drainMainActor(rounds: Int = 64) async {
    for _ in 0..<rounds {
        await Task.yield()
    }
}

/// Polls a main-actor predicate by yielding, not sleeping. The bound only
/// exists so a broken invariant fails instead of hanging the suite.
@MainActor
private func waitUntil(
    _ label: String,
    rounds: Int = 50_000,
    _ predicate: @MainActor () -> Bool
) async throws {
    if predicate() { return }
    for _ in 0..<rounds {
        await Task.yield()
        if predicate() { return }
    }
    throw TestFailure(message: "\(label): condition was not met")
}

@MainActor
private func expect(_ condition: Bool, _ message: String) throws {
    guard condition else { throw TestFailure(message: message) }
}

@main
@MainActor
struct ConversationTurnTests {
    static func main() async {
        let tests: [(String, @MainActor (TurnTestEnvironment) async throws -> Void)] = [
            ("stop while LLM outstanding discards the late reply", stopDiscardsLateReply),
            ("stop while LLM outstanding discards the late error", stopDiscardsLateError),
            ("reset while LLM outstanding leaves only the welcome message", resetKeepsWelcomeOnly),
            ("stale reply after stop cannot change a newer turn", staleReplyCannotChangeNewTurn),
            ("stale error after stop cannot change a newer turn", staleErrorCannotChangeNewTurn),
            ("successful turn reveals the reply caption when playback starts", successfulTurnRevealsCaption),
            ("busy cleared while audio is queued still reveals the caption on start", busyClearedStillRevealsCaption),
            ("invalidated turn's late started callback cannot update newer UI", invalidatedCallbackCannotUpdateNewTurn),
            ("completed turn's late started callback cannot restore speaking state", completedCallbackCannotRestoreSpeaking),
            ("mic enabled while LLM outstanding discards the late reply", micDiscardsLateReply),
        ]

        var failures = 0
        for (name, body) in tests {
            let environment = await TurnTestEnvironment()
            do {
                try await body(environment)
                await environment.tearDown()
                print("PASS \(name)")
            } catch {
                await environment.tearDown()
                failures += 1
                print("FAIL \(name): \(error)")
            }
        }

        if failures > 0 {
            print("\(failures) test(s) failed")
            exit(1)
        }
        print("All tests passed")
    }

    // MARK: - Tests

    /// Stop while the provider is still thinking. The late reply must not be
    /// appended, synthesized, or played, and must not surface an error.
    static func stopDiscardsLateReply(_ env: TurnTestEnvironment) async throws {
        let vm = env.viewModel
        vm.inputText = "最初の質問"
        vm.sendCurrentMessage()
        await env.backend.waitForRequestCount(1)

        try expect(vm.isBusy && vm.isThinking, "turn did not become busy while the LLM was outstanding")
        try expect(vm.messages.count == 2, "user message was not appended")
        try expect(vm.messages.last?.content == "最初の質問", "unexpected last message")

        vm.stopSpeaking()
        try expect(!vm.isBusy && !vm.isThinking && !vm.isSpeaking, "stop did not clear thinking state")
        try expect(vm.statusMessage.isEmpty, "stop did not clear the status message")
        try expect(vm.errorMessage == nil, "stop introduced an error")

        await env.backend.release(0, reply: "遅れて届いた返答")
        await env.backend.waitForFinishedCount(1)
        await drainMainActor()

        try expect(vm.messages.count == 2, "late reply was appended after stop")
        try expect(vm.messages.last?.role == .user, "history gained an assistant reply")
        try expect(vm.subtitleMessage?.id == vm.messages.last?.id, "late reply produced a subtitle")
        try expect(vm.subtitleMessage?.content == "最初の質問", "subtitle changed after stop")
        try expect(env.tts.synthesizeCallCount == 0, "late reply reached TTS")
        try expect(env.audio.playCallCount == 0, "late reply reached audio playback")
        try expect(vm.errorMessage == nil, "late reply surfaced an error")
        try expect(!vm.isBusy && !vm.isThinking && !vm.isSpeaking, "late reply changed busy state")
        try expect(vm.statusMessage.isEmpty, "late reply changed the status message")
    }

    /// Stop while the provider is still thinking, then fail it. The stale
    /// error must not become the visible error.
    static func stopDiscardsLateError(_ env: TurnTestEnvironment) async throws {
        let vm = env.viewModel
        vm.inputText = "失敗する質問"
        vm.sendCurrentMessage()
        await env.backend.waitForRequestCount(1)

        vm.stopSpeaking()
        await env.backend.fail(0, error: StaleLLMError())
        await env.backend.waitForFinishedCount(1)
        await drainMainActor()

        try expect(vm.errorMessage == nil, "stale error overwrote the cleared error")
        try expect(vm.messages.count == 2, "stale error changed the history")
        try expect(env.tts.synthesizeCallCount == 0, "stale error reached TTS")
        try expect(env.audio.playCallCount == 0, "stale error reached audio playback")
        try expect(!vm.isBusy && !vm.isThinking, "stale error changed busy state")
    }

    /// Reset while the provider is still thinking. Only the welcome message
    /// may remain, even after the late reply arrives.
    static func resetKeepsWelcomeOnly(_ env: TurnTestEnvironment) async throws {
        let vm = env.viewModel
        vm.inputText = "リセット前の質問"
        vm.sendCurrentMessage()
        await env.backend.waitForRequestCount(1)

        vm.resetConversation()
        try expect(vm.messages.count == 1, "reset left more than the welcome message")
        try expect(vm.messages.first?.content == welcomeText, "reset lost the welcome message")
        try expect(vm.errorMessage == nil, "reset introduced an error")

        await env.backend.release(0, reply: "リセット後に届いた返答")
        await env.backend.waitForFinishedCount(1)
        await drainMainActor()

        try expect(vm.messages.count == 1, "late reply was appended after reset")
        try expect(vm.messages.first?.content == welcomeText, "late reply replaced the welcome message")
        try expect(vm.subtitleMessage?.id == vm.messages.first?.id, "late reply produced a subtitle after reset")
        try expect(vm.subtitleMessage?.content == welcomeText, "subtitle changed after reset")
        try expect(env.tts.synthesizeCallCount == 0, "late reply reached TTS after reset")
        try expect(env.audio.playCallCount == 0, "late reply reached audio after reset")
        try expect(vm.errorMessage == nil, "late reply surfaced an error after reset")
    }

    /// Stop a turn, start a new one, then let the old reply arrive. The old
    /// reply must not touch the new turn's messages, busy/thinking state,
    /// status, subtitle, or audio pipeline. The new turn must still complete.
    static func staleReplyCannotChangeNewTurn(_ env: TurnTestEnvironment) async throws {
        let vm = env.viewModel
        vm.inputText = "古い質問"
        vm.sendCurrentMessage()
        await env.backend.waitForRequestCount(1)

        vm.stopSpeaking()
        vm.inputText = "新しい質問"
        vm.sendCurrentMessage()
        await env.backend.waitForRequestCount(2)

        try expect(vm.isBusy && vm.isThinking, "new turn is not busy")
        try expect(vm.statusMessage == "返答を考えています…", "new turn status was not set")
        try expect(vm.messages.count == 3, "new turn history is wrong")
        try expect(vm.messages.last?.content == "新しい質問", "new turn lost its user message")

        await env.backend.release(0, reply: "古い返答")
        await env.backend.waitForFinishedCount(1)
        await drainMainActor()

        try expect(vm.messages.count == 3, "stale reply was appended to the new turn")
        try expect(vm.messages.last?.role == .user, "stale reply replaced the new user message")
        try expect(vm.subtitleMessage?.id == vm.messages.last?.id, "stale reply produced a subtitle")
        try expect(vm.subtitleMessage?.content == "新しい質問", "stale reply changed the subtitle")
        try expect(vm.errorMessage == nil, "stale reply surfaced an error")
        try expect(env.tts.synthesizeCallCount == 0, "stale reply reached TTS")
        try expect(env.audio.playCallCount == 0, "stale reply reached audio playback")
        try expect(vm.isBusy && vm.isThinking, "stale reply changed the new turn's state")
        try expect(!vm.isSpeaking, "stale reply marked the new turn as speaking")
        try expect(vm.statusMessage == "返答を考えています…", "stale reply overwrote the new turn status")

        // The new turn must still be able to finish and reveal its caption.
        await env.backend.release(1, reply: "新しい返答")
        await env.audio.waitForPlayRequest(1)
        try expect(vm.messages.last?.content == "新しい返答", "new reply was not appended")
        try expect(vm.subtitleMessage == nil, "new caption was revealed before playback started")

        env.audio.signalPlaybackStarted()
        try expect(vm.subtitleMessage?.content == "新しい返答", "new caption was not revealed")
        env.audio.finishPlayback()
        try await waitUntil("new turn did not finish") { !vm.isBusy }
    }

    /// Stop a turn, start a new one, then fail the old request. The stale
    /// error must not clear the new turn or replace the status.
    static func staleErrorCannotChangeNewTurn(_ env: TurnTestEnvironment) async throws {
        let vm = env.viewModel
        vm.inputText = "古い質問"
        vm.sendCurrentMessage()
        await env.backend.waitForRequestCount(1)

        vm.stopSpeaking()
        vm.inputText = "新しい質問"
        vm.sendCurrentMessage()
        await env.backend.waitForRequestCount(2)

        await env.backend.fail(0, error: StaleLLMError())
        await env.backend.waitForFinishedCount(1)
        await drainMainActor()

        try expect(vm.errorMessage == nil, "stale error overwrote the new turn error")
        try expect(vm.messages.count == 3, "stale error changed the new turn history")
        try expect(vm.messages.last?.content == "新しい質問", "stale error replaced the new user message")
        try expect(vm.isBusy && vm.isThinking, "stale error cleared the new turn's busy state")
        try expect(!vm.isSpeaking, "stale error marked the new turn as speaking")
        try expect(vm.statusMessage == "返答を考えています…", "stale error overwrote the new turn status")
        try expect(vm.subtitleMessage?.id == vm.messages.last?.id, "stale error produced a subtitle")
        try expect(vm.subtitleMessage?.content == "新しい質問", "stale error changed the subtitle")
        try expect(env.tts.synthesizeCallCount == 0, "stale error reached TTS")
        try expect(env.audio.playCallCount == 0, "stale error reached audio playback")

        await env.backend.release(1, reply: "新しい返答")
        await env.audio.waitForPlayRequest(1)
        env.audio.signalPlaybackStarted()
        try expect(vm.subtitleMessage?.content == "新しい返答", "new caption was not revealed after the stale error")
        env.audio.finishPlayback()
        try await waitUntil("new turn did not finish") { !vm.isBusy }
    }

    /// A normal successful turn keeps the caption hidden while audio is still
    /// queued, then reveals the actual reply text on the real started event.
    static func successfulTurnRevealsCaption(_ env: TurnTestEnvironment) async throws {
        let vm = env.viewModel
        vm.inputText = "こんにちは"
        vm.sendCurrentMessage()
        await env.backend.waitForRequestCount(1)

        await env.backend.release(0, reply: "元気です。")
        await env.audio.waitForPlayRequest(1)

        try expect(vm.messages.last?.role == .assistant, "assistant reply was not appended")
        try expect(vm.messages.last?.content == "元気です。", "assistant reply text is wrong")
        try expect(env.tts.synthesizeCallCount == 1, "expected exactly one synthesis")
        try expect(env.audio.playCallCount == 1, "expected exactly one playback request")
        try expect(vm.subtitleMessage == nil, "caption was revealed before playback started")
        try expect(vm.isThinking, "turn stopped thinking before playback started")
        try expect(vm.isBusy && !vm.isSpeaking, "unexpected state before playback started")

        env.audio.signalPlaybackStarted()
        try expect(vm.subtitleMessage?.content == "元気です。", "started event did not reveal the actual caption")
        try expect(vm.isSpeaking, "started event did not mark speaking")
        try expect(!vm.isThinking, "started event did not clear thinking")
        try expect(vm.statusMessage == "お話し中…", "started event did not set the speaking status")

        env.audio.finishPlayback()
        try await waitUntil("turn did not finish") { !vm.isBusy }
        try expect(vm.subtitleMessage?.content == "元気です。", "caption disappeared after playback finished")
        try expect(vm.statusMessage.isEmpty, "status was not cleared after playback finished")
    }

    /// The started guard is intentionally independent of `isBusy`: even if the
    /// public busy flag is cleared while this message's audio is still queued,
    /// the genuine started event must still reveal the caption.
    static func busyClearedStillRevealsCaption(_ env: TurnTestEnvironment) async throws {
        let vm = env.viewModel
        vm.inputText = "ビジー解除の質問"
        vm.sendCurrentMessage()
        await env.backend.waitForRequestCount(1)
        await env.backend.release(0, reply: "ビジーでも話します。")
        await env.audio.waitForPlayRequest(1)

        try expect(vm.subtitleMessage == nil, "caption was revealed before playback started")
        vm.isBusy = false

        env.audio.signalPlaybackStarted()
        try expect(vm.subtitleMessage?.content == "ビジーでも話します。", "cleared isBusy blocked the genuine reveal")
        try expect(vm.isSpeaking, "cleared isBusy blocked the speaking state")
        try expect(vm.statusMessage == "お話し中…", "cleared isBusy blocked the speaking status")

        env.audio.finishPlayback()
        try await waitUntil("turn did not finish") { !vm.isBusy && !vm.isSpeaking && vm.statusMessage.isEmpty }
        try expect(vm.subtitleMessage?.content == "ビジーでも話します。", "caption disappeared after playback finished")
    }

    /// Capture the real started callback of a turn, stop that turn, start a new
    /// turn, and invoke the old callback. The invalidated turn must not reveal
    /// or otherwise change the newer turn's UI.
    static func invalidatedCallbackCannotUpdateNewTurn(_ env: TurnTestEnvironment) async throws {
        let vm = env.viewModel
        vm.inputText = "古いターン"
        vm.sendCurrentMessage()
        await env.backend.waitForRequestCount(1)
        await env.backend.release(0, reply: "古い返答")
        await env.audio.waitForPlayRequest(1)

        guard let oldStarted = env.audio.pendingPlaybackStartedCallback() else {
            throw TestFailure(message: "old playback did not expose a started callback")
        }

        vm.stopSpeaking()
        vm.inputText = "新しいターン"
        vm.sendCurrentMessage()
        await env.backend.waitForRequestCount(2)
        await env.backend.release(1, reply: "新しい返答")
        await env.audio.waitForPlayRequest(2)

        try expect(vm.subtitleMessage == nil, "new caption was revealed before playback started")
        try expect(vm.isThinking, "new turn is not thinking before playback started")
        try expect(vm.statusMessage == "音声を準備しています…", "new turn status is wrong")
        try expect(vm.isBusy && !vm.isSpeaking, "unexpected new turn state")

        oldStarted()
        try expect(vm.subtitleMessage == nil, "invalidated callback revealed a caption")
        try expect(vm.isThinking, "invalidated callback cleared new turn thinking")
        try expect(!vm.isSpeaking, "invalidated callback marked the new turn as speaking")
        try expect(vm.isBusy, "invalidated callback cleared new turn busy")
        try expect(vm.statusMessage == "音声を準備しています…", "invalidated callback overwrote the new turn status")

        env.audio.signalPlaybackStarted()
        try expect(vm.subtitleMessage?.content == "新しい返答", "new caption was not revealed after the stale callback")
        env.audio.finishPlayback()
        try await waitUntil("new turn did not finish") { !vm.isBusy }
    }

    static func completedCallbackCannotRestoreSpeaking(_ env: TurnTestEnvironment) async throws {
        let vm = env.viewModel
        vm.inputText = "完了するターン"
        vm.sendCurrentMessage()
        await env.backend.waitForRequestCount(1)
        await env.backend.release(0, reply: "完了した返答")
        await env.audio.waitForPlayRequest(1)
        guard let lateStarted = env.audio.pendingPlaybackStartedCallback() else {
            throw TestFailure(message: "playback did not expose a started callback")
        }

        env.audio.signalPlaybackStarted()
        env.audio.finishPlayback()
        try await waitUntil("turn did not finish") { !vm.isBusy }

        lateStarted()
        try expect(!vm.isSpeaking && !vm.isThinking && !vm.isBusy, "late start restored completed turn state")
        try expect(vm.statusMessage.isEmpty, "late start restored a completed speaking status")
        try expect(vm.subtitleMessage?.content == "完了した返答", "late start changed the completed subtitle")
    }

    static func micDiscardsLateReply(_ env: TurnTestEnvironment) async throws {
        let vm = env.viewModel
        vm.inputText = "マイク開始前の質問"
        vm.sendCurrentMessage()
        await env.backend.waitForRequestCount(1)

        vm.toggleVoiceListening()
        try await waitUntil("microphone did not start") { env.speech.isListening }
        await env.backend.release(0, reply: "マイク開始後に届いた返答")
        await env.backend.waitForFinishedCount(1)
        await drainMainActor()

        try expect(vm.messages.count == 2, "late reply was appended while listening")
        try expect(env.tts.synthesizeCallCount == 0 && env.audio.playCallCount == 0, "late reply started speech while listening")
        try expect(env.speech.isListening && vm.isVoiceSessionActive, "late reply interrupted the microphone")
        try expect(!vm.isBusy && !vm.isThinking && !vm.isSpeaking, "late reply changed stopped turn state")
    }
}
