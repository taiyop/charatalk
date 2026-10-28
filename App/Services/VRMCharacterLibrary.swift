import Foundation
import SwiftUI
import VRMKit
#if canImport(UIKit)
import UIKit
#endif

public enum VRMCharacterOpenError: LocalizedError {
    /// 記録した場所のファイルにアクセスできない（移動・削除・権限切れ・未ダウンロード）
    case fileUnavailable(String)
    /// ファイルは読めたがVRMとして扱えない
    case invalidModel(String)

    public var errorDescription: String? {
        switch self {
        case .fileUnavailable(let detail):
            return "前回選んだ場所のVRMファイルを開けませんでした。ファイルを選び直してください。\n(\(detail))"
        case .invalidModel(let detail):
            return "VRMモデルとして読み込めませんでした。別のファイルを選んでください。\n(\(detail))"
        }
    }
}

/// VRMファイルの場所の記録と読み出し。セキュリティスコープ付きURLを扱うので MainActor の外で実行する。
enum VRMFileAccess {
    struct Loaded: Sendable {
        let vrm: VRM
        let url: URL
        /// ブックマークが古くなっていた／新規に選ばれたときの最新ブックマーク
        let bookmark: Data?
    }

    static var builtInURL: URL? {
        Bundle.main.url(forResource: "default_avatar", withExtension: "vrm")
    }

    static func resolve(_ bookmark: Data) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        do {
            let url = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)
            return (url, isStale)
        } catch {
            throw VRMCharacterOpenError.fileUnavailable(error.localizedDescription)
        }
    }

    /// `makeBookmark` が true なら、アクセス中にブックマークを作り直して返す。
    static func load(from url: URL, makeBookmark: Bool) async throws -> Loaded {
        try await Task.detached(priority: .userInitiated) {
            let secured = url.startAccessingSecurityScopedResource()
            defer { if secured { url.stopAccessingSecurityScopedResource() } }

            let data: Data
            do {
                data = try coordinatedRead(url)
            } catch {
                throw VRMCharacterOpenError.fileUnavailable(error.localizedDescription)
            }
            guard !data.isEmpty else { throw VRMCharacterOpenError.invalidModel("ファイルが空です") }

            let vrm: VRM
            do {
                vrm = try VRM(data: data, rootDirectory: url.deletingLastPathComponent())
            } catch {
                throw VRMCharacterOpenError.invalidModel(error.localizedDescription)
            }
            let bookmark = makeBookmark
                ? try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
                : nil
            return Loaded(vrm: vrm, url: url, bookmark: bookmark)
        }.value
    }

    /// iCloud Drive 等の未ダウンロードファイルも、ファイル調整を通して取得してから読む。
    private static func coordinatedRead(_ url: URL) throws -> Data {
        var coordinationError: NSError?
        var result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator().coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordinationError) { readURL in
            result = Result { try Data(contentsOf: readURL) }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }
}

