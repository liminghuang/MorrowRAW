import CoreGraphics
import Foundation

struct ColorAnalysis: Equatable {
    let averageLuminance: Double
    let shadowLuminance: Double
    let highlightLuminance: Double
    let redBalance: Double
    let greenBalance: Double
    let blueBalance: Double
    let averageSaturation: Double
    let clippedShadowFraction: Double
    let clippedHighlightFraction: Double
    let sampleCount: Int

    var dynamicRange: Double {
        max(0, highlightLuminance - shadowLuminance)
    }
}

enum ColorSuggestionReason: String, Equatable, CaseIterable {
    case exposure
    case whiteBalance
    case contrast
    case colorDepth
    case highlightProtection
    case shadowLift

    var displayName: String {
        let zh: String
        let en: String
        switch self {
        case .exposure: zh = "曝光平衡"; en = "Exposure balance"
        case .whiteBalance: zh = "白平衡"; en = "White balance"
        case .contrast: zh = "整體對比"; en = "Overall contrast"
        case .colorDepth: zh = "色彩厚度"; en = "Color depth"
        case .highlightProtection: zh = "高光保護"; en = "Highlight protection"
        case .shadowLift: zh = "陰影提亮"; en = "Shadow lift"
        }
        return StudioText.localized(zh, en)
    }
}

struct NaturalColorSuggestion: Equatable {
    let exposureDelta: Double
    let contrastDelta: Double
    let temperatureDelta: Double
    let tintDelta: Double
    let vibranceDelta: Double
    let saturationDelta: Double
    let confidence: Double
    let reasons: [ColorSuggestionReason]
    let analysis: ColorAnalysis
    let constancyConfidence: Double
    let constancyAgreementDegrees: Double
    let constancyMethods: [String]

    var hasChanges: Bool {
        abs(exposureDelta) > 0.01 || abs(contrastDelta) > 0.1 ||
        abs(temperatureDelta) > 1 || abs(tintDelta) > 0.1 ||
        abs(vibranceDelta) > 0.1 || abs(saturationDelta) > 0.1
    }

    func applying(to source: ImageAdjustments) -> ImageAdjustments {
        var result = source
        result.exposure = min(5, max(-5, source.exposure + exposureDelta))
        result.contrast = min(100, max(-100, source.contrast + contrastDelta))
        result.temperature = min(12000, max(2000, source.temperature + temperatureDelta))
        result.tint = min(100, max(-100, source.tint + tintDelta))
        result.vibrance = min(100, max(-100, source.vibrance + vibranceDelta))
        result.saturation = min(100, max(-100, source.saturation + saturationDelta))
        return result
    }
}

enum NaturalColorAssistant {
    static func analyze(_ image: CGImage) -> ColorAnalysis {
        let maxDimension = 256
        let scale = min(1, CGFloat(maxDimension) / CGFloat(max(image.width, image.height)))
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)

        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return ColorAnalysis(averageLuminance: 0.5, shadowLuminance: 0.2,
                                 highlightLuminance: 0.8, redBalance: 0,
                                 greenBalance: 0, blueBalance: 0,
                                 averageSaturation: 0.2, clippedShadowFraction: 0,
                                 clippedHighlightFraction: 0, sampleCount: 0)
        }

        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var luminances: [Double] = []
        luminances.reserveCapacity(width * height)
        var red = 0.0
        var green = 0.0
        var blue = 0.0
        var saturation = 0.0
        var clippedShadows = 0
        var clippedHighlights = 0

        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[offset + 3]) / 255
            guard alpha > 0.01 else { continue }
            let r = Double(pixels[offset]) / 255
            let g = Double(pixels[offset + 1]) / 255
            let b = Double(pixels[offset + 2]) / 255
            let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
            luminances.append(luminance)
            red += r
            green += g
            blue += b
            saturation += max(r, max(g, b)) - min(r, min(g, b))
            if luminance <= 0.012 { clippedShadows += 1 }
            if luminance >= 0.988 { clippedHighlights += 1 }
        }

        guard !luminances.isEmpty else {
            return ColorAnalysis(averageLuminance: 0.5, shadowLuminance: 0.2,
                                 highlightLuminance: 0.8, redBalance: 0,
                                 greenBalance: 0, blueBalance: 0,
                                 averageSaturation: 0.2, clippedShadowFraction: 0,
                                 clippedHighlightFraction: 0, sampleCount: 0)
        }

        let sorted = luminances.sorted()
        let low = sorted[Int(Double(sorted.count - 1) * 0.05)]
        let high = sorted[Int(Double(sorted.count - 1) * 0.95)]
        let count = Double(luminances.count)
        let averageRed = red / count
        let averageGreen = green / count
        let averageBlue = blue / count
        return ColorAnalysis(
            averageLuminance: luminances.reduce(0, +) / count,
            shadowLuminance: low,
            highlightLuminance: high,
            redBalance: averageRed - (averageGreen + averageBlue) / 2,
            greenBalance: averageGreen - (averageRed + averageBlue) / 2,
            blueBalance: averageBlue - (averageRed + averageGreen) / 2,
            averageSaturation: saturation / count,
            clippedShadowFraction: Double(clippedShadows) / count,
            clippedHighlightFraction: Double(clippedHighlights) / count,
            sampleCount: luminances.count
        )
    }

    static func suggest(for image: CGImage) -> NaturalColorSuggestion {
        let analysis = analyze(image)
        let constancy = ColorConstancyAnalyzer.estimate(for: image)
        let targetLuminance = 0.46
        let exposure = min(1.5, max(-1.5, log2(targetLuminance / max(0.04, analysis.averageLuminance))))
        let temperature = min(1500, max(-1500,
            (constancy.correctionGains.x - constancy.correctionGains.z) * 2200))
        let meanGain = (constancy.correctionGains.x + constancy.correctionGains.y + constancy.correctionGains.z) / 3
        let tint = min(35, max(-35, (meanGain - constancy.correctionGains.y) * 160))
        let range = analysis.dynamicRange
        let contrast = min(24, max(-18, (0.62 - range) * 80))
        let shadowLift = analysis.clippedShadowFraction > 0.08 ? 8.0 : 0
        let highlightProtection = analysis.clippedHighlightFraction > 0.015 ? -10.0 : 0
        let vibrance = analysis.averageSaturation < 0.16 ?
            min(18, (0.16 - analysis.averageSaturation) * 100) : 0

        var reasons: [ColorSuggestionReason] = []
        if abs(exposure) > 0.08 { reasons.append(.exposure) }
        if abs(temperature) > 40 || abs(tint) > 1 { reasons.append(.whiteBalance) }
        if abs(contrast) > 2 { reasons.append(.contrast) }
        if vibrance > 2 { reasons.append(.colorDepth) }
        if highlightProtection != 0 { reasons.append(.highlightProtection) }
        if shadowLift != 0 { reasons.append(.shadowLift) }

        let confidence = min(constancy.confidence, min(0.96, max(0.35,
            0.45 + min(0.25, Double(analysis.sampleCount) / 65_536) +
            (analysis.dynamicRange > 0.1 ? 0.12 : 0))))
        return NaturalColorSuggestion(
            exposureDelta: exposure,
            contrastDelta: contrast,
            temperatureDelta: temperature,
            tintDelta: tint,
            vibranceDelta: vibrance,
            saturationDelta: 0,
            confidence: confidence,
            reasons: reasons,
            analysis: analysis,
            constancyConfidence: constancy.confidence,
            constancyAgreementDegrees: constancy.agreementDegrees,
            constancyMethods: constancy.methods
        )
    }
}
