import CoreImage
import Foundation

enum PhotoDecoderError: LocalizedError, Equatable {
    case unsupportedFormat
    case cannotDecode(URL)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return StudioText.localized("不支援的影像格式", "Unsupported image format")
        case .cannotDecode(let url):
            return StudioText.localized("無法解碼影像：\(url.lastPathComponent)",
                                       "Unable to decode image: \(url.lastPathComponent)")
        }
    }
}

protocol PhotoDecoder {
    func decode(url: URL) throws -> CIImage
    func decodePreview(url: URL, maxDimension: CGFloat) throws -> CIImage
}

extension PhotoDecoder {
    func decodePreview(url: URL, maxDimension: CGFloat) throws -> CIImage {
        try decode(url: url)
    }
}

final class ApplePhotoDecoder: PhotoDecoder {
    private static let decodedCache: NSCache<NSString, CIImage> = {
        let cache = NSCache<NSString, CIImage>()
        cache.countLimit = 8
        // A CIImage can represent a very large RAW. Bound the cache by an
        // estimated RGBA footprint as well as entry count so browsing a
        // high-resolution folder cannot retain several gigabytes of sources.
        cache.totalCostLimit = 512 * 1024 * 1024
        return cache
    }()
    private static let rawExtensions: Set<String> = [
        "arw", "sr2", "srf", "cr2", "cr3", "crw", "nef", "nrw",
        "raf", "rw2", "orf", "pef", "dng"
    ]

    func decode(url: URL) throws -> CIImage {
        let signpostID = MorrowPerformanceLog.begin("RAW decode")
        defer { MorrowPerformanceLog.end("RAW decode", id: signpostID) }
        guard Self.isSupported(url) else { throw PhotoDecoderError.unsupportedFormat }
        let cacheKey = PhotoFileFingerprint.key(for: url) as NSString
        if let cached = Self.decodedCache.object(forKey: cacheKey) {
            return cached
        }

        let decoded: CIImage?
        if Self.isRaw(url) {
            // Core Image selects Apple's RAW decoder for the camera model.
            if let filter = CIFilter(imageURL: url), let output = filter.outputImage,
               !output.extent.isEmpty {
                decoded = output
            } else if let proxy = CIImage(contentsOf: Self.proxyURL(for: url)) {
                decoded = proxy
            } else {
                decoded = nil
            }
        } else if let image = CIImage(contentsOf: url) {
            decoded = image
        } else {
            decoded = nil
        }
        guard let decoded else { throw PhotoDecoderError.cannotDecode(url) }
        Self.decodedCache.setObject(decoded, forKey: cacheKey, cost: Self.estimatedCost(of: decoded))
        return decoded
    }

    private static func estimatedCost(of image: CIImage) -> Int {
        let pixelCount = max(1, image.extent.width * image.extent.height)
        let bytes = min(Double(Int.max), pixelCount * 4)
        return max(1, Int(bytes))
    }

    func decodePreview(url: URL, maxDimension: CGFloat) throws -> CIImage {
        guard Self.isSupported(url) else { throw PhotoDecoderError.unsupportedFormat }
        guard Self.isRaw(url), maxDimension > 0,
              let rawFilter = CIFilter(imageURL: url) as? CIRAWFilter else {
            return try decode(url: url)
        }

        let nativeSize = rawFilter.nativeSize
        let longestEdge = max(nativeSize.width, nativeSize.height)
        if longestEdge > maxDimension {
            rawFilter.scaleFactor = Float(maxDimension / longestEdge)
        }
        rawFilter.isDraftModeEnabled = true
        guard let output = rawFilter.outputImage, !output.extent.isEmpty else {
            return try decode(url: url)
        }
        return output
    }

    private static func isRaw(_ url: URL) -> Bool {
        rawExtensions.contains(url.pathExtension.lowercased())
    }

    private static func isSupported(_ url: URL) -> Bool {
        isRaw(url) || ["jpg", "jpeg", "png", "tif", "tiff", "bmp", "heic"].contains(url.pathExtension.lowercased())
    }

    private static func proxyURL(for imageURL: URL) -> URL {
        imageURL.deletingLastPathComponent()
            .appendingPathComponent("RAW_TEMP")
            .appendingPathComponent(imageURL.lastPathComponent + ".rawpipe.png")
    }
}
