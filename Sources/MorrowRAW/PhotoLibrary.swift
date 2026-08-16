import Foundation

struct PhotoLibrary {
    static let rawExtensions: Set<String> = [
        "arw", "sr2", "srf", "cr2", "cr3", "crw", "nef", "nrw",
        "raf", "rw2", "orf", "pef", "dng"
    ]
    static let supportedExtensions: Set<String> = rawExtensions.union(["jpg", "jpeg", "png", "tif", "tiff", "bmp", "heic"])

    static func scan(folder: URL, includeHidden: Bool = false, rawOnly: Bool = false) -> [URL] {
        let state = includeHidden ? PhotoLibraryState() : PhotoLibraryState.load(folder: folder)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return urls
            .filter {
                let extensions = rawOnly ? rawExtensions : supportedExtensions
                guard extensions.contains($0.pathExtension.lowercased()),
                      let values = try? $0.resourceValues(forKeys: [.isRegularFileKey]) else {
                    return false
                }
                return values.isRegularFile == true && (includeHidden || !state.contains($0))
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Scans on the caller's queue and reports each supported file as soon as it is found.
    /// The caller can use this to keep the UI responsive while a large folder is discovered.
    static func scanIncrementally(folder: URL, includeHidden: Bool = false, rawOnly: Bool = false,
                                  onPhoto: @Sendable (URL) -> Void) -> [URL] {
        let state = includeHidden ? PhotoLibraryState() : PhotoLibraryState.load(folder: folder)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var found: [URL] = []
        for url in urls {
            let extensions = rawOnly ? rawExtensions : supportedExtensions
            guard extensions.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true,
                  includeHidden || !state.contains(url) else { continue }
            found.append(url)
            onPhoto(url)
        }
        return found.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Hidden photos remain viewable in "show hidden" mode but are never exportable.
    static func exportable(_ urls: [URL], from folder: URL?) -> [URL] {
        guard let folder else { return urls }
        let state = PhotoLibraryState.load(folder: folder)
        return urls.filter { !state.contains($0) }
    }
}
