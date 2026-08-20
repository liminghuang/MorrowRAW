import CoreGraphics

struct ColorCheckerSample: Equatable {
    let measured: SIMD3<Double>
    let reference: SIMD3<Double>
}

struct ColorCheckerProfile: Equatable {
    static let identityMatrix = [1.0, 0.0, 0.0,
                                 0.0, 1.0, 0.0,
                                 0.0, 0.0, 1.0]

    var cameraIdentifier = ""
    var illuminant = "Unknown"
    var matrix = identityMatrix
    var sampleCount = 0

    var isIdentity: Bool {
        matrix.count == 9 && zip(matrix, Self.identityMatrix).allSatisfy {
            abs($0 - $1) < 0.000001
        }
    }

    static func calibrate(samples: [ColorCheckerSample], cameraIdentifier: String = "",
                          illuminant: String = "Unknown") -> ColorCheckerProfile? {
        guard samples.count >= 3 else { return nil }
        let normal = samples.reduce(into: Array(repeating: 0.0, count: 9)) { result, sample in
            let values = [sample.measured.x, sample.measured.y, sample.measured.z]
            for row in 0..<3 {
                for column in 0..<3 {
                    result[row * 3 + column] += values[row] * values[column]
                }
            }
        }
        var matrix = Array(repeating: 0.0, count: 9)
        for channel in 0..<3 {
            var right = samples.reduce(into: Array(repeating: 0.0, count: 3)) { result, sample in
                let target = [sample.reference.x, sample.reference.y, sample.reference.z][channel]
                result[0] += sample.measured.x * target
                result[1] += sample.measured.y * target
                result[2] += sample.measured.z * target
            }
            guard let solution = solve3x3(normal, &right) else { return nil }
            for component in 0..<3 {
                matrix[channel * 3 + component] = solution[component]
            }
        }
        return ColorCheckerProfile(cameraIdentifier: cameraIdentifier,
                                   illuminant: illuminant,
                                   matrix: matrix,
                                   sampleCount: samples.count)
    }

    static func sampleRGB(from image: CGImage, normalizedPoint: CGPoint,
                          radius: CGFloat = 0.018) -> SIMD3<Double>? {
        let width = 256
        let height = max(1, Int((Double(image.height) * Double(width) / Double(max(1, image.width))).rounded()))
        let bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let context = CGContext(data: &buffer, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let centerX = min(width - 1, max(0, Int(normalizedPoint.x * CGFloat(width))))
        let centerY = min(height - 1, max(0, Int((1 - normalizedPoint.y) * CGFloat(height))))
        let radiusX = max(1, Int(radius * CGFloat(width)))
        let radiusY = max(1, Int(radius * CGFloat(height)))
        var total = SIMD3<Double>(repeating: 0)
        var count = 0.0
        for y in max(0, centerY - radiusY)...min(height - 1, centerY + radiusY) {
            for x in max(0, centerX - radiusX)...min(width - 1, centerX + radiusX) {
                let offset = y * bytesPerRow + x * 4
                let alpha = Double(buffer[offset + 3]) / 255
                guard alpha > 0.01 else { continue }
                total += SIMD3(Double(buffer[offset]) / 255,
                               Double(buffer[offset + 1]) / 255,
                               Double(buffer[offset + 2]) / 255)
                count += 1
            }
        }
        guard count > 0 else { return nil }
        return total / count
    }

    /// Approximate sRGB targets for the 24-patch ColorChecker Classic chart.
    /// The profile is intended to be refined by the captured samples, not used
    /// as a substitute for a manufacturer-specific camera profile.
    static let classicReferenceRGB: [SIMD3<Double>] = [
        .init(0.42, 0.19, 0.14), .init(0.73, 0.45, 0.29),
        .init(0.20, 0.30, 0.12), .init(0.18, 0.23, 0.41),
        .init(0.46, 0.18, 0.28), .init(0.11, 0.32, 0.33),
        .init(0.72, 0.28, 0.08), .init(0.24, 0.18, 0.36),
        .init(0.77, 0.47, 0.09), .init(0.12, 0.26, 0.15),
        .init(0.54, 0.24, 0.12), .init(0.09, 0.19, 0.34),
        .init(0.93, 0.64, 0.50), .init(0.72, 0.49, 0.38),
        .init(0.60, 0.38, 0.28), .init(0.40, 0.25, 0.19),
        .init(0.91, 0.72, 0.55), .init(0.77, 0.60, 0.46),
        .init(0.58, 0.42, 0.30), .init(0.36, 0.25, 0.17),
        .init(0.95, 0.95, 0.94), .init(0.76, 0.76, 0.74),
        .init(0.52, 0.52, 0.50), .init(0.20, 0.20, 0.19)
    ]

    private static func solve3x3(_ matrix: [Double], _ right: inout [Double]) -> [Double]? {
        var a = [
            [matrix[0], matrix[1], matrix[2], right[0]],
            [matrix[3], matrix[4], matrix[5], right[1]],
            [matrix[6], matrix[7], matrix[8], right[2]]
        ]
        for pivot in 0..<3 {
            guard let row = (pivot..<3).max(by: { abs(a[$0][pivot]) < abs(a[$1][pivot]) }),
                  abs(a[row][pivot]) > 0.0000001 else { return nil }
            a.swapAt(pivot, row)
            let divisor = a[pivot][pivot]
            for column in pivot..<4 { a[pivot][column] /= divisor }
            for row in 0..<3 where row != pivot {
                let factor = a[row][pivot]
                for column in pivot..<4 { a[row][column] -= factor * a[pivot][column] }
            }
        }
        return [a[0][3], a[1][3], a[2][3]]
    }
}

enum ReferenceColorMatcher {
    static func suggestion(source: CGImage, reference: CGImage) -> NaturalColorSuggestion {
        let current = NaturalColorAssistant.analyze(source)
        let target = NaturalColorAssistant.analyze(reference)
        let constancy = ColorConstancyAnalyzer.estimate(for: source)
        let exposure = min(1.5, max(-1.5, log2(max(0.04, target.averageLuminance) /
                                                 max(0.04, current.averageLuminance))))
        let temperature = min(1500, max(-1500,
            ((target.blueBalance - target.redBalance) -
             (current.blueBalance - current.redBalance)) * 2600))
        let tint = min(35, max(-35, (target.greenBalance - current.greenBalance) * -240))
        let saturation = min(25, max(-25, (target.averageSaturation - current.averageSaturation) * 100))
        return NaturalColorSuggestion(
            exposureDelta: exposure,
            contrastDelta: min(24, max(-24, (target.dynamicRange - current.dynamicRange) * 80)),
            temperatureDelta: temperature,
            tintDelta: tint,
            vibranceDelta: saturation > 0 ? saturation : 0,
            saturationDelta: saturation < 0 ? saturation : 0,
            confidence: 0.7,
            reasons: [.exposure, .whiteBalance, .contrast, .colorDepth],
            analysis: current,
            constancyConfidence: constancy.confidence,
            constancyAgreementDegrees: constancy.agreementDegrees,
            constancyMethods: constancy.methods
        )
    }
}
