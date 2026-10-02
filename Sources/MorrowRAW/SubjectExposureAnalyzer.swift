import CoreGraphics

struct SubjectExposureEvidence: Equatable {
    let subjectMedianLuminance: Double
    let subjectHighlightLuminance: Double
    let backgroundMedianLuminance: Double
    let backgroundHighlightLuminance: Double
    let subjectCoverage: Double
    let backgroundCoverage: Double
    let confidence: Double
    let subjectRegion: SemanticRegionKind
    let backgroundRegion: SemanticRegionKind?

    var hasReliableSubject: Bool {
        subjectCoverage >= 0.01 && confidence >= 0.45
    }
}

enum SubjectExposureAnalyzer {
    static func analyze(_ image: CGImage) -> SubjectExposureEvidence? {
        let regions = SemanticMaskAnalyzer.detect(in: image)
        let subject = regions
            .filter { $0.kind == .person || $0.kind == .skin }
            .max { lhs, rhs in
                lhs.confidence * Double(lhs.points.count) < rhs.confidence * Double(rhs.points.count)
            }
        guard let subject, subject.points.count >= 3 else { return nil }

        let background = regions.first(where: { $0.kind == .sky })
        let grid = LinearColorSampleGrid(image: image)
        guard !grid.samples.isEmpty else { return nil }
        let subjectIndices = indices(for: subject.points, in: grid)
        guard subjectIndices.count >= 8 else { return nil }

        var backgroundIndices: Set<Int>
        if let background, background.points.count >= 3 {
            backgroundIndices = Set(indices(for: background.points, in: grid))
        } else {
            backgroundIndices = Set(grid.samples.indices).subtracting(subjectIndices)
        }
        if backgroundIndices.count < 8 {
            backgroundIndices = Set(grid.samples.indices)
        }

        let subjectSamples = subjectIndices.map { grid.samples[$0] }
        let backgroundSamples = backgroundIndices.map { grid.samples[$0] }
        guard let subjectStats = stats(subjectSamples),
              let backgroundStats = stats(backgroundSamples) else { return nil }

        let coverage = Double(subjectIndices.count) / Double(grid.samples.count)
        let backgroundCoverage = Double(backgroundIndices.count) / Double(grid.samples.count)
        let confidence = min(0.95, max(0.35,
            subject.confidence * 0.7 + min(0.25, coverage * 2) +
            (background != nil ? 0.08 : 0)))
        return SubjectExposureEvidence(
            subjectMedianLuminance: subjectStats.median,
            subjectHighlightLuminance: subjectStats.highlight,
            backgroundMedianLuminance: backgroundStats.median,
            backgroundHighlightLuminance: backgroundStats.highlight,
            subjectCoverage: coverage,
            backgroundCoverage: backgroundCoverage,
            confidence: confidence,
            subjectRegion: subject.kind,
            backgroundRegion: background?.kind
        )
    }

    private static func indices(for points: [AdjustmentBrushPoint], in grid: LinearColorSampleGrid) -> [Int] {
        var result = Set<Int>()
        let radius = max(1, min(3, max(grid.width, grid.height) / 96))
        for point in points {
            let centerX = min(grid.width - 1, max(0, Int(point.x * Double(grid.width))))
            let centerY = min(grid.height - 1, max(0, Int((1 - point.y) * Double(grid.height))))
            for y in max(0, centerY - radius)...min(grid.height - 1, centerY + radius) {
                for x in max(0, centerX - radius)...min(grid.width - 1, centerX + radius) {
                    result.insert(y * grid.width + x)
                }
            }
        }
        return Array(result)
    }

    private static func stats(_ samples: [LinearColorSample]) -> (median: Double, highlight: Double)? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.map(\.luminance).sorted()
        let median = sorted[sorted.count / 2]
        let highlight = sorted[Int(Double(sorted.count - 1) * 0.95)]
        return (median, highlight)
    }
}

struct LinearColorSampleGrid {
    let width: Int
    let height: Int
    let samples: [LinearColorSample]

    init(image: CGImage, maxDimension: Int = 256) {
        let scale = min(1, CGFloat(maxDimension) / CGFloat(max(image.width, image.height)))
        width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        let bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let context = CGContext(data: &buffer, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            samples = []
            return
        }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        func linearized(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        var output: [LinearColorSample] = []
        output.reserveCapacity(width * height)
        for offset in stride(from: 0, to: buffer.count, by: 4) {
            guard buffer[offset + 3] > 3 else {
                output.append(LinearColorSample(red: 0, green: 0, blue: 0, luminance: 0))
                continue
            }
            let red = linearized(Double(buffer[offset]) / 255)
            let green = linearized(Double(buffer[offset + 1]) / 255)
            let blue = linearized(Double(buffer[offset + 2]) / 255)
            let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
            output.append(LinearColorSample(red: red, green: green, blue: blue, luminance: luminance))
        }
        samples = output
    }
}
