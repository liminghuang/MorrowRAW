import CoreGraphics
import Foundation

/// Small-region Poisson image editing for clone repair.
///
/// The solver preserves source gradients while using the target image as the
/// boundary condition. Jacobi iterations are sufficient for the brush-sized
/// regions used by the repair tool and avoid introducing a third-party solver.
/// This follows the gradient-domain formulation of Pérez, Gangnet and Blake.
enum PoissonClone {
    static func blend(_ image: CGImage, sourceCenter: CGPoint,
                      targetCenter: CGPoint, radius: Int,
                      strength: CGFloat = 1) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, radius > 0 else { return image }

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

        let tx = Int(targetCenter.x.rounded())
        let ty = Int(targetCenter.y.rounded())
        let sx = Int(sourceCenter.x.rounded())
        let sy = Int(sourceCenter.y.rounded())
        let radiusSquared = radius * radius
        let minX = max(0, tx - radius)
        let maxX = min(width - 1, tx + radius)
        let minY = max(0, ty - radius)
        let maxY = min(height - 1, ty + radius)
        guard minX <= maxX, minY <= maxY else { return image }

        func inside(_ x: Int, _ y: Int) -> Bool {
            let dx = x - tx
            let dy = y - ty
            return dx * dx + dy * dy <= radiusSquared
        }

        let neighbours = [(1, 0), (-1, 0), (0, 1), (0, -1)]
        var estimate = source
        let iterations = min(120, max(32, radius * 2))

        for _ in 0..<iterations {
            var next = estimate
            for y in minY...maxY {
                for x in minX...maxX where inside(x, y) {
                    let targetIndex = (y * width + x) * 4
                    var sums = [Double](repeating: 0, count: 3)
                    var count = 0.0

                    for (dx, dy) in neighbours {
                        let nx = x + dx
                        let ny = y + dy
                        guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                        let neighbourTargetIndex = (ny * width + nx) * 4
                        let sourceX = sx + (nx - tx)
                        let sourceY = sy + (ny - ty)
                        guard sourceX >= 0, sourceX < width,
                              sourceY >= 0, sourceY < height else { continue }
                        let sourceIndex = (sourceY * width + sourceX) * 4
                        let sourceCurrentX = sx + (x - tx)
                        let sourceCurrentY = sy + (y - ty)
                        guard sourceCurrentX >= 0, sourceCurrentX < width,
                              sourceCurrentY >= 0, sourceCurrentY < height else { continue }
                        let sourceCurrentIndex = (sourceCurrentY * width + sourceCurrentX) * 4

                        for channel in 0..<3 {
                            let gradient = Double(source[sourceCurrentIndex + channel])
                                - Double(source[sourceIndex + channel])
                            let neighbourValue: Double
                            if inside(nx, ny) {
                                neighbourValue = Double(estimate[neighbourTargetIndex + channel]) + gradient
                            } else {
                                neighbourValue = Double(source[neighbourTargetIndex + channel]) + gradient
                            }
                            sums[channel] += neighbourValue
                        }
                        count += 1
                    }

                    guard count > 0 else { continue }
                    for channel in 0..<3 {
                        next[targetIndex + channel] = UInt8(max(0, min(255,
                            (sums[channel] / count).rounded())))
                    }
                }
            }
            estimate = next
        }

        let amount = max(0, min(1, strength))
        for y in minY...maxY {
            for x in minX...maxX where inside(x, y) {
                let index = (y * width + x) * 4
                for channel in 0..<3 {
                    let value = CGFloat(source[index + channel]) * (1 - amount)
                        + CGFloat(estimate[index + channel]) * amount
                    estimate[index + channel] = UInt8(max(0, min(255, value.rounded())))
                }
            }
        }

        guard let provider = CGDataProvider(data: Data(estimate) as CFData) else { return nil }
        return CGImage(width: width, height: height,
                       bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: bytesPerRow, space: colorSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true,
                       intent: .defaultIntent)
    }
}
