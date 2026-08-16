import CoreGraphics
import Foundation

/// Fast, pixelwise Non-Local Means approximation for high-strength denoising.
///
/// The weighting follows the non-local averaging idea from Buades et al.:
/// pixels with similar local luminance receive larger weights even when they
/// are not immediate neighbours. To keep interactive RAW previews bounded,
/// this implementation uses a compact five-sample cross patch and a strided
/// search window. It is intentionally documented as an approximation, not as
/// a claim of full patch-NLM or BM3D reproduction. The renderer only invokes it
/// for bounded preview-sized rasters; full-resolution export uses the faster
/// Core Image fallback when the raster exceeds the safety limit.
enum NonLocalMeansDenoising {
    static func denoise(_ image: CGImage, strength: CGFloat) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return image }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let bytesPerRow = width * 4
        var source = [UInt8](repeating: 0, count: height * bytesPerRow)
        guard let context = CGContext(data: &source, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let amount = max(0, min(1, strength))
        let searchRadius = amount > 0.85 ? 5 : 4
        let searchStep = 2
        let h = 0.035 + amount * 0.11
        let hSquared = h * h
        var output = source

        func clamped(_ value: Int, _ limit: Int) -> Int {
            min(limit - 1, max(0, value))
        }

        func luminance(_ index: Int) -> CGFloat {
            let r = CGFloat(source[index]) / 255
            let g = CGFloat(source[index + 1]) / 255
            let b = CGFloat(source[index + 2]) / 255
            return 0.2126 * r + 0.7152 * g + 0.0722 * b
        }

        let cross = [(0, 0), (-1, 0), (1, 0), (0, -1), (0, 1)]
        for y in 0..<height {
            for x in 0..<width {
                let centerIndex = (y * width + x) * 4
                var red = CGFloat.zero
                var green = CGFloat.zero
                var blue = CGFloat.zero
                var totalWeight = CGFloat.zero

                for offsetY in Swift.stride(from: -searchRadius, through: searchRadius, by: searchStep) {
                    for offsetX in Swift.stride(from: -searchRadius, through: searchRadius, by: searchStep) {
                        let candidateX = clamped(x + offsetX, width)
                        let candidateY = clamped(y + offsetY, height)
                        let candidateIndex = (candidateY * width + candidateX) * 4

                        var patchError = CGFloat.zero
                        for (patchX, patchY) in cross {
                            let centerPatchX = clamped(x + patchX, width)
                            let centerPatchY = clamped(y + patchY, height)
                            let candidatePatchX = clamped(candidateX + patchX, width)
                            let candidatePatchY = clamped(candidateY + patchY, height)
                            let centerPatchIndex = (centerPatchY * width + centerPatchX) * 4
                            let candidatePatchIndex = (candidatePatchY * width + candidatePatchX) * 4
                            let delta = luminance(centerPatchIndex) - luminance(candidatePatchIndex)
                            patchError += delta * delta
                        }
                        patchError /= CGFloat(cross.count)

                        let weight = exp(-patchError / hSquared)
                        red += CGFloat(source[candidateIndex]) * weight
                        green += CGFloat(source[candidateIndex + 1]) * weight
                        blue += CGFloat(source[candidateIndex + 2]) * weight
                        totalWeight += weight
                    }
                }

                guard totalWeight > 0 else { continue }
                output[centerIndex] = UInt8(max(0, min(255, (red / totalWeight).rounded())))
                output[centerIndex + 1] = UInt8(max(0, min(255, (green / totalWeight).rounded())))
                output[centerIndex + 2] = UInt8(max(0, min(255, (blue / totalWeight).rounded())))
            }
        }

        guard let provider = CGDataProvider(data: Data(output) as CFData) else { return nil }
        return CGImage(width: width, height: height,
                       bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: bytesPerRow, space: colorSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true,
                       intent: .defaultIntent)
    }
}
