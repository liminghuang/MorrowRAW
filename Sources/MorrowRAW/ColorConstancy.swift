import CoreGraphics
import Foundation
import simd

struct ColorConstancyEstimate: Equatable {
    let illuminant: SIMD3<Double>
    let correctionGains: SIMD3<Double>
    let confidence: Double
    let agreementDegrees: Double
    let methods: [String]

    var isReliable: Bool { confidence >= 0.45 && agreementDegrees <= 20 }
}

struct LinearColorSample {
    let red: Double
    let green: Double
    let blue: Double
    let luminance: Double
}

enum ColorSampleBuffer {
    static func linearSamples(from image: CGImage, maxDimension: Int = 256,
                              includeClipped: Bool = true) -> [LinearColorSample] {
        let scale = min(1, CGFloat(maxDimension) / CGFloat(max(image.width, image.height)))
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        let bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let context = CGContext(data: &buffer, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        func linearized(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        var samples: [LinearColorSample] = []
        samples.reserveCapacity(width * height)
        for offset in stride(from: 0, to: buffer.count, by: 4) {
            guard buffer[offset + 3] > 3 else { continue }
            let red = linearized(Double(buffer[offset]) / 255)
            let green = linearized(Double(buffer[offset + 1]) / 255)
            let blue = linearized(Double(buffer[offset + 2]) / 255)
            let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
            guard luminance > 0.002 else { continue }
            if !includeClipped && luminance >= 0.995 { continue }
            samples.append(LinearColorSample(red: red, green: green, blue: blue, luminance: luminance))
        }
        return samples
    }
}

enum ColorConstancyAnalyzer {
    static func estimate(for image: CGImage) -> ColorConstancyEstimate {
        estimate(samples: ColorSampleBuffer.linearSamples(from: image, includeClipped: false))
    }

    static func estimate(samples pixels: [LinearColorSample]) -> ColorConstancyEstimate {
        guard pixels.count >= 16 else {
            return ColorConstancyEstimate(
                illuminant: SIMD3(1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0),
                correctionGains: SIMD3(repeating: 1), confidence: 0.2,
                agreementDegrees: 90, methods: []
            )
        }

        let candidates: [(String, SIMD3<Double>)] = [
            ("Gray World", grayWorld(pixels)),
            ("Gray Pixel", grayPixel(pixels)),
            ("White Patch", whitePatch(pixels)),
            ("Shades of Gray", shadesOfGray(pixels, order: 6)),
            ("Gray Edge", grayEdge(pixels))
        ]
        let normalized = candidates.map { ($0.0, normalize($0.1)) }
        let sum = normalized.reduce(SIMD3<Double>(repeating: 0)) { $0 + $1.1 }
        let illuminant = normalize(sum / Double(normalized.count))
        let pairwiseAngles = normalized.flatMap { lhs in
            normalized.filter { $0.0 > lhs.0 }.map { angularDistance(lhs.1, $0.1) }
        }
        let agreement = pairwiseAngles.max() ?? 90
        let confidence = min(0.92, max(0.22,
            0.88 - agreement / 42 + min(0.08, Double(pixels.count) / 250_000)))
        let mean = (illuminant.x + illuminant.y + illuminant.z) / 3
        let gains = SIMD3(
            min(2, max(0.5, mean / max(0.0001, illuminant.x))),
            min(2, max(0.5, mean / max(0.0001, illuminant.y))),
            min(2, max(0.5, mean / max(0.0001, illuminant.z)))
        )
        return ColorConstancyEstimate(
            illuminant: illuminant,
            correctionGains: gains,
            confidence: confidence,
            agreementDegrees: agreement,
            methods: normalized.map(\.0)
        )
    }

    private static func grayWorld(_ pixels: [LinearColorSample]) -> SIMD3<Double> {
        let total = pixels.reduce(SIMD3<Double>(repeating: 0)) {
            $0 + SIMD3($1.red, $1.green, $1.blue)
        }
        return total / Double(pixels.count)
    }

    private static func grayPixel(_ pixels: [LinearColorSample]) -> SIMD3<Double> {
        let neutral = pixels.filter {
            let maximum = max($0.red, max($0.green, $0.blue))
            let minimum = min($0.red, min($0.green, $0.blue))
            return maximum - minimum < 0.08 && $0.luminance > 0.03 && $0.luminance < 0.9
        }
        guard neutral.count >= max(16, pixels.count / 200) else { return grayWorld(pixels) }
        return grayWorld(neutral)
    }

    private static func whitePatch(_ pixels: [LinearColorSample]) -> SIMD3<Double> {
        func percentile(_ values: [Double], _ fraction: Double) -> Double {
            let sorted = values.sorted()
            return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))]
        }
        return SIMD3(
            percentile(pixels.map(\.red), 0.98),
            percentile(pixels.map(\.green), 0.98),
            percentile(pixels.map(\.blue), 0.98)
        )
    }

    private static func shadesOfGray(_ pixels: [LinearColorSample], order: Int) -> SIMD3<Double> {
        let exponent = Double(order)
        let values = pixels.reduce(SIMD3<Double>(repeating: 0)) {
            $0 + SIMD3(pow($1.red, exponent), pow($1.green, exponent), pow($1.blue, exponent))
        } / Double(pixels.count)
        return SIMD3(pow(values.x, 1 / exponent), pow(values.y, 1 / exponent), pow(values.z, 1 / exponent))
    }

    private static func grayEdge(_ pixels: [LinearColorSample]) -> SIMD3<Double> {
        guard pixels.count > 1 else { return grayWorld(pixels) }
        var total = SIMD3<Double>(repeating: 0)
        for pair in zip(pixels, pixels.dropFirst()) {
            total += SIMD3(abs(pair.0.red - pair.1.red),
                           abs(pair.0.green - pair.1.green),
                           abs(pair.0.blue - pair.1.blue))
        }
        return total.x + total.y + total.z > 0.0001 ? total : grayWorld(pixels)
    }

    private static func normalize(_ value: SIMD3<Double>) -> SIMD3<Double> {
        let sum = value.x + value.y + value.z
        return sum > 0.000001 ? value / sum : SIMD3(repeating: 1.0 / 3.0)
    }

    private static func angularDistance(_ lhs: SIMD3<Double>, _ rhs: SIMD3<Double>) -> Double {
        let left = normalize(lhs)
        let right = normalize(rhs)
        let dot = min(1, max(-1, simd_dot(left, right) /
                              max(0.000001, sqrt(simd_dot(left, left) * simd_dot(right, right)))))
        return acos(dot) * 180 / .pi
    }

}
