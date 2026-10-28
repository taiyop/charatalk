import Foundation

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

@main
struct RetiredLocalLLMCleanupTests {
    static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw TestFailure(description: message) }
    }

    static func withSandbox(_ body: (URL, UserDefaults) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("retired-llm-tests-\(UUID().uuidString)", isDirectory: true)
        let suite = "RetiredLocalLLMCleanupTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try body(root, defaults)
    }

    static func touch(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: url)
    }

    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    static func main() throws {
        let tests: [(String, () throws -> Void)] = [
            ("LFM2.5 models and variant setting are removed, current models are kept", {
                try withSandbox { root, defaults in
                    let retired = root.appendingPathComponent("LFM2Models/LFM2.5-1.2B-JP-Q4_K_M.gguf")
                    let current = root.appendingPathComponent("LocalLLMModels/LFM3-1.7B-Q4_K_M.gguf")
                    try touch(retired)
                    try touch(current)
                    defaults.set("Q4_K_M", forKey: "lfm2ModelVariant")
                    defaults.set("Q4_K_M", forKey: "localLLMModelVariant")

                    let removed = RetiredLocalLLMCleanup.run(applicationSupport: root, defaults: defaults)

                    try expect(removed.map(\.lastPathComponent) == ["LFM2Models"], "unexpected removals: \(removed)")
                    try expect(!exists(retired.deletingLastPathComponent()), "LFM2Models remained")
                    try expect(exists(current), "current model deleted")
                    try expect(defaults.object(forKey: "lfm2ModelVariant") == nil, "retired key remained")
                    try expect(defaults.string(forKey: "localLLMModelVariant") == "Q4_K_M", "current key removed")
                }
            }),
            ("nothing installed is a no-op and repeat runs are safe", {
                try withSandbox { root, defaults in
                    try expect(RetiredLocalLLMCleanup.run(applicationSupport: root, defaults: defaults).isEmpty,
                               "removed something from an empty directory")
                    try touch(root.appendingPathComponent("LFM2Models/a.gguf"))
                    _ = RetiredLocalLLMCleanup.run(applicationSupport: root, defaults: defaults)
                    try expect(RetiredLocalLLMCleanup.run(applicationSupport: root, defaults: defaults).isEmpty,
                               "second run removed something")
                    try expect(exists(root), "Application Support root deleted")
                }
            }),
            ("future entries are honored and paths outside the root are ignored", {
                try withSandbox { root, defaults in
                    let outside = root.deletingLastPathComponent()
                        .appendingPathComponent("retired-llm-outside-\(UUID().uuidString)")
                    try touch(outside)
                    defer { try? FileManager.default.removeItem(at: outside) }
                    let next = root.appendingPathComponent("LocalLLMModels/Old.gguf")
                    try touch(next)
                    let removed = RetiredLocalLLMCleanup.run(
                        applicationSupport: root,
                        paths: ["LocalLLMModels/Old.gguf", "../\(outside.lastPathComponent)", ".", ""],
                        defaultsKeys: [],
                        defaults: defaults
                    )
                    try expect(removed.map(\.lastPathComponent) == ["Old.gguf"], "unexpected removals: \(removed)")
                    try expect(exists(outside), "file outside Application Support deleted")
                    try expect(exists(root.appendingPathComponent("LocalLLMModels")), "parent of retired file deleted")
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
