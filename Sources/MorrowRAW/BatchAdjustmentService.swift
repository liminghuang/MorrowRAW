import Foundation

final class ProgressUpdateGate: @unchecked Sendable {
    private let lock = NSLock()
    private var lastPublished = Date.distantPast
    private let minimumInterval: TimeInterval

    init(minimumInterval: TimeInterval = 0.05) {
        self.minimumInterval = minimumInterval
    }

    func shouldPublish(completed: Int, total: Int) -> Bool {
        if completed >= total { return true }
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        guard now.timeIntervalSince(lastPublished) >= minimumInterval else { return false }
        lastPublished = now
        return true
    }
}

struct BatchAdjustmentResult {
    let updatedCount: Int
    let failureCount: Int
    let cancelled: Bool

    init(updatedCount: Int, failureCount: Int, cancelled: Bool = false) {
        self.updatedCount = updatedCount
        self.failureCount = failureCount
        self.cancelled = cancelled
    }
}

private final class ConcurrentBatchState: @unchecked Sendable {
    private let lock = NSLock()
    private var next = 0
    private var processed = 0
    private var updated = 0
    private var failures = 0

    func takeNext(total: Int) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard next < total else { return nil }
        defer { next += 1 }
        return next
    }

    func record(success: Bool) -> Int {
        lock.lock()
        defer { lock.unlock() }
        processed += 1
        if success { updated += 1 } else { failures += 1 }
        return processed
    }

    func result(cancelled: Bool) -> BatchAdjustmentResult {
        lock.lock()
        defer { lock.unlock() }
        return BatchAdjustmentResult(updatedCount: updated, failureCount: failures, cancelled: cancelled)
    }
}

final class BatchAdjustmentCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

enum BatchAdjustmentService {
    static func applyPreset(_ preset: BuiltInPreset, to urls: [URL],
                            shouldCancel: @Sendable () -> Bool = { false },
                            onProgress: @Sendable (Int, Int) -> Void = { _, _ in }) -> BatchAdjustmentResult {
        return runConcurrently(urls: urls, shouldCancel: shouldCancel, onProgress: onProgress) { url in
            var adjustments = try loadAdjustments(for: url)
            preset.apply(to: &adjustments)
            try save(adjustments, for: url)
        }
    }

    static func copy(_ source: ImageAdjustments, to urls: [URL],
                     shouldCancel: @Sendable () -> Bool = { false },
                     onProgress: @Sendable (Int, Int) -> Void = { _, _ in }) -> BatchAdjustmentResult {
        return runConcurrently(urls: urls, shouldCancel: shouldCancel, onProgress: onProgress) { url in
            var target = try loadAdjustments(for: url)
            let exif = target.cachedExif
            target = source
            target.cachedExif = exif
            try save(target, for: url)
        }
    }

    private static func runConcurrently(urls: [URL],
                                        shouldCancel: @Sendable () -> Bool,
                                        onProgress: @Sendable (Int, Int) -> Void,
                                        operation: (URL) throws -> Void) -> BatchAdjustmentResult {
        guard !urls.isEmpty else { return BatchAdjustmentResult(updatedCount: 0, failureCount: 0) }
        let state = ConcurrentBatchState()
        let workerCount = min(urls.count, max(1, min(4, ProcessInfo.processInfo.activeProcessorCount)))

        DispatchQueue.concurrentPerform(iterations: workerCount) { _ in
            while !shouldCancel(), let index = state.takeNext(total: urls.count) {
                var success = false
                do {
                    try operation(urls[index])
                    success = true
                } catch {
                    success = false
                }
                let completed = state.record(success: success)
                onProgress(completed, urls.count)
            }
        }
        return state.result(cancelled: shouldCancel())
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
