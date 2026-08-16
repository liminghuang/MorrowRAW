import Foundation

struct BatchAdjustmentResult {
    let updatedCount: Int
    let failureCount: Int
}

enum BatchAdjustmentService {
    static func applyPreset(_ preset: BuiltInPreset, to urls: [URL]) -> BatchAdjustmentResult {
        var updated = 0
        var failures = 0
        for url in urls {
            do {
                var adjustments = try loadAdjustments(for: url)
                preset.apply(to: &adjustments)
                try save(adjustments, for: url)
                updated += 1
            } catch {
                failures += 1
            }
        }
        return BatchAdjustmentResult(updatedCount: updated, failureCount: failures)
    }

    static func copy(_ source: ImageAdjustments, to urls: [URL]) -> BatchAdjustmentResult {
        var updated = 0
        var failures = 0
        for url in urls {
            do {
                var target = try loadAdjustments(for: url)
                let exif = target.cachedExif
                target = source
                target.cachedExif = exif
                try save(target, for: url)
                updated += 1
            } catch {
                failures += 1
            }
        }
        return BatchAdjustmentResult(updatedCount: updated, failureCount: failures)
    }

    private static func loadAdjustments(for url: URL) throws -> ImageAdjustments {
        var adjustments = ImageAdjustments()
        let path = adjustmentURL(for: url)
        if FileManager.default.fileExists(atPath: path.path) {
            try adjustments.load(from: path)
        }
        return adjustments
    }

    private static func save(_ adjustments: ImageAdjustments, for url: URL) throws {
        try adjustments.save(to: adjustmentURL(for: url))
    }

    private static func adjustmentURL(for url: URL) -> URL {
        url.deletingLastPathComponent()
            .appendingPathComponent("RAW_TEMP")
            .appendingPathComponent(url.lastPathComponent + ".rawpipe.xml")
    }
}
