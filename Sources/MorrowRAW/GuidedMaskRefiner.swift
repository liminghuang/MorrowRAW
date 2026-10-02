import CoreGraphics

/// CPU reference implementation of the grayscale guided filter. It is used
/// only for semantic masks during final/export rendering; interactive brush
/// feedback keeps the cheaper analytic mask.
enum GuidedMaskRefiner {
    static func refine(mask: CGImage, guide: CGImage,
                       radius: Int = 8, epsilon: Float = 0.01) -> CGImage? {
        let width = min(512, max(1, mask.width))
        let height = max(1, Int((Double(mask.height) * Double(width) / Double(max(1, mask.width))).rounded()))
        guard let maskPixels = Raster(image: mask, width: width, height: height),
              let guidePixels = Raster(image: guide, width: width, height: height) else { return nil }
        let count = width * height
        var input = [Float](repeating: 0, count: count)
        var guidance = [Float](repeating: 0, count: count)
        for index in 0..<count {
            input[index] = maskPixels.gray[index]
            guidance[index] = guidePixels.luminance[index]
        }

        let meanInput = boxMean(input, width: width, height: height, radius: radius)
        let meanGuide = boxMean(guidance, width: width, height: height, radius: radius)
        let guideSquared = zip(guidance, guidance).map { $0 * $1 }
        let guideInput = zip(guidance, input).map { $0 * $1 }
        let meanGuideSquared = boxMean(guideSquared, width: width, height: height, radius: radius)
        let meanGuideInput = boxMean(guideInput, width: width, height: height, radius: radius)
        var coefficients = [Float](repeating: 0, count: count)
        var intercepts = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let variance = meanGuideSquared[index] - meanGuide[index] * meanGuide[index]
            let covariance = meanGuideInput[index] - meanGuide[index] * meanInput[index]
            let coefficient = covariance / max(0.00001, variance + epsilon)
            coefficients[index] = coefficient
            intercepts[index] = meanInput[index] - coefficient * meanGuide[index]
        }
        let meanCoefficients = boxMean(coefficients, width: width, height: height, radius: radius)
        let meanIntercepts = boxMean(intercepts, width: width, height: height, radius: radius)
        var output = [UInt8](repeating: 255, count: count * 4)
        for index in 0..<count {
            let value = min(1, max(0, meanCoefficients[index] * guidance[index] + meanIntercepts[index]))
            let byte = UInt8((value * 255).rounded())
            output[index * 4] = byte
            output[index * 4 + 1] = byte
            output[index * 4 + 2] = byte
        }
        guard let context = CGContext(data: &output, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        return context.makeImage()
    }

    private static func boxMean(_ values: [Float], width: Int, height: Int, radius: Int) -> [Float] {
        var integral = [Double](repeating: 0, count: (width + 1) * (height + 1))
        for y in 0..<height {
            var row = 0.0
            for x in 0..<width {
                row += Double(values[y * width + x])
                let index = (y + 1) * (width + 1) + (x + 1)
                integral[index] = integral[y * (width + 1) + (x + 1)] + row
            }
        }
        var result = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let y0 = max(0, y - radius)
            let y1 = min(height - 1, y + radius)
            for x in 0..<width {
                let x0 = max(0, x - radius)
                let x1 = min(width - 1, x + radius)
                let bottomRight = integral[(y1 + 1) * (width + 1) + (x1 + 1)]
                let topRight = integral[y0 * (width + 1) + (x1 + 1)]
                let bottomLeft = integral[(y1 + 1) * (width + 1) + x0]
                let topLeft = integral[y0 * (width + 1) + x0]
                let area = Double((x1 - x0 + 1) * (y1 - y0 + 1))
                result[y * width + x] = Float((bottomRight - topRight - bottomLeft + topLeft) / area)
            }
        }
        return result
    }

    private struct Raster {
        let gray: [Float]
        let luminance: [Float]

        init?(image: CGImage, width: Int, height: Int) {
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            guard let context = CGContext(data: &bytes, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            var gray = [Float](repeating: 0, count: width * height)
            var luminance = [Float](repeating: 0, count: width * height)
            for index in 0..<(width * height) {
                let offset = index * 4
                gray[index] = Float(bytes[offset]) / 255
                luminance[index] = (0.2126 * Float(bytes[offset]) +
                                    0.7152 * Float(bytes[offset + 1]) +
                                    0.0722 * Float(bytes[offset + 2])) / 255
            }
            self.gray = gray
            self.luminance = luminance
        }
    }
}
