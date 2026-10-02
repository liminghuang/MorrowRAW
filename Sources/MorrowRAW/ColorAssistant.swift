import CoreGraphics
import Foundation

struct ColorAnalysis: Equatable {
    let averageLuminance: Double
    let medianLuminance: Double
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
    case subjectBalance

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
        case .subjectBalance: zh = "主體曝光平衡"; en = "Subject exposure balance"
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
    let subjectEvidence: SubjectExposureEvidence?

    var plan: NaturalColorPlan {
        var protectedRegions: [String] = []
        if subjectEvidence?.backgroundRegion == .sky { protectedRegions.append("sky") }
        if let subjectRegion = subjectEvidence?.subjectRegion {
            protectedRegions.append(subjectRegion.rawValue)
        }
        return NaturalColorPlan(
            observations: [
                "average_luminance": analysis.averageLuminance,
                "median_luminance": analysis.medianLuminance,
                "shadow_luminance": analysis.shadowLuminance,
                "highlight_luminance": analysis.highlightLuminance,
                "clipped_shadow_fraction": analysis.clippedShadowFraction,
                "clipped_highlight_fraction": analysis.clippedHighlightFraction,
                "average_saturation": analysis.averageSaturation,
                "constancy_confidence": constancyConfidence,
                "constancy_agreement_degrees": constancyAgreementDegrees,
                "subject_median_luminance": subjectEvidence?.subjectMedianLuminance ?? 0,
                "subject_highlight_luminance": subjectEvidence?.subjectHighlightLuminance ?? 0,
                "background_median_luminance": subjectEvidence?.backgroundMedianLuminance ?? 0,
                "background_highlight_luminance": subjectEvidence?.backgroundHighlightLuminance ?? 0,
                "subject_coverage": subjectEvidence?.subjectCoverage ?? 0,
                "subject_confidence": subjectEvidence?.confidence ?? 0
            ],
            exposureDelta: exposureDelta,
            contrastDelta: contrastDelta,
            temperatureDelta: temperatureDelta,
            tintDelta: tintDelta,
            vibranceDelta: vibranceDelta,
            saturationDelta: saturationDelta,
            confidence: confidence,
            estimatorMethods: constancyMethods,
            modelIdentifier: "morrow.natural-color.classical-ensemble",
            modelVersion: "1.1",
            protectedRegions: protectedRegions
        )
    }

    var hasChanges: Bool {
        abs(exposureDelta) > 0.01 || abs(contrastDelta) > 0.1 ||
        abs(temperatureDelta) > 1 || abs(tintDelta) > 0.1 ||
        abs(vibranceDelta) > 0.1 || abs(saturationDelta) > 0.1
    }

    func applying(to source: ImageAdjustments, strength: Double = 1) -> ImageAdjustments {
        NaturalColorAdjustmentMapper.apply(plan, to: source, strength: strength)
    }
}

struct NaturalColorPlan: Codable, Equatable {
    let schemaVersion: Int
    let observations: [String: Double]
    let exposureDelta: Double
    let contrastDelta: Double
    let temperatureDelta: Double
    let tintDelta: Double
    let vibranceDelta: Double
    let saturationDelta: Double
    let confidence: Double
    let estimatorMethods: [String]
    let modelIdentifier: String
    let modelVersion: String
    let protectedRegions: [String]

