import Foundation

private struct TestFailure: Error {
    let message: String
}

private enum SampleError: Error, Equatable {
    case expected
}

private actor ContextProbe {
    func context() -> (String?, Int, TimeInterval?) {
        (ConversationPerformance.current?.id, ConversationPerformance.chunkIndex,
         ConversationPerformance.previousPlaybackFinishedAt)
    }
}

@main
@MainActor
struct ConversationPerformanceTests {
    static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw TestFailure(message: message) }
    }

    static func main() async throws {
        let tests: [(String, @MainActor () async throws -> Void)] = [
            ("measurement without a turn preserves results and default context", {
                try expect(ConversationPerformance.current == nil, "unexpected turn context")
                try expect(ConversationPerformance.chunkIndex == -1, "unexpected chunk context")
                try expect(ConversationPerformance.begin("Unscoped phase") == nil, "unscoped interval")
                let value = ConversationPerformance.measure("Unscoped phase") { 42 }
                try expect(value == 42, "sync result changed")
                let asyncValue = await ConversationPerformance.measureAsync("Unscoped async phase") { 43 }
                try expect(asyncValue == 43, "async result changed")
            }),
            ("sync and async failures retain the original error", {
                do {
                    try ConversationPerformance.measure("Failing sync phase") { throw SampleError.expected }
                    throw TestFailure(message: "sync error swallowed")
                } catch SampleError.expected {}
                do {
                    try await ConversationPerformance.measureAsync("Failing async phase") { throw SampleError.expected }
                    throw TestFailure(message: "async error swallowed")
                } catch SampleError.expected {}
            }),
            ("turn and chunk context survive actor hops and inherited tasks", {
                let trace = ConversationPerformance(provider: "gemini", mode: "perSentence")
                let probe = ContextProbe()
                try await ConversationPerformance.$current.withValue(trace) {
                    try await ConversationPerformance.$chunkIndex.withValue(2) {
                        try await ConversationPerformance.$previousPlaybackFinishedAt.withValue(123) {
                            let child = Task { await probe.context() }
                            let context = await child.value
                            try expect(context.0 == trace.id, "turn lost in child/actor")
                            try expect(context.1 == 2, "chunk lost in child/actor")
                            try expect(context.2 == 123, "playback boundary lost")
                            let measured = await ConversationPerformance.measureAsync("Actor hop") {
                                await probe.context()
                            }
                            try expect(measured.0 == trace.id && measured.1 == 2, "async measure lost context")
                        }
                    }
                }
                try expect(ConversationPerformance.current == nil, "turn escaped scope")
                try expect(ConversationPerformance.chunkIndex == -1, "chunk escaped scope")
                try expect(ConversationPerformance.previousPlaybackFinishedAt == nil, "playback boundary escaped scope")
            }),
            ("nested turns restore the outer correlation ID", {
                let outer = ConversationPerformance(provider: "chatGPTSignIn", mode: "perSentence")
                let inner = ConversationPerformance(provider: "gemini", mode: "wholeResponse")
                try expect(outer.id != inner.id, "turn IDs were reused")
                try ConversationPerformance.$current.withValue(outer) {
                    try ConversationPerformance.$current.withValue(inner) {
                        try expect(ConversationPerformance.current?.id == inner.id, "inner turn missing")
                    }
                    try expect(ConversationPerformance.current?.id == outer.id, "outer turn not restored")
                }
            }),
            ("reply-ready context preserves the turn ID and start time", {
                let trace = ConversationPerformance(provider: "gemini", mode: "perSentence")
                let speechTrace = trace.recordingReplyReady()
                try expect(trace.id == speechTrace.id, "reply created a different turn")
                try expect(trace.startedAt == speechTrace.startedAt, "reply reset turn start")
                ConversationPerformance.$current.withValue(speechTrace) {
                    ConversationPerformance.$chunkIndex.withValue(0) {
                        speechTrace.audioStarted()
                    }
                }
            }),
            ("scoped intervals and errors do not alter application results", {
                let trace = ConversationPerformance(provider: "chatGPTSignIn", mode: "perSentence")
                try await ConversationPerformance.$current.withValue(trace) {
                    let interval = ConversationPerformance.begin("Explicit phase")
                    try expect(interval != nil, "scoped interval missing")
                    ConversationPerformance.end("Explicit phase", interval, outcome: .completed)
                    let value = ConversationPerformance.measure("Successful sync phase") { Data([1, 2]) }
                    try expect(value == Data([1, 2]), "scoped sync result changed")
                    do {
                        try await ConversationPerformance.measureAsync("Cancelled async phase") {
                            throw CancellationError()
                        }
                        throw TestFailure(message: "cancellation swallowed")
                    } catch is CancellationError {}
                    try expect(ConversationPerformance.outcome(for: CancellationError()) == .cancelled,
                               "cancellation mislabeled")
                    try expect(ConversationPerformance.outcome(for: SampleError.expected) == .failed,
                               "failure mislabeled")
                    // Unsupported native timing sentinels must not produce invalid metrics.
                    trace.duration("Invalid duration", seconds: -.infinity)
                    trace.duration("Invalid duration", seconds: .nan)
                    trace.value("Invalid ratio", value: .infinity)
                }
            }),
            ("real pipeline tasks inherit one turn and independent chunk contexts", {
                let trace = ConversationPerformance(provider: "gemini", mode: "perSentence")
                var synthIndex = 0
                var events: [SpeechPlaybackPipeline.Event] = []
                try await ConversationPerformance.$current.withValue(trace) {
                    try await SpeechPlaybackPipeline.play(chunks: ["one", "two", "three"], onEvent: {
                        events.append($0)
                    }) { _ in
                        let index = synthIndex
                        synthIndex += 1
                        return try await ConversationPerformance.$chunkIndex.withValue(index) {
                            let context = await ContextProbe().context()
                            try expect(context.0 == trace.id && context.1 == index, "synthesis context incorrect")
                            return Data([UInt8(index)])
                        }
                    } play: { data, index in
                        try ConversationPerformance.$chunkIndex.withValue(index) {
                            try expect(ConversationPerformance.current?.id == trace.id, "playback turn missing")
                            try expect(ConversationPerformance.chunkIndex == index, "playback chunk missing")
                            try expect(data == Data([UInt8(index)]), "playback order changed")
                        }
                    }
                }
                try expect(events.filter { if case .playbackCompleted = $0 { true } else { false } }.count == 3,
                           "instrumented pipeline did not finish")
            })
        ]

        for (name, test) in tests {
            try await test()
            print("PASS: \(name)")
        }
        print("\(tests.count) tests passed")
    }
}
