import Foundation

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

@main
struct VRMCharacterStoreTests {
    static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw TestFailure(description: message) }
    }

    static func withStore(_ body: (VRMCharacterStore) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vrm-character-store-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(VRMCharacterStore(directory: root))
    }

    static func entry(_ name: String, added: TimeInterval, opened: TimeInterval? = nil) -> VRMCharacterEntry {
        VRMCharacterEntry(
            name: name,
            bookmark: Data(name.utf8),
            fileName: "\(name).vrm",
            addedAt: Date(timeIntervalSince1970: added),
            lastOpenedAt: opened.map(Date.init(timeIntervalSince1970:))
        )
    }

    static func main() throws {
        let tests: [(String, () throws -> Void)] = [
            ("a fresh store lists only the built-in avatar", {
                try withStore { store in
                    let entries = store.load()
                    try expect(entries.map(\.id) == [VRMCharacterEntry.builtInID], "unexpected entries: \(entries)")
                    try expect(entries[0].bookmark == nil, "built-in avatar has a bookmark")
                }
            }),
            ("entries round-trip with bookmarks and open dates", {
                try withStore { store in
                    let saved = [entry("A", added: 10, opened: 30), .builtIn()]
                    try store.save(saved)
                    try expect(store.load() == saved, "round trip changed the list")
                }
            }),
            ("built-in avatar is restored and duplicates are dropped", {
                try withStore { store in
                    let a = entry("A", added: 10)
                    try store.save([a, a])
                    let loaded = store.load()
                    try expect(loaded.map(\.id) == [a.id, VRMCharacterEntry.builtInID], "unexpected entries: \(loaded)")
                }
            }),
            ("recently opened first, then unopened by newest addition", {
                let old = entry("old", added: 1, opened: 100)
                let recent = entry("recent", added: 2, opened: 200)
                let newUnopened = entry("new", added: 50)
                let builtIn = VRMCharacterEntry.builtIn()
                let sorted = VRMCharacterStore.sorted([builtIn, old, newUnopened, recent])
                try expect(sorted.map(\.name) == ["recent", "old", "new", "vrm_sample"], "order: \(sorted.map(\.name))")
            }),
            ("thumbnails are saved per character and removable", {
                try withStore { store in
                    let id = UUID()
                    try store.saveThumbnail(Data([0xFF, 0xD8]), for: id)
                    try expect(FileManager.default.fileExists(atPath: store.thumbnailURL(for: id).path), "thumbnail missing")
                    store.removeThumbnail(for: id)
                    try expect(!FileManager.default.fileExists(atPath: store.thumbnailURL(for: id).path), "thumbnail remained")
                }
            }),
            ("an unreadable list falls back to the built-in avatar", {
                try withStore { store in
                    try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
                    try Data("not json".utf8).write(to: store.directory.appendingPathComponent("characters.json"))
                    try expect(store.load().map(\.id) == [VRMCharacterEntry.builtInID], "broken list not recovered")
                }
            }),
        ]
        for (name, test) in tests {
            try test()
            print("PASS: \(name)")
        }
        print("\(tests.count) tests passed")
    }
}
