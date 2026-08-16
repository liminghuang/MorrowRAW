import CoreImage
import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageExporterError: LocalizedError {
    case cannotRender
    case cannotCreateDestination
    case cannotFinalize

    var errorDescription: String? {
        switch self {
        case .cannotRender: return "無法產生匯出影像"
        case .cannotCreateDestination: return "無法建立輸出檔案"
        case .cannotFinalize: return "無法完成影像匯出"
        }
    }
}

enum ImageExportFormat {
    case jpeg, png, tiff, bmp

    var type: UTType {
        switch self {
        case .jpeg: return .jpeg
        case .png: return .png
        case .tiff: return .tiff
        case .bmp: return .bmp
        }
    }

    var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .png: return "png"
        case .tiff: return "tiff"
        case .bmp: return "bmp"
        }
    }
}

enum BatchExportNaming: String, CaseIterable, Identifiable, Codable {
    case original = "Original"
    case dateTime = "Date and Time"
    case sequence = "Sequence"

    var id: String { rawValue }
}

enum BatchConflictMode: String, CaseIterable, Identifiable, Codable {
    case appendNumber = "Append Number"
    case overwrite = "Overwrite"

    var id: String { rawValue }
}

struct WatermarkSettings: Codable, Equatable {
    var enabled = false
    var text = "Watermark"
    var fontName = "System"
    var fontSize: CGFloat = 32
    var opacity: CGFloat = 0.8
    var margin: CGFloat = 24
    var position: WatermarkPosition = .bottomRight
    var color: WatermarkColor = .white
}

enum WatermarkPosition: String, CaseIterable, Identifiable, Codable {
    case topLeft = "Top Left"
    case topRight = "Top Right"
    case bottomLeft = "Bottom Left"
    case bottomRight = "Bottom Right"

    var id: String { rawValue }
}

enum WatermarkColor: String, CaseIterable, Identifiable, Codable {
    case white = "White"
    case black = "Black"
    case blue = "Blue"
    case yellow = "Yellow"
    case green = "Green"
    case red = "Red"
    case gray = "Gray"
    case orange = "Orange"

    var id: String { rawValue }

    var nsColor: NSColor {
        switch self {
        case .white: return .white
        case .black: return .black
        case .blue: return .systemBlue
        case .yellow: return .systemYellow
        case .green: return .systemGreen
        case .red: return .systemRed
        case .gray: return .systemGray
        case .orange: return .systemOrange
        }
    }
}

