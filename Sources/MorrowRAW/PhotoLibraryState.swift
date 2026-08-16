import Foundation

/// Per-folder, non-destructive visibility state for photos hidden from the filmstrip.
/// The file lives beside the existing RAW_TEMP cache and is intentionally separate from
/// adjustment XML so hiding never changes an edit or the source image.
struct PhotoLibraryState: Codable, Equatable {
    private(set) var hiddenPaths: Set<String> = []

    func contains(_ url: URL) -> Bool {
        hiddenPaths.contains(url.standardizedFileURL.path)
    }

    mutating func hide(_ url: URL) {
        hiddenPaths.insert(url.standardizedFileURL.path)
    }

    mutating func show(_ url: URL) {
        hiddenPaths.remove(url.standardizedFileURL.path)
    }

    static func load(folder: URL) -> PhotoLibraryState {
        let url = stateURL(folder: folder)
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(PhotoLibraryState.self, from: data) else {
            return PhotoLibraryState()
        }
        return state
    }

    func save(folder: URL) throws {
        let directory = folder.appendingPathComponent("RAW_TEMP", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(self)
        try data.write(to: Self.stateURL(folder: folder), options: .atomic)
    }

    private static func stateURL(folder: URL) -> URL {
        folder.appendingPathComponent("RAW_TEMP", isDirectory: true)
            .appendingPathComponent("preview_list.macos.json")
    }
}
