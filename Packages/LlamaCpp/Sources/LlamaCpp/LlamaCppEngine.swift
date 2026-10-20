import Foundation
import LlamaCppNative

public actor LlamaCppEngine {
    private let bridge = LlamaCppBridge()
    private var loadedModelPath: String?
    public private(set) var preparedVariant: LFM2ModelVariant?

    public init() {}

    public func prepare(modelFile: URL, variant: LFM2ModelVariant, contextLength: Int = 4096) throws {
        if loadedModelPath == modelFile.path && preparedVariant == variant {
            return
        }

        let info = try bridge.prepareModel(modelFile.path, contextLength: Int32(contextLength))
        self.loadedModelPath = modelFile.path
        self.preparedVariant = variant
    }

    public func generate(
        messages: [[String: String]],
        temperature: Float = 0.3,
        maxTokens: Int = 256,
        onToken: (@Sendable (String) -> Void)? = nil
    ) throws -> String {
        let reply = try bridge.generateChat(
            withMessages: messages,
            temperature: temperature,
            maxTokens: Int32(maxTokens),
            onToken: onToken
        )
        return reply
    }

    public func cancel() {
        bridge.cancel()
    }

    public func release() {
        bridge.releaseModel()
        loadedModelPath = nil
        preparedVariant = nil
    }
}