final class ImageExporter {
    private let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.linearSRGB) as Any,
        .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any
    ])

    func exportJPEG(source: CIImage, adjustments: ImageAdjustments,
                    to url: URL, quality: CGFloat = 0.92,
                    maxLongEdge: Int? = nil, sourceURL: URL? = nil,
                    dpi: CGFloat = 300, preserveMetadata: Bool = true) throws {
        try export(source: source, adjustments: adjustments, to: url,
                   format: .jpeg, quality: quality, maxLongEdge: maxLongEdge,
                   sourceURL: sourceURL, dpi: dpi, preserveMetadata: preserveMetadata,
                   watermark: WatermarkSettings())
    }

    func export(source: CIImage, adjustments: ImageAdjustments,
                to url: URL, format: ImageExportFormat,
                quality: CGFloat = 0.92,
                maxLongEdge: Int? = nil,
                sourceURL: URL? = nil,
                dpi: CGFloat = 300,
                preserveMetadata: Bool = true,
                watermark: WatermarkSettings = WatermarkSettings()) throws {
        let output = ImageRenderer.shared.render(source, adjustments: adjustments)
        guard let renderedImage = context.createCGImage(output, from: output.extent) else {
            throw ImageExporterError.cannotRender
        }
        let watermarked = watermark.enabled ? applyWatermark(to: renderedImage, settings: watermark) : renderedImage
        let image = resizedImage(watermarked, maxLongEdge: maxLongEdge)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, format.type.identifier as CFString, 1, nil
        ) else {
            throw ImageExporterError.cannotCreateDestination
        }

        var properties: [String: Any] = [:]
        if preserveMetadata, let sourceURL,
           let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
           let sourceProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
            properties = sourceProperties
        }
        properties[kCGImagePropertyDPIWidth as String] = dpi
        properties[kCGImagePropertyDPIHeight as String] = dpi
        // Geometry has already been normalized by ImageRenderer; prevent
        // viewers from applying the source EXIF rotation a second time.
        properties[kCGImagePropertyOrientation as String] = 1
        if format == .jpeg {
            properties[kCGImageDestinationLossyCompressionQuality as String] = quality
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageExporterError.cannotFinalize
        }
    }

    private func resizedImage(_ image: CGImage, maxLongEdge: Int?) -> CGImage {
        guard let maxLongEdge, maxLongEdge > 0 else { return image }
        let longEdge = max(image.width, image.height)
        guard longEdge > maxLongEdge else { return image }
        let scale = CGFloat(maxLongEdge) / CGFloat(longEdge)
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return image
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    private func applyWatermark(to image: CGImage, settings: WatermarkSettings) -> CGImage {
        let width = image.width
        let height = image.height
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let bitmap = CGContext(data: nil, width: width, height: height,
                                     bitsPerComponent: 8, bytesPerRow: 0,
                                     space: colorSpace,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return image
        }
        bitmap.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard !settings.text.isEmpty else { return bitmap.makeImage() ?? image }

        let font = settings.fontName == "System"
            ? NSFont.systemFont(ofSize: settings.fontSize, weight: .regular)
            : (NSFont(name: settings.fontName, size: settings.fontSize)
                ?? NSFont.systemFont(ofSize: settings.fontSize, weight: .regular))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: settings.color.nsColor.withAlphaComponent(settings.opacity)
        ]
        let text = NSString(string: settings.text)
        let size = text.size(withAttributes: attributes)
        let margin = settings.margin
        let x: CGFloat = settings.position == .topLeft || settings.position == .bottomLeft
            ? margin : CGFloat(width) - size.width - margin
        let y: CGFloat = settings.position == .topLeft || settings.position == .topRight
            ? CGFloat(height) - size.height - margin : margin
        let graphics = NSGraphicsContext(cgContext: bitmap, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        text.draw(at: CGPoint(x: x, y: y), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.makeImage() ?? image
    }
}

final class BatchExportCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

struct BatchExportResult {
    let writtenURLs: [URL]
    let failures: [(URL, Error)]
    let cancelled: Bool
}

private final class BatchExportWorkerState: @unchecked Sendable {
    struct Failure {
        let url: URL
        let error: Error
    }

    private let lock = NSLock()
    private var nextIndex = 0
    private var completed = 0
    private var written: [URL?]
    private var failures: [Failure?]

    init(count: Int) {
        written = Array(repeating: nil, count: count)
        failures = Array(repeating: nil, count: count)
    }

    func takeNext(total: Int) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard nextIndex < total else { return nil }
        defer { nextIndex += 1 }
        return nextIndex
    }

    func record(index: Int, outputURL: URL?, failure: Failure?) -> Int {
        lock.lock()
        defer { lock.unlock() }
        written[index] = outputURL
        failures[index] = failure
        completed += 1
        return completed
    }

    func snapshot(cancelled: Bool) -> BatchExportResult {
        lock.lock()
        defer { lock.unlock() }
        return BatchExportResult(
            writtenURLs: written.compactMap { $0 },
            failures: failures.compactMap { $0 }.map { ($0.url, $0.error) },
            cancelled: cancelled
        )
    }
}

final class ImageBatchExporter {
    private let decoder: PhotoDecoder
    private let exporter: ImageExporter

    init(decoder: PhotoDecoder = ApplePhotoDecoder(), exporter: ImageExporter = ImageExporter()) {
        self.decoder = decoder
        self.exporter = exporter
    }

