import CoreGraphics
import SwiftUI

struct ColorScopeSnapshot: Equatable {
    let waveform: [Float]
    let waveformWidth: Int
    let waveformHeight: Int
    let vectorscope: [Float]
    let vectorscopeSize: Int
    let clippedShadowFraction: Double
    let clippedHighlightFraction: Double

    static let empty = ColorScopeSnapshot(
        waveform: [], waveformWidth: 0, waveformHeight: 0,
        vectorscope: [], vectorscopeSize: 0,
        clippedShadowFraction: 0, clippedHighlightFraction: 0
    )
}

enum ColorScopeCalculator {
    static func snapshot(for image: CGImage,
                         waveformWidth: Int = 128,
                         waveformHeight: Int = 64,
                         vectorscopeSize: Int = 128) -> ColorScopeSnapshot {
        guard let pixels = RGBAImagePixels(image) else { return .empty }
        var waveform = [Float](repeating: 0, count: waveformWidth * waveformHeight)
        var vectorscope = [Float](repeating: 0, count: vectorscopeSize * vectorscopeSize)
        var shadows = 0
        var highlights = 0
        var count = 0

        for y in 0..<pixels.height {
            for x in 0..<pixels.width {
                let (r, g, b, alpha) = pixels.pixel(x: x, y: y)
                guard alpha > 0.01 else { continue }
                count += 1
                let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                if max(r, max(g, b)) <= 0.012 { shadows += 1 }
                if max(r, max(g, b)) >= 0.988 { highlights += 1 }

                let waveformX = min(waveformWidth - 1,
                                    max(0, x * waveformWidth / max(1, pixels.width)))
                let waveformY = min(waveformHeight - 1,
                                    max(0, Int((1 - luma) * Double(waveformHeight - 1))))
                waveform[waveformY * waveformWidth + waveformX] += 1

                let chromaX = 2 * r - g - b
                let chromaY = g - b
                let scopeX = min(vectorscopeSize - 1, max(0,
                    Int((chromaX * 0.5 + 0.5) * Double(vectorscopeSize - 1))))
                let scopeY = min(vectorscopeSize - 1, max(0,
                    Int((1 - (chromaY * 0.5 + 0.5)) * Double(vectorscopeSize - 1))))
                vectorscope[scopeY * vectorscopeSize + scopeX] += 1
            }
        }

        let maximumWaveform = max(1, waveform.max() ?? 1)
        let maximumVectorscope = max(1, vectorscope.max() ?? 1)
        waveform = waveform.map { sqrt($0 / maximumWaveform) }
        vectorscope = vectorscope.map { sqrt($0 / maximumVectorscope) }
        let denominator = Double(max(1, count))
        return ColorScopeSnapshot(
            waveform: waveform,
            waveformWidth: waveformWidth,
            waveformHeight: waveformHeight,
            vectorscope: vectorscope,
            vectorscopeSize: vectorscopeSize,
            clippedShadowFraction: Double(shadows) / denominator,
            clippedHighlightFraction: Double(highlights) / denominator
        )
    }
}

private struct RGBAImagePixels {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let data: [UInt8]

    init?(_ image: CGImage) {
        width = min(512, max(1, image.width))
        height = max(1, Int((Double(image.height) * Double(width) / Double(max(1, image.width))).rounded()))
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

struct ColorScopesView: View {
    let snapshot: ColorScopeSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(StudioText.localized("色彩 scopes", "Color Scopes"))
                .font(.caption.weight(.semibold))
            HStack(spacing: 8) {
                ScopeGridView(values: snapshot.waveform,
                              width: snapshot.waveformWidth,
                              height: snapshot.waveformHeight,
                              tint: .green)
                ScopeGridView(values: snapshot.vectorscope,
                              width: snapshot.vectorscopeSize,
                              height: snapshot.vectorscopeSize,
                              tint: .cyan)
            }
            HStack(spacing: 12) {
                clippingLabel(
                    StudioText.localized("黑位", "Shadow"),
                    snapshot.clippedShadowFraction,
                    color: .blue
                )
                clippingLabel(
                    StudioText.localized("高光", "Highlight"),
                    snapshot.clippedHighlightFraction,
                    color: .red
                )
            }
            .font(.caption2.monospacedDigit())
        }
    }

    private func clippingLabel(_ title: String, _ value: Double, color: Color) -> some View {
        Label {
            Text("\(title) \(String(format: "%.1f%%", value * 100))")
        } icon: {
            Circle().fill(color).frame(width: 6, height: 6)
        }
        .foregroundStyle(value > 0.02 ? color : StudioUI.secondary)
    }
}

private struct ScopeGridView: View {
    let values: [Float]
    let width: Int
    let height: Int
    let tint: Color

    var body: some View {
        Canvas { context, size in
            guard width > 0, height > 0, values.count == width * height else { return }
            let cellWidth = size.width / CGFloat(width)
            let cellHeight = size.height / CGFloat(height)
            for y in 0..<height {
                for x in 0..<width {
                    let value = CGFloat(values[y * width + x])
                    guard value > 0 else { continue }
                    let rect = CGRect(x: CGFloat(x) * cellWidth,
                                      y: CGFloat(y) * cellHeight,
                                      width: max(1, cellWidth + 0.5),
                                      height: max(1, cellHeight + 0.5))
                    context.fill(Path(rect), with: .color(tint.opacity(min(0.95, 0.08 + value * 0.8))))
                }
            }
        }
        .background(Color.black.opacity(0.8))
        .overlay(Rectangle().stroke(StudioUI.divider, lineWidth: 1))
        .aspectRatio(width == height ? 1 : 1.8, contentMode: .fit)
    }
}
