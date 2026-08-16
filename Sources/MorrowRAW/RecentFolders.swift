import Foundation

enum RecentFoldersStore {
    private static let key = "MorrowRAW.recentFolders"
    private static let limit = 20

    static func load(defaults: UserDefaults = .standard) -> [String] {
        ((defaults.array(forKey: key) as? [String]) ?? [])
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    static func remember(_ folder: URL, defaults: UserDefaults = .standard) -> [String] {
        let path = folder.standardizedFileURL.path
        var paths = load(defaults: defaults).filter { $0 != path && FileManager.default.fileExists(atPath: $0) }
        paths.insert(path, at: 0)
        paths = Array(paths.prefix(limit))
        defaults.set(paths, forKey: key)
        return paths
    }
}
