import CoreImage
import CoreGraphics

enum WhiteBalanceSampler {
    private static let sRGBColorSpace = CGColorSpace(name: CGColorSpace.sRGB)

    // CIContext construction is relatively expensive and the context is
    // thread-safe. Reuse one for repeated eyedropper samples.
    private static let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.linearSRGB) as Any,
        .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any
    ])

    static func sample(source: CIImage, normalizedPoint: CGPoint) -> (temperature: Double, tint: Double)? {
        let extent = source.extent
        guard !extent.isEmpty else { return nil }
        let x = min(1, max(0, normalizedPoint.x))
        let y = min(1, max(0, normalizedPoint.y))
        let sampleSize = max(1, min(extent.width, extent.height) / 100)
        let rect = CGRect(x: extent.minX + x * extent.width - sampleSize / 2,
                          y: extent.minY + y * extent.height - sampleSize / 2,
                          width: sampleSize, height: sampleSize)
            .intersection(extent)
        guard !rect.isEmpty,
              let cgImage = context.createCGImage(source.cropped(to: rect), from: rect),
              let rgba = rgbaBytes(cgImage) else { return nil }

        let red = Double(rgba[0]) / 255
        let green = Double(rgba[1]) / 255
        let blue = Double(rgba[2]) / 255
        let temperature = min(12000, max(2000, 5200 + (red - blue) * 4200))
        let tint = min(100, max(-100, (green - (red + blue) / 2) * 240))
        return (temperature, tint)
    }

    private static func rgbaBytes(_ image: CGImage) -> [UInt8]? {
        guard let colorSpace = sRGBColorSpace,
              let context = CGContext(data: nil, width: 1, height: 1,
                                       bitsPerComponent: 8, bytesPerRow: 4,
                                       space: colorSpace,
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        return [bytes[0], bytes[1], bytes[2], bytes[3]]
    }
}