extension VRM {
    /// モデル自身が名乗る名前（VRM 0.x の title / VRM 1.0 の name）
    var characterName: String? {
        let name: String?
        switch self {
        case .v0(let vrm0): name = vrm0.meta.title
        case .v1(let vrm1): name = vrm1.meta.name
        }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// 最初の画面に並べるVRMキャラクター一覧。
/// ファイルはコピーせず場所（ブックマーク）だけを覚え、タップ1回で開く。開けなければ選び直してもらう。
@available(iOS 18.0, *)
@MainActor
public final class VRMCharacterLibrary: ObservableObject {
    public static let shared = VRMCharacterLibrary()

    @Published public private(set) var entries: [VRMCharacterEntry] = []
    @Published public private(set) var thumbnails: [UUID: UIImage] = [:]
    /// 読み込み中のキャラクター
    @Published public private(set) var openingID: UUID?
    /// 表示中のキャラクター
    @Published public private(set) var activeID: UUID?

    private let store: VRMCharacterStore
    private let controller: VRMCharacterController

    public var activeEntry: VRMCharacterEntry? {
        entries.first { $0.id == activeID }
    }

    init(store: VRMCharacterStore = VRMCharacterStore(directory: VRMCharacterStore.defaultDirectory),
         controller: VRMCharacterController = .shared) {
        self.store = store
        self.controller = controller
        var loaded = store.load()
        if let legacy = Self.migrateLegacyCustomAvatar(into: loaded, store: store) {
            loaded.append(legacy)
            try? store.save(loaded)
        }
        entries = VRMCharacterStore.sorted(loaded)
        for entry in entries {
            if let image = UIImage(contentsOfFile: store.thumbnailURL(for: entry.id).path) {
                thumbnails[entry.id] = image
            }
        }
    }

    /// 旧バージョンが Application Support/CustomVRM にコピーしていたモデルを一覧に引き継ぐ（一覧の初回作成時のみ）。
    private static func migrateLegacyCustomAvatar(into entries: [VRMCharacterEntry], store: VRMCharacterStore) -> VRMCharacterEntry? {
        guard !FileManager.default.fileExists(atPath: store.listURL.path) else { return nil }
        let legacyURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CustomVRM/custom_avatar.vrm")
        guard FileManager.default.fileExists(atPath: legacyURL.path),
              let bookmark = try? legacyURL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else {
            return nil
        }
        return VRMCharacterEntry(name: "カスタムVRM", bookmark: bookmark, fileName: legacyURL.lastPathComponent)
    }

    // MARK: - 開く

    /// 記録した場所から開く。失敗したら `VRMCharacterOpenError` を投げる（呼び出し側でファイルを選び直してもらう）。
    public func open(_ entry: VRMCharacterEntry) async throws {
        try await perform(entry.id) {
            let url: URL
            var isStale = false
            if entry.isBuiltIn {
                guard let builtIn = VRMFileAccess.builtInURL else {
                    throw VRMCharacterOpenError.invalidModel("同梱のVRMモデルが見つかりません")
                }
                url = builtIn
            } else {
                guard let bookmark = entry.bookmark else {
                    throw VRMCharacterOpenError.fileUnavailable("ファイルの場所が記録されていません")
                }
                (url, isStale) = try VRMFileAccess.resolve(bookmark)
            }
            let loaded = try await VRMFileAccess.load(from: url, makeBookmark: isStale)
            try await self.show(loaded)
            self.didOpen(entry.id, bookmark: loaded.bookmark)
        }
    }

    /// ファイルピッカーで選んだVRMを一覧に加えて開く。同じファイルが既にあればそれを開き直す。
    @discardableResult
    public func add(pickedURL: URL) async throws -> VRMCharacterEntry {
        let existing = entries.first { entry in
            guard let bookmark = entry.bookmark, let resolved = try? VRMFileAccess.resolve(bookmark) else { return false }
            return resolved.url.standardizedFileURL.path == pickedURL.standardizedFileURL.path
        }
        if let existing {
            try await relink(existing, to: pickedURL)
            return existing
        }

        let id = UUID()
        var created: VRMCharacterEntry?
        try await perform(id) {
            let loaded = try await VRMFileAccess.load(from: pickedURL, makeBookmark: true)
            guard let bookmark = loaded.bookmark else {
                throw VRMCharacterOpenError.fileUnavailable("ファイルの場所を記録できませんでした")
            }
            let entry = VRMCharacterEntry(
                id: id,
                name: loaded.vrm.characterName ?? pickedURL.deletingPathExtension().lastPathComponent,
                bookmark: bookmark,
                fileName: pickedURL.lastPathComponent
            )
            try await self.show(loaded)
            self.entries.append(entry)
            self.didOpen(id, bookmark: bookmark)
            created = entry
        }
        guard let created else { throw CancellationError() }
        return created
    }

    /// 開けなくなったキャラクターのファイルを選び直す。顔写真と並び順はそのまま。
    public func relink(_ entry: VRMCharacterEntry, to pickedURL: URL) async throws {
        try await perform(entry.id) {
            let loaded = try await VRMFileAccess.load(from: pickedURL, makeBookmark: true)
            guard loaded.bookmark != nil else {
                throw VRMCharacterOpenError.fileUnavailable("ファイルの場所を記録できませんでした")
            }
            try await self.show(loaded)
            self.update(entry.id) { $0.fileName = pickedURL.lastPathComponent }
            self.didOpen(entry.id, bookmark: loaded.bookmark)
        }
    }

    private func perform(_ id: UUID, _ body: () async throws -> Void) async throws {
        // 読み込みは1件ずつ。連打された2件目は何もしない
        guard openingID == nil else { throw CancellationError() }
        openingID = id
        defer { openingID = nil }
        try await body()
    }

    private func show(_ loaded: VRMFileAccess.Loaded) async throws {
        do {
            try await controller.loadAvatar(loaded.vrm)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw VRMCharacterOpenError.invalidModel(error.localizedDescription)
        }
    }

    private func didOpen(_ id: UUID, bookmark: Data?) {
        update(id) { entry in
            if let bookmark { entry.bookmark = bookmark }
            entry.lastOpenedAt = Date()
        }
        activeID = id
        if thumbnails[id] == nil {
            Task { await captureThumbnail(for: id) }
        }
    }

    // MARK: - 編集

    public func remove(_ entry: VRMCharacterEntry) {
        guard !entry.isBuiltIn else { return }
        entries.removeAll { $0.id == entry.id }
        thumbnails[entry.id] = nil
        store.removeThumbnail(for: entry.id)
        persist()
    }

    /// 表示中のキャラクターの顔を撮り直す
    public func captureThumbnail(for id: UUID) async {
        guard activeID == id,
              let image = await controller.captureFaceThumbnail(),
              activeID == id,
              let jpeg = UIImage(cgImage: image).jpegData(compressionQuality: 0.85) else {
            return
        }
        do {
            try store.saveThumbnail(jpeg, for: id)
            thumbnails[id] = UIImage(data: jpeg)
        } catch {
            print("[VRMCharacterLibrary] 顔写真を保存できませんでした: \(error.localizedDescription)")
        }
    }

    private func update(_ id: UUID, _ change: (inout VRMCharacterEntry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        change(&entries[index])
        entries = VRMCharacterStore.sorted(entries)
        persist()
    }

    private func persist() {
        do {
            try store.save(entries)
        } catch {
            print("[VRMCharacterLibrary] 一覧を保存できませんでした: \(error.localizedDescription)")
        }
    }
}
