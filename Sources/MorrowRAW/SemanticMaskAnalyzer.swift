import CoreGraphics
import CoreVideo
import Vision

enum SemanticRegionKind: String, CaseIterable, Equatable {
    case sky
    case skin
    case vegetation
    case person

    var displayName: String {
        switch self {
        case .sky: return StudioText.localized("天空", "Sky")
        case .skin: return StudioText.localized("皮膚", "Skin")
        case .vegetation: return StudioText.localized("植物", "Vegetation")
        case .person: return StudioText.localized("人物", "Person")
        }
    }
}

struct SemanticRegionSuggestion: Equatable, Identifiable {
    let kind: SemanticRegionKind
    let confidence: Double
    let points: [AdjustmentBrushPoint]

    var id: String { kind.rawValue }
}

enum SemanticMaskAnalyzer {
    static func detect(in image: CGImage) -> [SemanticRegionSuggestion] {
        var results = heuristicRegions(in: image)
        if let personPoints = personPoints(in: image), personPoints.count >= 3 {
            results.append(SemanticRegionSuggestion(kind: .person, confidence: 0.82,
                                                    points: personPoints))
        }
        return results
    }

    private static func heuristicRegions(in image: CGImage) -> [SemanticRegionSuggestion] {
        guard let pixels = SampledPixels(image, width: 32, height: 24) else { return [] }
        var regions: [SemanticRegionKind: [AdjustmentBrushPoint]] = [:]
        var scores: [SemanticRegionKind: Double] = [:]

        for y in 0..<pixels.height {
            for x in 0..<pixels.width {
                let (r, g, b, alpha) = pixels.pixel(x: x, y: y)
                guard alpha > 0.05 else { continue }
                let maxValue = max(r, max(g, b))
                let minValue = min(r, min(g, b))
                let saturation = maxValue - minValue
                let normalizedX = (Double(x) + 0.5) / Double(pixels.width)
                let normalizedY = 1 - (Double(y) + 0.5) / Double(pixels.height)
                let point = AdjustmentBrushPoint(x: normalizedX, y: normalizedY)

                if Double(y) < Double(pixels.height) * 0.48, b > r * 1.05, b > g * 1.01,
                   saturation > 0.04, maxValue > 0.24 {
                    regions[.sky, default: []].append(point)
                    scores[.sky, default: 0] += 1
                }
                if r > g * 1.08, g > b * 1.12, saturation > 0.08,
                   r > 0.22, r < 0.96 {
                    regions[.skin, default: []].append(point)
                    scores[.skin, default: 0] += 1
                }
                if g > r * 1.08, g > b * 1.04, saturation > 0.08,
                   g > 0.16, normalizedY < 0.88 {
                    regions[.vegetation, default: []].append(point)
                    scores[.vegetation, default: 0] += 1
                }
            }
        }

        return SemanticRegionKind.allCases.compactMap { kind -> SemanticRegionSuggestion? in
            guard let points = regions[kind], points.count >= 3 else { return nil }
            let coverage = Double(points.count) / Double(max(1, pixels.width * pixels.height))
            guard coverage >= 0.01 else { return nil }
            return SemanticRegionSuggestion(
                kind: kind,
                confidence: min(0.78, max(0.38, 0.38 + coverage * 2.5)),
                points: points
            )
        }
    }

    private static func personPoints(in image: CGImage) -> [AdjustmentBrushPoint]? {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(cgImage: image)
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let pixelBuffer = request.results?.first?.pixelBuffer else { return nil }
        return maskPoints(pixelBuffer)
    }

    private static func maskPoints(_ buffer: CVPixelBuffer) -> [AdjustmentBrushPoint] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return [] }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let pointer = base.assumingMemoryBound(to: UInt8.self)
        var points: [AdjustmentBrushPoint] = []
        for y in stride(from: 0, to: height, by: max(1, height / 24)) {
            for x in stride(from: 0, to: width, by: max(1, width / 32)) {
                let value = Double(pointer[y * bytesPerRow + x]) / 255
                guard value > 0.55 else { continue }
                points.append(AdjustmentBrushPoint(
                    x: (Double(x) + 0.5) / Double(width),
                    y: 1 - (Double(y) + 0.5) / Double(height)
                ))
            }
        }
        return points
    }
}

private struct SampledPixels {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let data: [UInt8]

    init?(_ image: CGImage, width: Int, height: Int) {
        self.width = width
        self.height = height
        bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let context = CGContext(
            data: &buffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        data = buffer
    }

    func pixel(x: Int, y: Int) -> (Double, Double, Double, Double) {
        let offset = y * bytesPerRow + x * 4
        return (
            Double(data[offset]) / 255,
            Double(data[offset + 1]) / 255,
            Double(data[offset + 2]) / 255,
            Double(data[offset + 3]) / 255
        )
    }
}