    func export(urls: [URL], to folder: URL, format: ImageExportFormat,
                quality: CGFloat = 0.92,
                maxLongEdge: Int? = nil,
                dpi: CGFloat = 300, preserveMetadata: Bool = true,
                naming: BatchExportNaming = .original,
                conflict: BatchConflictMode = .appendNumber,
                watermark: WatermarkSettings = WatermarkSettings(),
                onProgress: ((Int, Int) -> Void)? = nil,
                shouldCancel: (() -> Bool)? = nil) throws -> BatchExportResult {
        let signpostID = MorrowPerformanceLog.begin("Batch export")
        defer { MorrowPerformanceLog.end("Batch export", id: signpostID) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard !urls.isEmpty else {
            return BatchExportResult(writtenURLs: [], failures: [], cancelled: false)
        }

        // Reserve output paths before workers start so append-number naming
        // cannot race when two photos finish at nearly the same time.
        var reservedPaths = Set<String>()
        let jobs: [(url: URL, outputURL: URL)] = urls.enumerated().map { index, url in
            let base = baseName(for: url, index: index, naming: naming)
            let output = outputURL(folder: folder, baseName: base, format: format,
                                   conflict: conflict, reservedPaths: &reservedPaths)
            return (url, output)
        }

        let state = BatchExportWorkerState(count: jobs.count)
        let progressLock = NSLock()
        let workerCount = min(jobs.count, max(1, min(2, ProcessInfo.processInfo.activeProcessorCount)))
        DispatchQueue.concurrentPerform(iterations: workerCount) { _ in
            while shouldCancel?() != true, let index = state.takeNext(total: jobs.count) {
                let job = jobs[index]
                autoreleasepool {
                    do {
                        let source = try decoder.decode(url: job.url)
                        var adjustments = ImageAdjustments()
                        let xmlURL = job.url.deletingLastPathComponent()
                            .appendingPathComponent("RAW_TEMP")
                            .appendingPathComponent(job.url.lastPathComponent + ".rawpipe.xml")
                        if FileManager.default.fileExists(atPath: xmlURL.path) {
                            try adjustments.load(from: xmlURL)
                        }
                        try exporter.export(source: source, adjustments: adjustments, to: job.outputURL,
                                            format: format, quality: quality,
                                            maxLongEdge: maxLongEdge, sourceURL: job.url,
                                            dpi: dpi, preserveMetadata: preserveMetadata,
                                            watermark: watermark)
                        let completed = state.record(index: index, outputURL: job.outputURL, failure: nil)
                        if let onProgress {
                            progressLock.lock()
                            onProgress(completed, jobs.count)
                            progressLock.unlock()
                        }
                    } catch {
                        let completed = state.record(
                            index: index, outputURL: nil,
                            failure: BatchExportWorkerState.Failure(url: job.url, error: error)
                        )
                        if let onProgress {
                            progressLock.lock()
                            onProgress(completed, jobs.count)
                            progressLock.unlock()
                        }
                    }
                }
            }
        }
        return state.snapshot(cancelled: shouldCancel?() == true)
    }

    private func outputURL(folder: URL, baseName: String, format: ImageExportFormat,
                           conflict: BatchConflictMode,
                           reservedPaths: inout Set<String>) -> URL {
        let baseURL = folder.appendingPathComponent(baseName + "." + format.fileExtension)
        if conflict == .overwrite {
            reservedPaths.insert(baseURL.path)
            return baseURL
        }
        var index = 0
        while true {
            let suffix = index == 0 ? "" : "_\(index + 1)"
            let candidate = folder.appendingPathComponent(baseName + suffix + "." + format.fileExtension)
            if !FileManager.default.fileExists(atPath: candidate.path), !reservedPaths.contains(candidate.path) {
                reservedPaths.insert(candidate.path)
                return candidate
            }
            index += 1
        }
    }

    private func baseName(for url: URL, index: Int, naming: BatchExportNaming) -> String {
        switch naming {
        case .original:
            return url.deletingPathExtension().lastPathComponent + "_edited"
        case .sequence:
            return String(format: "%04d_edited", index + 1)
        case .dateTime:
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? Date()
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            return formatter.string(from: date) + "_edited"
        }
    }
}
