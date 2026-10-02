import CoreGraphics

/// CPU reference implementation of the RGB guided filter. It is used
/// only for semantic masks during final/export rendering; interactive brush
/// feedback keeps the cheaper analytic mask.
enum GuidedMaskRefiner {
    static func resized(_ image: CGImage, maxDimension: Int = 512) -> CGImage? {
        let scale = min(1, CGFloat(maxDimension) / CGFloat(max(image.width, image.height)))
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    static func resized(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    static func refine(mask: CGImage, guide: CGImage,
                       radius: Int = 8, epsilon: Float = 0.01) -> CGImage? {
        let width = min(512, max(1, mask.width))
        let height = max(1, Int((Double(mask.height) * Double(width) / Double(max(1, mask.width))).rounded()))
        guard let maskPixels = Raster(image: mask, width: width, height: height),
              let guidePixels = Raster(image: guide, width: width, height: height) else { return nil }
        let count = width * height
        let input = maskPixels.gray
        let red = guidePixels.red
        let green = guidePixels.green
        let blue = guidePixels.blue
        let meanInput = boxMean(input, width: width, height: height, radius: radius)
        let meanRed = boxMean(red, width: width, height: height, radius: radius)
        let meanGreen = boxMean(green, width: width, height: height, radius: radius)
        let meanBlue = boxMean(blue, width: width, height: height, radius: radius)
        let meanRR = boxMean(red.map { $0 * $0 }, width: width, height: height, radius: radius)
        let meanRG = boxMean(zip(red, green).map { $0 * $1 }, width: width, height: height, radius: radius)
        let meanRB = boxMean(zip(red, blue).map { $0 * $1 }, width: width, height: height, radius: radius)
        let meanGG = boxMean(green.map { $0 * $0 }, width: width, height: height, radius: radius)
        let meanGB = boxMean(zip(green, blue).map { $0 * $1 }, width: width, height: height, radius: radius)
        let meanBB = boxMean(blue.map { $0 * $0 }, width: width, height: height, radius: radius)
        let meanRP = boxMean(zip(red, input).map { $0 * $1 }, width: width, height: height, radius: radius)
        let meanGP = boxMean(zip(green, input).map { $0 * $1 }, width: width, height: height, radius: radius)
        let meanBP = boxMean(zip(blue, input).map { $0 * $1 }, width: width, height: height, radius: radius)
        var coefficientRed = [Float](repeating: 0, count: count)
        var coefficientGreen = [Float](repeating: 0, count: count)
        var coefficientBlue = [Float](repeating: 0, count: count)
        var intercepts = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let r = meanRed[index], g = meanGreen[index], b = meanBlue[index]
            let covariance: [[Double]] = [
                [Double(meanRR[index] - r * r + epsilon), Double(meanRG[index] - r * g), Double(meanRB[index] - r * b)],
                [Double(meanRG[index] - r * g), Double(meanGG[index] - g * g + epsilon), Double(meanGB[index] - g * b)],
                [Double(meanRB[index] - r * b), Double(meanGB[index] - g * b), Double(meanBB[index] - b * b + epsilon)]
            ]
            let vector = [Double(meanRP[index] - r * meanInput[index]),
                          Double(meanGP[index] - g * meanInput[index]),
                          Double(meanBP[index] - b * meanInput[index])]
            let coefficients = solve(covariance, vector)
            coefficientRed[index] = Float(coefficients[0])
            coefficientGreen[index] = Float(coefficients[1])
            coefficientBlue[index] = Float(coefficients[2])
            intercepts[index] = meanInput[index] -
                coefficientRed[index] * r - coefficientGreen[index] * g - coefficientBlue[index] * b
        }
        let meanCoefficientsRed = boxMean(coefficientRed, width: width, height: height, radius: radius)
        let meanCoefficientsGreen = boxMean(coefficientGreen, width: width, height: height, radius: radius)
        let meanCoefficientsBlue = boxMean(coefficientBlue, width: width, height: height, radius: radius)
        let meanIntercepts = boxMean(intercepts, width: width, height: height, radius: radius)
        var output = [UInt8](repeating: 255, count: count * 4)
        for index in 0..<count {
            let value = min(1, max(0, meanCoefficientsRed[index] * red[index] +
                meanCoefficientsGreen[index] * green[index] +
                meanCoefficientsBlue[index] * blue[index] + meanIntercepts[index]))
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
        let red: [Float]
        let green: [Float]
        let blue: [Float]
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
            var red = [Float](repeating: 0, count: width * height)
            var green = [Float](repeating: 0, count: width * height)
            var blue = [Float](repeating: 0, count: width * height)
            var luminance = [Float](repeating: 0, count: width * height)
            for index in 0..<(width * height) {
                let offset = index * 4
                red[index] = Float(bytes[offset]) / 255
                green[index] = Float(bytes[offset + 1]) / 255
                blue[index] = Float(bytes[offset + 2]) / 255
                gray[index] = red[index]
                luminance[index] = 0.2126 * red[index] + 0.7152 * green[index] + 0.0722 * blue[index]
            }
            self.gray = gray
            self.red = red
            self.green = green
            self.blue = blue
            self.luminance = luminance
        }
    }

    private static func solve(_ matrix: [[Double]], _ vector: [Double]) -> [Double] {
        var augmented = (0..<3).map { row in matrix[row] + [vector[row]] }
        for pivot in 0..<3 {
            guard let row = (pivot..<3).max(by: { abs(augmented[$0][pivot]) < abs(augmented[$1][pivot]) }),
                  abs(augmented[row][pivot]) > 0.0000001 else { continue }
            augmented.swapAt(pivot, row)
            let divisor = augmented[pivot][pivot]
            for column in pivot..<4 { augmented[pivot][column] /= divisor }
            for row in 0..<3 where row != pivot {
                let factor = augmented[row][pivot]
                for column in pivot..<4 { augmented[row][column] -= factor * augmented[pivot][column] }
            }
        }
        return [augmented[0][3], augmented[1][3], augmented[2][3]]
    }
}
