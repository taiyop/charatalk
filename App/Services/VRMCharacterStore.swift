import Foundation

/// 一覧に並ぶVRMキャラクター1件。
/// VRMファイル本体はコピーせず、ユーザーが選んだ場所をブックマークで覚えておく。
public struct VRMCharacterEntry: Codable, Identifiable, Equatable, Sendable {
    public static let builtInID = UUID(uuidString: "00000000-0000-0000-0000-00000000C0DE")!

    public let id: UUID
    public var name: String
    /// 選んだファイルのブックマーク。同梱アバターは nil。
    public var bookmark: Data?
    /// 一覧に表示するファイル名（ブックマークが解決できないときの手がかり）
    public var fileName: String?
    public var addedAt: Date
    public var lastOpenedAt: Date?

    public var isBuiltIn: Bool { id == Self.builtInID }

    public init(id: UUID = UUID(), name: String, bookmark: Data?, fileName: String?, addedAt: Date = Date(), lastOpenedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.bookmark = bookmark
        self.fileName = fileName
        self.addedAt = addedAt
        self.lastOpenedAt = lastOpenedAt
    }

    public static func builtIn(addedAt: Date = .distantPast) -> VRMCharacterEntry {
        VRMCharacterEntry(id: builtInID, name: "vrm_sample", bookmark: nil, fileName: nil, addedAt: addedAt)
    }
}

/// キャラクター一覧の永続化（JSON）と並び順。UI・RealityKitに依存しない。
public struct VRMCharacterStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("VRMCharacters", isDirectory: true)
    }

    var listURL: URL { directory.appendingPathComponent("characters.json") }
    var thumbnailDirectory: URL { directory.appendingPathComponent("Thumbnails", isDirectory: true) }

    public func thumbnailURL(for id: UUID) -> URL {
        thumbnailDirectory.appendingPathComponent("\(id.uuidString).jpg")
    }

    /// 保存済みの一覧。同梱アバターは常に含まれる。
    public func load() -> [VRMCharacterEntry] {
        let saved = (try? Data(contentsOf: listURL))
            .flatMap { try? JSONDecoder().decode([VRMCharacterEntry].self, from: $0) } ?? []
        return Self.ensuringBuiltIn(saved)
    }

    public func save(_ entries: [VRMCharacterEntry]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: listURL, options: .atomic)
    }

    public func saveThumbnail(_ jpeg: Data, for id: UUID) throws {
        try FileManager.default.createDirectory(at: thumbnailDirectory, withIntermediateDirectories: true)
        try jpeg.write(to: thumbnailURL(for: id), options: .atomic)
    }

    public func removeThumbnail(for id: UUID) {
        try? FileManager.default.removeItem(at: thumbnailURL(for: id))
    }

    static func ensuringBuiltIn(_ entries: [VRMCharacterEntry]) -> [VRMCharacterEntry] {
        var unique: [VRMCharacterEntry] = []
        for entry in entries where !unique.contains(where: { $0.id == entry.id }) {
            unique.append(entry)
        }
        if !unique.contains(where: \.isBuiltIn) {
            unique.append(.builtIn())
        }
        return unique
    }

    /// 最近開いた順。一度も開いていないものは追加が新しい順で後ろに並ぶ。
    public static func sorted(_ entries: [VRMCharacterEntry]) -> [VRMCharacterEntry] {
        entries.sorted { lhs, rhs in
            switch (lhs.lastOpenedAt, rhs.lastOpenedAt) {
            case let (l?, r?): return l > r
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return lhs.addedAt > rhs.addedAt
            }
        }
    }
}
