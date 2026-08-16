import Foundation

enum BuiltInPreset: String, CaseIterable, Identifiable {
    case defaultPreset = "預設時設定"
    case landscape = "風景"
    case portrait = "人像"
    case vivid = "鮮豔"
    case monochrome = "黑白"
    case soft = "柔和"

    var id: String { rawValue }

    func apply(to adjustments: inout ImageAdjustments) {
        if self == .defaultPreset {
            adjustments = ImageAdjustments()
            return
        }

        adjustments.resetTonal()
        switch self {
        case .defaultPreset:
            break
        case .landscape:
            adjustments.contrast = 18
            adjustments.highlights = -20
            adjustments.shadows = 12
            adjustments.whites = 8
            adjustments.blacks = -10
            adjustments.temperature = 5600
            adjustments.vibrance = 28
            adjustments.saturation = 8
            adjustments.sharpening = 25
            adjustments.noiseReduction = 5
        case .portrait:
            adjustments.exposure = 0.1
            adjustments.contrast = -6
            adjustments.highlights = -12
            adjustments.shadows = 18
            adjustments.temperature = 5400
            adjustments.tint = 4
            adjustments.vibrance = 10
            adjustments.saturation = -4
            adjustments.sharpening = 5
            adjustments.noiseReduction = 12
        case .vivid:
            adjustments.contrast = 14
            adjustments.highlights = -10
            adjustments.whites = 8
            adjustments.blacks = -8
            adjustments.vibrance = 38
            adjustments.saturation = 16
            adjustments.sharpening = 18
        case .monochrome:
            adjustments.contrast = 22
            adjustments.highlights = -15
            adjustments.shadows = 8
            adjustments.whites = 10
            adjustments.blacks = -16
            adjustments.saturation = -100
            adjustments.sharpening = 20
        case .soft:
            adjustments.exposure = 0.15
            adjustments.contrast = -14
            adjustments.highlights = -18
            adjustments.shadows = 24
            adjustments.blacks = 6
            adjustments.temperature = 5650
            adjustments.vibrance = 6
            adjustments.saturation = -6
            adjustments.sharpening = -10
            adjustments.noiseReduction = 15
        }
    }
}

extension ImageAdjustments {
    mutating func resetTonal() {
        exposure = 0
        contrast = 0
        highlights = 0
        shadows = 0
        whites = 0
        blacks = 0
        temperature = 5200
        tint = 0
        vibrance = 0
        saturation = 0
        sharpening = 0
        noiseReduction = 0
        vignette = 0
        distortion = 0
    }
}
