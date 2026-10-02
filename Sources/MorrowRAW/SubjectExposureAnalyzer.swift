import CoreGraphics

struct SubjectRegionEvidence: Equatable {
    let kind: SemanticRegionKind
    let points: [AdjustmentBrushPoint]
    let confidence: Double
    let coverage: Double
    let medianLuminance: Double
    let highlightLuminance: Double
    let red: Double
    let green: Double
    let blue: Double
    let saturation: Double

    var priorityScore: Double {
        let semanticWeight: Double
        switch kind {
        case .person: semanticWeight = 1.0
        case .skin: semanticWeight = 0.94
        case .vegetation: semanticWeight = 0.62
        case .sky: semanticWeight = 0.1
        }
        return semanticWeight * confidence * (0.65 + min(0.35, coverage * 2))
    }
}

struct SubjectExposureEvidence: Equatable {
    let regions: [SubjectRegionEvidence]
    let subjectPoints: [AdjustmentBrushPoint]
    let backgroundPoints: [AdjustmentBrushPoint]
    let subjectMedianLuminance: Double
    let subjectHighlightLuminance: Double
    let subjectRed: Double
    let subjectGreen: Double
    let subjectBlue: Double
    let subjectSaturation: Double
    let backgroundMedianLuminance: Double
    let backgroundHighlightLuminance: Double
    let subjectCoverage: Double
    let backgroundCoverage: Double
    let confidence: Double
    let subjectRegion: SemanticRegionKind
    let backgroundRegion: SemanticRegionKind?

    var hasReliableSubject: Bool {
        subjectCoverage >= 0.01 && confidence >= 0.45 && !regions.isEmpty
    }

    var colorfulness: Double { subjectSaturation }
}

enum SubjectExposureAnalyzer {
    static func analyze(_ image: CGImage) -> SubjectExposureEvidence? {
        let detected = SemanticMaskAnalyzer.detect(in: image)
        let candidates = detected.filter {
            ($0.kind == .person || $0.kind == .skin || $0.kind == .vegetation) && $0.points.count >= 3
        }
        let background = detected.first(where: { $0.kind == .sky && $0.points.count >= 3 })
        let grid = LinearColorSampleGrid(image: image)
        guard !grid.samples.isEmpty else { return nil }

        let measured = candidates.compactMap { region -> SubjectRegionEvidence? in
            let indices = Set(indices(for: region.points, in: grid))
            guard indices.count >= 8, let values = stats(indices.map { grid.samples[$0] }) else { return nil }
            return SubjectRegionEvidence(kind: region.kind, points: region.points,
                                         confidence: region.confidence,
                                         coverage: Double(indices.count) / Double(grid.samples.count),
                                         medianLuminance: values.median,
                                         highlightLuminance: values.highlight,
                                         red: values.red, green: values.green, blue: values.blue,
                                         saturation: values.saturation)
        }.sorted { $0.priorityScore > $1.priorityScore }
        guard let primary = measured.first else { return nil }

        let selected = measured.filter { $0.priorityScore >= primary.priorityScore * 0.45 }.prefix(3)
        let selectedPointSets = candidates.filter { candidate in
            selected.contains(where: { $0.kind == candidate.kind })
        }.map { Set(indices(for: $0.points, in: grid)) }
        let subjectIndices = selectedPointSets.reduce(into: Set<Int>()) { $0.formUnion($1) }
        guard subjectIndices.count >= 8, let subject = stats(subjectIndices.map { grid.samples[$0] }) else {
            return nil
        }

        let backgroundIndices: Set<Int>
        if let background {
            backgroundIndices = Set(indices(for: background.points, in: grid))
        } else {
            backgroundIndices = Set(grid.samples.indices).subtracting(subjectIndices)
        }
        let safeBackground = backgroundIndices.count >= 8 ? backgroundIndices : Set(grid.samples.indices)
        guard let backgroundValues = stats(safeBackground.map { grid.samples[$0] }) else { return nil }
        let coverage = Double(subjectIndices.count) / Double(grid.samples.count)
        let confidence = min(0.95, max(0.35,
            selected.map(\.confidence).reduce(0, +) / Double(selected.count) * 0.7 +
            min(0.25, coverage * 2) + (background != nil ? 0.08 : 0)))
        return SubjectExposureEvidence(
            regions: Array(selected), subjectPoints: selected.flatMap(\.points),
            backgroundPoints: background?.points ?? [],
            subjectMedianLuminance: subject.median,
            subjectHighlightLuminance: subject.highlight, subjectRed: subject.red,
            subjectGreen: subject.green, subjectBlue: subject.blue,
            subjectSaturation: subject.saturation,
            backgroundMedianLuminance: backgroundValues.median,
            backgroundHighlightLuminance: backgroundValues.highlight,
            subjectCoverage: coverage,
            backgroundCoverage: Double(safeBackground.count) / Double(grid.samples.count),
            confidence: confidence, subjectRegion: primary.kind,
            backgroundRegion: background?.kind)
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

    private static func stats(_ samples: [LinearColorSample]) ->
        (median: Double, highlight: Double, red: Double, green: Double, blue: Double, saturation: Double)? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.map(\.luminance).sorted()
        let count = Double(samples.count)
        return (sorted[sorted.count / 2], sorted[Int(Double(sorted.count - 1) * 0.95)],
                samples.reduce(0) { $0 + $1.red } / count,
                samples.reduce(0) { $0 + $1.green } / count,
                samples.reduce(0) { $0 + $1.blue } / count,
                samples.reduce(0) {
                    $0 + max($1.red, max($1.green, $1.blue)) - min($1.red, min($1.green, $1.blue))
                } / count)
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
            output.append(LinearColorSample(red: red, green: green, blue: blue,
                                            luminance: 0.2126 * red + 0.7152 * green + 0.0722 * blue))
        }
        samples = output
    }
}