    init(schemaVersion: Int = 1,
         observations: [String: Double],
         exposureDelta: Double,
         contrastDelta: Double,
         temperatureDelta: Double,
         tintDelta: Double,
         vibranceDelta: Double,
         saturationDelta: Double,
         confidence: Double,
         estimatorMethods: [String],
         modelIdentifier: String = "morrow.natural-color.classical-ensemble",
         modelVersion: String = "1.0",
         protectedRegions: [String] = []) {
        self.schemaVersion = schemaVersion
        self.observations = observations
        self.exposureDelta = exposureDelta
        self.contrastDelta = contrastDelta
        self.temperatureDelta = temperatureDelta
        self.tintDelta = tintDelta
        self.vibranceDelta = vibranceDelta
        self.saturationDelta = saturationDelta
        self.confidence = confidence
        self.estimatorMethods = estimatorMethods
        self.modelIdentifier = modelIdentifier
        self.modelVersion = modelVersion
        self.protectedRegions = protectedRegions
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, observations, exposureDelta, contrastDelta,
             temperatureDelta, tintDelta, vibranceDelta, saturationDelta,
             confidence, estimatorMethods, modelIdentifier, modelVersion,
             protectedRegions
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        observations = try values.decodeIfPresent([String: Double].self, forKey: .observations) ?? [:]
        exposureDelta = try values.decodeIfPresent(Double.self, forKey: .exposureDelta) ?? 0
        contrastDelta = try values.decodeIfPresent(Double.self, forKey: .contrastDelta) ?? 0
        temperatureDelta = try values.decodeIfPresent(Double.self, forKey: .temperatureDelta) ?? 0
        tintDelta = try values.decodeIfPresent(Double.self, forKey: .tintDelta) ?? 0
        vibranceDelta = try values.decodeIfPresent(Double.self, forKey: .vibranceDelta) ?? 0
        saturationDelta = try values.decodeIfPresent(Double.self, forKey: .saturationDelta) ?? 0
        confidence = try values.decodeIfPresent(Double.self, forKey: .confidence) ?? 0
        estimatorMethods = try values.decodeIfPresent([String].self, forKey: .estimatorMethods) ?? []
        modelIdentifier = try values.decodeIfPresent(String.self, forKey: .modelIdentifier)
            ?? "morrow.natural-color.classical-ensemble"
        modelVersion = try values.decodeIfPresent(String.self, forKey: .modelVersion) ?? "1.0"
        protectedRegions = try values.decodeIfPresent([String].self, forKey: .protectedRegions) ?? []
    }
}

enum NaturalColorAdjustmentMapper {
    static func apply(_ plan: NaturalColorPlan, to source: ImageAdjustments,
                      strength: Double) -> ImageAdjustments {
        let requestedStrength = min(2, max(0, strength))
        // Confidence is surfaced as evidence for the user; the explicit
        // strength slider remains the sole intensity control for compatibility.
        let amount = requestedStrength
        let backgroundHighlight = plan.observations["background_highlight_luminance"] ?? 0
        // Natural suggestions are intentionally conservative. The renderer's
        // highlight shoulder is useful for manual exposure, but a full-strength
        // auto suggestion should not make a whole RAW look like a log preview.
        var exposure = min(0.9, max(-1.0, plan.exposureDelta))
        if plan.protectedRegions.contains("sky"), backgroundHighlight > 0.8, exposure > 0 {
            exposure = min(exposure, 0.7)
        }
        var result = source
        result.exposure = min(5, max(-5, source.exposure + exposure * amount))
        result.contrast = min(100, max(-100, source.contrast +
            min(18, max(-6, plan.contrastDelta)) * amount))
        result.temperature = min(12000, max(2000, source.temperature +
            min(1500, max(-1500, plan.temperatureDelta)) * amount))
        result.tint = min(100, max(-100, source.tint +
            min(35, max(-35, plan.tintDelta)) * amount))
        result.vibrance = min(100, max(-100, source.vibrance +
            min(25, max(-25, plan.vibranceDelta)) * amount))
        result.saturation = min(100, max(-100, source.saturation +
            min(25, max(-25, plan.saturationDelta)) * amount))
        return result
    }
}

enum NaturalColorAssistant {
    static func analyze(_ image: CGImage) -> ColorAnalysis {
        analyze(samples: ColorSampleBuffer.linearSamples(from: image))
    }

