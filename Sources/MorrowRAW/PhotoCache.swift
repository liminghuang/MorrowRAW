import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

actor ThumbnailDecodeGate {
    static let shared = ThumbnailDecodeGate(limit: 2)
    private let limit: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func acquire() async {
        if active < limit {
            active += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            active = max(0, active - 1)
        }
    }
}

enum PhotoFileFingerprint {
    static func key(for url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let stamp = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let size = values?.fileSize ?? 0
        let input = "\(url.path)|\(size)|\(stamp)"
        return SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

final class PhotoThumbnailCache {
    static let shared = PhotoThumbnailCache()

    private let directory: URL
    private let maintenanceQueue = DispatchQueue(
        label: "com.morrow.raw.thumbnail-cache-maintenance",
        qos: .utility
    )
    private let maintenanceLock = NSLock()
    private var lastPrune = Date.distantPast
    private let pruneLimit = 512 * 1024 * 1024
    private let pruneTarget = 384 * 1024 * 1024
    private let memoryCache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = 128
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    private func cost(of image: CGImage) -> Int {
        max(1, image.bytesPerRow * image.height)
    }

    init(fileManager: FileManager = .default) {
        let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        directory = base.appendingPathComponent("MorrowRAW/Thumbnails", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        schedulePrune()
    }

    func image(for url: URL) -> CGImage? {
        let key = PhotoFileFingerprint.key(for: url) as NSString
        if let cached = memoryCache.object(forKey: key) {
            return cached
        }
        let cacheURL = directory.appendingPathComponent(key as String + ".jpg")
        guard let source = CGImageSourceCreateWithURL(cacheURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        memoryCache.setObject(image, forKey: key, cost: cost(of: image))
        return image
    }

    func store(_ image: CGImage, for url: URL) {
        let key = PhotoFileFingerprint.key(for: url) as NSString
        memoryCache.setObject(image, forKey: key, cost: cost(of: image))
        let cacheURL = directory.appendingPathComponent(key as String + ".jpg")
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return }
        try? data.write(to: cacheURL, options: .atomic)
        schedulePrune()
    }

    private func schedulePrune() {
        maintenanceLock.lock()
        let now = Date()
        guard now.timeIntervalSince(lastPrune) > 30 else {
            maintenanceLock.unlock()
            return
        }
        lastPrune = now
        maintenanceLock.unlock()

        maintenanceQueue.async { [weak self] in
            self?.pruneDiskCacheIfNeeded()
        }
    }

    private func pruneDiskCacheIfNeeded() {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var entries: [(url: URL, size: Int, date: Date)] = []
        var total = 0
        for url in files where url.pathExtension == "jpg" {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize,
                  let date = values.contentModificationDate else { continue }
            entries.append((url, size, date))
            total += size
        }
        guard total > pruneLimit else { return }

        for entry in entries.sorted(by: { $0.date < $1.date }) {
            guard total > pruneTarget else { break }
            try? fileManager.removeItem(at: entry.url)
            total -= entry.size
        }
    }
}
