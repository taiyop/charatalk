import Foundation

/// 提供を終了したローカルLLMの後片付け。
/// モデルを入れ替えたら、旧モデルの保存先（Application Support からの相対パス）と設定キーをここに追加する。
enum RetiredLocalLLMCleanup {
    static let retiredPaths = [
        "LFM2Models", // LFM2.5-1.2B-JP
    ]

    static let retiredDefaultsKeys = [
        "lfm2ModelVariant", // LFM2.5-1.2B-JP の量子化選択
    ]

    /// 端末に残っている旧モデルと設定を削除し、削除したパスを返す。
    @discardableResult
    static func run(
        applicationSupport: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
        paths: [String] = retiredPaths,
        defaultsKeys: [String] = retiredDefaultsKeys,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) -> [URL] {
        for key in defaultsKeys {
            defaults.removeObject(forKey: key)
        }
        guard let root = applicationSupport?.standardizedFileURL else { return [] }

        var removed: [URL] = []
        for path in paths {
            let url = root.appendingPathComponent(path).standardizedFileURL
            // 想定外の相対パスで Application Support の外や全体を消さない
            guard url.path.hasPrefix(root.path + "/"), fileManager.fileExists(atPath: url.path) else { continue }
            do {
                try fileManager.removeItem(at: url)
                removed.append(url)
            } catch {
                print("[RetiredLocalLLMCleanup] \(path) を削除できませんでした: \(error.localizedDescription)")
            }
        }
        return removed
    }
}