    private static func analyze(samples: [LinearColorSample]) -> ColorAnalysis {
        guard !samples.isEmpty else {
            return ColorAnalysis(averageLuminance: 0.5, medianLuminance: 0.5,
                                 shadowLuminance: 0.2,
                                 highlightLuminance: 0.8, redBalance: 0,
                                 greenBalance: 0, blueBalance: 0,
                                 averageSaturation: 0.2, clippedShadowFraction: 0,
                                 clippedHighlightFraction: 0, sampleCount: 0)
        }
        let luminances = samples.map(\.luminance)
        let sorted = luminances.sorted()
        let low = sorted[Int(Double(sorted.count - 1) * 0.05)]
        let high = sorted[Int(Double(sorted.count - 1) * 0.95)]
        let count = Double(samples.count)
        let averageRed = samples.reduce(0) { $0 + $1.red } / count
        let averageGreen = samples.reduce(0) { $0 + $1.green } / count
        let averageBlue = samples.reduce(0) { $0 + $1.blue } / count
        let averageSaturation = samples.reduce(0) {
            $0 + max($1.red, max($1.green, $1.blue)) - min($1.red, min($1.green, $1.blue))
        } / count
        let clippedShadows = luminances.filter { $0 <= 0.012 }.count
        let clippedHighlights = luminances.filter { $0 >= 0.988 }.count
        return ColorAnalysis(
            averageLuminance: luminances.reduce(0, +) / count,
            medianLuminance: sorted[sorted.count / 2],
            shadowLuminance: low,
            highlightLuminance: high,
            redBalance: averageRed - (averageGreen + averageBlue) / 2,
            greenBalance: averageGreen - (averageRed + averageBlue) / 2,
            blueBalance: averageBlue - (averageRed + averageGreen) / 2,
            averageSaturation: averageSaturation,
            clippedShadowFraction: Double(clippedShadows) / count,
            clippedHighlightFraction: Double(clippedHighlights) / count,
            sampleCount: luminances.count
        )
    }

    static func suggest(for image: CGImage) -> NaturalColorSuggestion {
        let samples = ColorSampleBuffer.linearSamples(from: image)
        let analysis = analyze(samples: samples)
        let subjectEvidence = SubjectExposureAnalyzer.analyze(image)
        let constancy = ColorConstancyAnalyzer.estimate(
            samples: samples.filter { $0.luminance < 0.995 }
        )
        // Exposure estimation belongs in linear light. 0.18 is the usual
        // middle-gray target; using an sRGB target here makes mid-tones look
        // artificially close to correct and weakens the recommendation.
        let targetLuminance = 0.18
        let baseExposure = log2(targetLuminance / max(0.04, analysis.medianLuminance))
        let highlightPenalty = min(1.5, analysis.clippedHighlightFraction * 60)
        let shadowLift = analysis.clippedShadowFraction > 0.08 ? 8.0 : 0
        let shadowBonus = min(0.35, max(0, analysis.clippedShadowFraction - 0.08) * 3)
        let globalExposure = baseExposure - highlightPenalty + shadowBonus
        let exposure: Double
        if let subjectEvidence, subjectEvidence.hasReliableSubject {
            let subjectTarget = 0.18
            let subjectExposure = log2(subjectTarget / max(0.04, subjectEvidence.subjectMedianLuminance))
            let backgroundHighlightPenalty = max(0, subjectEvidence.backgroundHighlightLuminance - 0.72) * 2.2
            let protection = min(1.0, max(0, 1 - backgroundHighlightPenalty))
            let confidenceWeight = min(0.78, max(0.35, subjectEvidence.confidence))
            let subjectContribution = subjectExposure * protection
            exposure = min(1.5, max(-1.5,
                globalExposure * (1 - confidenceWeight) + subjectContribution * confidenceWeight))
        } else {
            exposure = min(1.5, max(-1.5, globalExposure))
        }
        let whiteBalanceScale = constancy.isReliable
            ? 1.0
            : min(1, max(0, constancy.confidence / 0.45))
        let temperature = min(1500, max(-1500,
            (constancy.correctionGains.x - constancy.correctionGains.z) * 2200 * whiteBalanceScale))
        let meanGain = (constancy.correctionGains.x + constancy.correctionGains.y + constancy.correctionGains.z) / 3
        let tint = min(35, max(-35, (meanGain - constancy.correctionGains.y) * 160 * whiteBalanceScale))
        let range = analysis.dynamicRange
        // A wide RAW dynamic range is not evidence that the image needs a
        // negative contrast curve; limiting this prevents a flat, log-like
        // result when paired with protected positive exposure.
        let contrast = min(18, max(-6, (0.62 - range) * 55))
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
        if subjectEvidence?.hasReliableSubject == true { reasons.append(.subjectBalance) }

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
            constancyMethods: constancy.methods,
            subjectEvidence: subjectEvidence
        )
    }

}
