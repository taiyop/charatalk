/// AI応答を音声合成エンジンへ渡す単位。
public enum TTSSynthesisMode: String, CaseIterable, Identifiable, Sendable {
    case perSentence
    case wholeResponse

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .perSentence: return "文ごと"
        case .wholeResponse: return "全文まとめて"
        }
    }
}
