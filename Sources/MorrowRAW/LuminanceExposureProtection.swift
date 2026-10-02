import Foundation

enum LuminanceExposureProtection {
    static func outputLuminance(_ luminance: Double, exposure: Double) -> Double {
        let y = min(1, max(0, luminance))
        guard exposure.isFinite, abs(exposure) > 0.000001 else { return y }
        let gain = pow(2, exposure)
        if gain > 1 {
            let threshold = 0.6 / gain
            guard y > threshold else { return min(1, y * gain) }
            guard y < 1 else { return y }
            let distance = y - threshold
            let denominator = gain / 0.4 - 1 / max(0.0001, 1 - threshold)
            return min(1, max(0, 0.6 + gain * distance / max(0.0001, 1 + denominator * distance)))
        }
        return y * (gain + (1 - gain) * 0.02 / (y + 0.02))
    }
}
