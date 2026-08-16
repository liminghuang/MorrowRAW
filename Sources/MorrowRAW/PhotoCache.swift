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

    init(fileManager: FileManager = .default) {
        let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        directory = base.appendingPathComponent("MorrowRAW/Thumbnails", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func image(for url: URL) -> CGImage? {
        let cacheURL = directory.appendingPathComponent(PhotoFileFingerprint.key(for: url) + ".jpg")
        guard let source = CGImageSourceCreateWithURL(cacheURL as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    func store(_ image: CGImage, for url: URL) {
        let cacheURL = directory.appendingPathComponent(PhotoFileFingerprint.key(for: url) + ".jpg")
        guard let destination = CGImageDestinationCreateWithURL(
            cacheURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary)
        _ = CGImageDestinationFinalize(destination)
    }
}
