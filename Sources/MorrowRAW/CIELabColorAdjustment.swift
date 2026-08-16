import CoreGraphics
import Foundation

/// CIE L*a*b* chroma adjustment for preview-sized images.
///
/// Saturation and vibrance are applied to a perceptual chroma vector instead
/// of independently scaling RGB channels. This keeps L* separate from a*/b*
/// and reduces the luma shifts caused by direct RGB saturation operations.
enum CIELabColorAdjustment {
    static func adjust(_ image: CGImage, saturation: CGFloat,
                       vibrance: CGFloat) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return image }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: height * bytesPerRow)
        guard let context = CGContext(data: &bytes, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let saturationAmount = max(-1, min(1, saturation))
        let vibranceAmount = max(-1, min(1, vibrance))
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let r = CGFloat(bytes[index]) / 255
            let g = CGFloat(bytes[index + 1]) / 255
            let b = CGFloat(bytes[index + 2]) / 255
            let lab = rgbToLab(r, g, b)
            let chroma = sqrt(lab.a * lab.a + lab.b * lab.b)
            let lowChromaWeight = max(0, 1 - min(1, chroma / 100))
            let factor = 1 + saturationAmount + vibranceAmount * lowChromaWeight
            let rgb = labToRGB(lab.l, lab.a * factor, lab.b * factor)
            bytes[index] = toByte(rgb.r)
            bytes[index + 1] = toByte(rgb.g)
            bytes[index + 2] = toByte(rgb.b)
        }

        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height,
                       bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: bytesPerRow, space: colorSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true,
                       intent: .defaultIntent)
    }

    private struct Lab {
        let l: CGFloat
        let a: CGFloat
        let b: CGFloat
    }

    private struct RGB {
        let r: CGFloat
        let g: CGFloat
        let b: CGFloat
    }

    private static func rgbToLab(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> Lab {
        let rl = linearize(r)
        let gl = linearize(g)
        let bl = linearize(b)
        let x = (0.4124564 * rl + 0.3575761 * gl + 0.1804375 * bl) / 0.95047
        let y = 0.2126729 * rl + 0.7151522 * gl + 0.0721750 * bl
        let z = (0.0193339 * rl + 0.1191920 * gl + 0.9503041 * bl) / 1.08883
        let fx = labPivot(x)
        let fy = labPivot(y)
        let fz = labPivot(z)
        return Lab(l: 116 * fy - 16, a: 500 * (fx - fy), b: 200 * (fy - fz))
    }

    private static func labToRGB(_ l: CGFloat, _ a: CGFloat, _ b: CGFloat) -> RGB {
        let fy = (l + 16) / 116
        let fx = fy + a / 500
        let fz = fy - b / 200
        let x = 0.95047 * inverseLabPivot(fx)
        let y = inverseLabPivot(fy)
        let z = 1.08883 * inverseLabPivot(fz)
        let r = 3.2404542 * x - 1.5371385 * y - 0.4985314 * z
        let g = -0.9692660 * x + 1.8760108 * y + 0.0415560 * z
        let blue = 0.0556434 * x - 0.2040259 * y + 1.0572252 * z
        return RGB(r: delinearize(r), g: delinearize(g), b: delinearize(blue))
    }

    private static func linearize(_ value: CGFloat) -> CGFloat {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    private static func delinearize(_ value: CGFloat) -> CGFloat {
        let clamped = max(0, value)
        return clamped <= 0.0031308
            ? clamped * 12.92
            : 1.055 * pow(clamped, 1 / 2.4) - 0.055
    }

    private static func labPivot(_ value: CGFloat) -> CGFloat {
        let epsilon = 216.0 / 24389.0
        let kappa = 24389.0 / 27.0
        return value > epsilon ? pow(value, 1.0 / 3.0) : (kappa * value + 16) / 116
    }

    private static func inverseLabPivot(_ value: CGFloat) -> CGFloat {
        let epsilon = 216.0 / 24389.0
        let kappa = 24389.0 / 27.0
        let cube = value * value * value
        return cube > epsilon ? cube : (116 * value - 16) / kappa
    }

    private static func toByte(_ value: CGFloat) -> UInt8 {
        UInt8(max(0, min(255, (value * 255).rounded())))
    }
}
