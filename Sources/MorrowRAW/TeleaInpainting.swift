import CoreGraphics
import Foundation

/// Fast-marching frontier inpainting for small repair regions.
///
/// The frontier ordering and distance-weighted neighbourhood propagation follow
/// the practical structure of Telea's fast marching method. The implementation
/// deliberately operates on an 8-bit preview/export raster; RAW decoding and
/// the rest of the adjustment pipeline remain in Core Image.
enum TeleaInpainting {
    private struct FrontierNode {
        let distance: Int
        let index: Int
    }

    private struct MinHeap {
        private var values: [FrontierNode] = []

        var isEmpty: Bool { values.isEmpty }

        mutating func insert(_ node: FrontierNode) {
            values.append(node)
            var child = values.count - 1
            while child > 0 {
                let parent = (child - 1) / 2
                guard less(values[child], values[parent]) else { break }
                values.swapAt(child, parent)
                child = parent
            }
        }

        mutating func removeMin() -> FrontierNode? {
            guard !values.isEmpty else { return nil }
            if values.count == 1 { return values.removeLast() }
            let result = values[0]
            values[0] = values.removeLast()
            var parent = 0
            while true {
                let left = parent * 2 + 1
                guard left < values.count else { break }
                let right = left + 1
                var child = left
                if right < values.count && less(values[right], values[left]) {
                    child = right
                }
                guard less(values[child], values[parent]) else { break }
                values.swapAt(parent, child)
                parent = child
            }
            return result
        }

        private func less(_ lhs: FrontierNode, _ rhs: FrontierNode) -> Bool {
            lhs.distance == rhs.distance ? lhs.index < rhs.index : lhs.distance < rhs.distance
        }
    }

    /// Fills a circular target region while preserving a fractional brush strength.
    static func inpaint(_ image: CGImage, center: CGPoint, radius: Int,
                        strength: CGFloat = 1) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, radius > 0 else { return image }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: height * bytesPerRow)
        guard let context = CGContext(data: &bytes, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let original = bytes

        let cx = Int(center.x.rounded())
        let cy = Int(center.y.rounded())
        let radiusSquared = radius * radius
        let searchRadius = min(4, max(2, radius / 8 + 2))
        let infinity = Int.max / 4
        var unknown = [Bool](repeating: false, count: width * height)
        var distance = [Int](repeating: infinity, count: width * height)
        var heap = MinHeap()

        func inside(_ x: Int, _ y: Int) -> Bool {
            guard x >= 0, x < width, y >= 0, y < height else { return false }
            let dx = x - cx
            let dy = y - cy
            return dx * dx + dy * dy <= radiusSquared
        }

        let minX = max(0, cx - radius)
        let maxX = min(width - 1, cx + radius)
        let minY = max(0, cy - radius)
        let maxY = min(height - 1, cy + radius)

        for y in minY...maxY {
            for x in minX...maxX where inside(x, y) {
                unknown[y * width + x] = true
            }
        }

        let neighbours8 = [
            (-1, -1), (0, -1), (1, -1),
            (-1, 0),              (1, 0),
            (-1, 1),  (0, 1),  (1, 1)
        ]

        // The initial narrow band is the fast-marching boundary.
        for y in minY...maxY {
            for x in minX...maxX where unknown[y * width + x] {
                let isBoundary = neighbours8.contains { dx, dy in
                    let nx = x + dx
                    let ny = y + dy
                    return nx < 0 || nx >= width || ny < 0 || ny >= height || !inside(nx, ny)
                }
                if isBoundary {
                    let index = y * width + x
                    distance[index] = 0
                    heap.insert(FrontierNode(distance: 0, index: index))
                }
            }
        }

        let amount = max(0, min(1, strength))
        while let node = heap.removeMin() {
            let index = node.index
            guard unknown[index] else { continue }
            let x = index % width
            let y = index / width

            var red = CGFloat.zero
            var green = CGFloat.zero
            var blue = CGFloat.zero
            var totalWeight = CGFloat.zero

            for dy in -searchRadius...searchRadius {
                for dx in -searchRadius...searchRadius where dx != 0 || dy != 0 {
                    let nx = x + dx
                    let ny = y + dy
                    guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                    let neighbourIndex = ny * width + nx
                    guard !unknown[neighbourIndex] else { continue }
                    let squaredDistance = CGFloat(dx * dx + dy * dy)
                    guard squaredDistance > 0 else { continue }
                    let weight = 1 / squaredDistance
                    let byteIndex = neighbourIndex * 4
                    red += CGFloat(bytes[byteIndex]) * weight
                    green += CGFloat(bytes[byteIndex + 1]) * weight
                    blue += CGFloat(bytes[byteIndex + 2]) * weight
                    totalWeight += weight
                }
            }

            if totalWeight > 0 {
                let byteIndex = index * 4
                bytes[byteIndex] = blend(original[byteIndex], red / totalWeight, amount)
                bytes[byteIndex + 1] = blend(original[byteIndex + 1], green / totalWeight, amount)
                bytes[byteIndex + 2] = blend(original[byteIndex + 2], blue / totalWeight, amount)
            }
            unknown[index] = false

            for (dx, dy) in neighbours8 {
                let nx = x + dx
                let ny = y + dy
                guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                let neighbourIndex = ny * width + nx
                guard unknown[neighbourIndex] else { continue }
                let nextDistance = node.distance + 1
                if nextDistance < distance[neighbourIndex] {
                    distance[neighbourIndex] = nextDistance
                    heap.insert(FrontierNode(distance: nextDistance, index: neighbourIndex))
                }
            }
        }

        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height,
                       bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: bytesPerRow, space: colorSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true,
                       intent: .defaultIntent)
    }

    private static func blend(_ original: UInt8, _ replacement: CGFloat,
                              _ amount: CGFloat) -> UInt8 {
        let value = CGFloat(original) * (1 - amount) + replacement * amount
        return UInt8(max(0, min(255, value.rounded())))
    }
}
