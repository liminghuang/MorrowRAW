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

    /// Scans on the caller's queue and reports supported files in small batches.
    /// Batching keeps a large folder from scheduling one UI update per file.
    static func scanIncrementally(folder: URL, includeHidden: Bool = false, rawOnly: Bool = false,
                                  batchSize: Int = 32,
                                  onTotal: @Sendable (Int) -> Void = { _ in },
                                  shouldCancel: @Sendable () -> Bool = { false },
                                  onBatch: @Sendable ([URL]) -> Void) -> [URL] {
        let state = includeHidden ? PhotoLibraryState() : PhotoLibraryState.load(folder: folder)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let extensions = rawOnly ? rawExtensions : supportedExtensions
        let candidates = urls.filter { url in
            guard extensions.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else { return false }
            return includeHidden || !state.contains(url)
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        onTotal(candidates.count)

        var found: [URL] = []
        var batch: [URL] = []
        let safeBatchSize = max(1, batchSize)
        for url in candidates {
            if shouldCancel() { break }
            found.append(url)
            batch.append(url)
            if batch.count >= safeBatchSize {
                onBatch(batch)
                batch.removeAll(keepingCapacity: true)
            }
        }
        if !batch.isEmpty { onBatch(batch) }
        return found
    }

    /// Hidden photos remain viewable in "show hidden" mode but are never exportable.
    static func exportable(_ urls: [URL], from folder: URL?) -> [URL] {
        guard let folder else { return urls }
        let state = PhotoLibraryState.load(folder: folder)
        return urls.filter { !state.contains($0) }
    }
}
