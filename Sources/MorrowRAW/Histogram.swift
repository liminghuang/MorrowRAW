import CoreGraphics
import Accelerate
import SwiftUI

enum HistogramCalculator {
    static func snapshot(for image: CGImage, count: Int = 64) -> HistogramSnapshot {
        let signpostID = MorrowPerformanceLog.begin("Histogram")
        defer { MorrowPerformanceLog.end("Histogram", id: signpostID) }
        guard count > 1,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let data = context.data else {
            return HistogramSnapshot(luminance: [], rgb: .empty)
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        var luminance = [CGFloat](repeating: 0, count: count)
        var red = luminance
        var green = luminance
        var blue = luminance
        let pixelCount = image.width * image.height
        for index in 0..<pixelCount {
            let offset = index * 4
            let redValue = CGFloat(bytes[offset]) / 255
            let greenValue = CGFloat(bytes[offset + 1]) / 255
            let blueValue = CGFloat(bytes[offset + 2]) / 255
            let luminanceValue = min(1, max(0, 0.2126 * redValue + 0.7152 * greenValue + 0.0722 * blueValue))
            luminance[min(count - 1, Int(luminanceValue * CGFloat(count)))] += 1
            red[min(count - 1, Int(redValue * CGFloat(count)))] += 1
            green[min(count - 1, Int(greenValue * CGFloat(count)))] += 1
            blue[min(count - 1, Int(blueValue * CGFloat(count)))] += 1
        }
        return HistogramSnapshot(
            luminance: normalize(luminance),
            rgb: RGBHistogram(red: normalize(red), green: normalize(green), blue: normalize(blue))
        )
    }

    static func bins(for image: CGImage, count: Int = 64) -> [CGFloat] {
        snapshot(for: image, count: count).luminance
    }

    static func rgbBins(for image: CGImage, count: Int = 64) -> RGBHistogram {
        snapshot(for: image, count: count).rgb
    }

    private static func normalize(_ values: [CGFloat]) -> [CGFloat] {
        guard !values.isEmpty else { return values }
        var normalized = values.map(Double.init)
        var peak = 0.0
        vDSP_maxvD(normalized, 1, &peak, vDSP_Length(normalized.count))
        guard peak > 0 else { return values }
        vDSP_vsdivD(normalized, 1, &peak, &normalized, 1,
                    vDSP_Length(normalized.count))
        return normalized.map { CGFloat($0) }
    }
}

struct HistogramSnapshot {
    let luminance: [CGFloat]
    let rgb: RGBHistogram
}

struct RGBHistogram {
    let red: [CGFloat]
    let green: [CGFloat]
    let blue: [CGFloat]

    static let empty = RGBHistogram(red: [], green: [], blue: [])
    var isEmpty: Bool { red.isEmpty && green.isEmpty && blue.isEmpty }
}

struct HistogramView: View {
    let bins: [CGFloat]

    var body: some View {
        GeometryReader { geometry in
            Path { path in
                guard !bins.isEmpty else { return }
                let step = geometry.size.width / CGFloat(bins.count - 1)
                path.move(to: CGPoint(x: 0, y: geometry.size.height))
                for (index, value) in bins.enumerated() {
                    path.addLine(to: CGPoint(x: CGFloat(index) * step,
                                             y: geometry.size.height * (1 - value)))
                }
                path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height))
                path.closeSubpath()
            }
            .fill(Color.accentColor.opacity(0.75))
        }
        .background(Color.black.opacity(0.18))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .accessibilityLabel("Histogram")
    }
}

struct RGBHistogramView: View {
    let histogram: RGBHistogram

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.18)
                channelPath(histogram.red, in: geometry.size)
                    .fill(Color.red.opacity(0.18))
                channelPath(histogram.green, in: geometry.size)
                    .fill(Color.green.opacity(0.14))
                channelPath(histogram.blue, in: geometry.size)
                    .fill(Color.blue.opacity(0.18))
                channelLine(histogram.red, in: geometry.size).stroke(Color.red.opacity(0.9), lineWidth: 1)
                channelLine(histogram.green, in: geometry.size).stroke(Color.green.opacity(0.9), lineWidth: 1)
                channelLine(histogram.blue, in: geometry.size).stroke(Color.blue.opacity(0.9), lineWidth: 1)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .accessibilityLabel("RGB 色彩直方圖")
    }

    private func channelLine(_ values: [CGFloat], in size: CGSize) -> Path {
        Path { path in
            guard values.count > 1 else { return }
            let step = size.width / CGFloat(values.count - 1)
            path.move(to: CGPoint(x: 0, y: size.height * (1 - values[0])))
            for (index, value) in values.enumerated() {
                path.addLine(to: CGPoint(x: CGFloat(index) * step, y: size.height * (1 - value)))
            }
        }
    }

    private func channelPath(_ values: [CGFloat], in size: CGSize) -> Path {
        var path = channelLine(values, in: size)
        guard values.count > 1 else { return path }
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.addLine(to: CGPoint(x: 0, y: size.height))
        path.closeSubpath()
        return path
    }
}
