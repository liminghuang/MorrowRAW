import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

enum RenderQuality: Equatable {
    case interactive
    case finalPreview
    case export

    var previewDimension: CGFloat {
        switch self {
        // Keep drag feedback light enough for high-resolution RAW sources;
        // the full-size refinement runs after the interaction ends.
        case .interactive: return 720
        case .finalPreview: return 2400
        case .export: return .greatestFiniteMagnitude
        }
    }

    var repairIterationScale: CGFloat {
        switch self {
        case .interactive: return 0.35
        case .finalPreview, .export: return 1
        }
    }
}

final class ImageRenderer {
    /// CIContext is thread-safe and expensive to construct. Interactive
    /// previews share one context instead of creating one for every slider
    /// render task.
    static let shared = ImageRenderer()

    private static let toneCurveCache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.countLimit = 64
        return cache
    }()

    private let context: CIContext

    init() {
        context = CIContext(options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.linearSRGB) as Any,
            .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any
        ])
    }

    func render(_ image: CIImage, adjustments: ImageAdjustments,
                quality: RenderQuality = .export) -> CIImage {
        var output = image

        if adjustments.exposure != 0 {
            let filter = CIFilter.exposureAdjust()
            filter.inputImage = output
            filter.ev = Float(adjustments.exposure)
            output = filter.outputImage ?? output
        }

        if adjustments.temperature != 5200 || adjustments.tint != 0 {
            let filter = CIFilter.temperatureAndTint()
            filter.inputImage = output
            filter.neutral = CIVector(x: 5200, y: 0)
            filter.targetNeutral = CIVector(x: adjustments.temperature,
                                            y: adjustments.tint)
            output = filter.outputImage ?? output
        }

        if adjustments.contrast != 0 {
            let filter = CIFilter.colorControls()
            filter.inputImage = output
            filter.contrast = Float(1 + adjustments.contrast / 100)
            output = filter.outputImage ?? output
        }

        if adjustments.saturation != 0 || adjustments.vibrance != 0 {
            output = perceptualColorAdjust(output, saturation: adjustments.saturation,
                                           vibrance: adjustments.vibrance) ??
                fallbackColorAdjust(output, saturation: adjustments.saturation,
                                    vibrance: adjustments.vibrance)
        }

        if adjustments.highlights != 0 || adjustments.shadows != 0 ||
            adjustments.whites != 0 || adjustments.blacks != 0 {
            output = applyToneCurve(to: output, adjustments: adjustments)
        }

        if adjustments.noiseReduction > 0 {
            if adjustments.noiseReduction >= 65 {
                output = nonLocalMeansDenoise(output, strength: adjustments.noiseReduction)
                    ?? fastNoiseReduction(output, strength: adjustments.noiseReduction)
            } else {
                output = fastNoiseReduction(output, strength: adjustments.noiseReduction)
            }
        }

        if adjustments.sharpening != 0 {
            if adjustments.sharpening > 0 {
                let filter = CIFilter(name: "CISharpenLuminance")
                filter?.setValue(output, forKey: kCIInputImageKey)
                filter?.setValue(Float(adjustments.sharpening / 50), forKey: kCIInputSharpnessKey)
                output = filter?.outputImage ?? output
            } else {
                let extent = output.extent
                let filter = CIFilter(name: "CIGaussianBlur")
                filter?.setValue(output, forKey: kCIInputImageKey)
                filter?.setValue(Float((-adjustments.sharpening) / 100 * 2), forKey: kCIInputRadiusKey)
                output = (filter?.outputImage ?? output).cropped(to: extent)
            }
        }

        if !adjustments.gradients.isEmpty {
            output = applyGradients(to: output, gradients: adjustments.gradients)
        }

        if !adjustments.healSpots.isEmpty {
            output = applyHealSpots(to: output, spots: adjustments.healSpots, quality: quality)
        }

        if adjustments.distortion != 0 {
            output = MetalImageProcessor.shared.brownConrady(
                output, amount: adjustments.distortion, context: context
            ) ?? BrownConradyDistortion.apply(to: output, amount: adjustments.distortion)
        }

        output = applyGeometry(to: output, adjustments: adjustments)

        if adjustments.vignette != 0 {
            let filter = CIFilter.vignetteEffect()
            filter.inputImage = output
            filter.intensity = Float(adjustments.vignette / 100)
            filter.radius = Float(max(output.extent.width, output.extent.height) * 0.7)
            filter.falloff = 0.6
            output = filter.outputImage ?? output
        }

        return output
    }

    /// Asynchronous preview pipeline. Core Image graph construction remains
    /// cheap and synchronous; Metal stages suspend until their command buffer
    /// completion instead of blocking a worker on `waitUntilCompleted()`.
    func renderAsync(_ image: CIImage, adjustments: ImageAdjustments,
                     quality: RenderQuality = .finalPreview) async -> CIImage {
        var output = image

        if adjustments.exposure != 0 {
            let filter = CIFilter.exposureAdjust()
            filter.inputImage = output
            filter.ev = Float(adjustments.exposure)
            output = filter.outputImage ?? output
        }
        if adjustments.temperature != 5200 || adjustments.tint != 0 {
            let filter = CIFilter.temperatureAndTint()
            filter.inputImage = output
            filter.neutral = CIVector(x: 5200, y: 0)
            filter.targetNeutral = CIVector(x: adjustments.temperature, y: adjustments.tint)
            output = filter.outputImage ?? output
        }
        if adjustments.contrast != 0 {
            let filter = CIFilter.colorControls()
            filter.inputImage = output
            filter.contrast = Float(1 + adjustments.contrast / 100)
            output = filter.outputImage ?? output
        }
        if adjustments.saturation != 0 || adjustments.vibrance != 0 {
            if output.extent.width * output.extent.height <= 4_000_000,
               let adjusted = await MetalImageProcessor.shared.labChromaAsync(
                output, saturation: CGFloat(adjustments.saturation / 100),
                vibrance: CGFloat(adjustments.vibrance / 100), context: context
               ) {
                output = adjusted
            } else {
                output = fallbackColorAdjust(output, saturation: adjustments.saturation,
                                             vibrance: adjustments.vibrance)
            }
        }
        if adjustments.highlights != 0 || adjustments.shadows != 0 ||
            adjustments.whites != 0 || adjustments.blacks != 0 {
            output = applyToneCurve(to: output, adjustments: adjustments)
        }
        if adjustments.noiseReduction >= 65,
           quality != .interactive,
           output.extent.width * output.extent.height <= 4_000_000,
           let denoised = await MetalImageProcessor.shared.nonLocalMeansAsync(
            output, strength: CGFloat(adjustments.noiseReduction / 100), context: context
           ) {
            output = denoised
        } else if adjustments.noiseReduction > 0 {
            output = fastNoiseReduction(output, strength: adjustments.noiseReduction)
        }
        if adjustments.sharpening != 0 {
            if adjustments.sharpening > 0 {
                let filter = CIFilter(name: "CISharpenLuminance")
                filter?.setValue(output, forKey: kCIInputImageKey)
                filter?.setValue(Float(adjustments.sharpening / 50), forKey: kCIInputSharpnessKey)
                output = filter?.outputImage ?? output
            } else {
                let extent = output.extent
                let filter = CIFilter(name: "CIGaussianBlur")
                filter?.setValue(output, forKey: kCIInputImageKey)
                filter?.setValue(Float((-adjustments.sharpening) / 100 * 2), forKey: kCIInputRadiusKey)
                output = (filter?.outputImage ?? output).cropped(to: extent)
            }
        }
        if !adjustments.gradients.isEmpty {
            output = applyGradients(to: output, gradients: adjustments.gradients)
        }
        if !adjustments.healSpots.isEmpty {
            output = await applyHealSpotsAsync(to: output, spots: adjustments.healSpots, quality: quality)
        }
        if adjustments.distortion != 0 {
            output = await MetalImageProcessor.shared.brownConradyAsync(
                output, amount: adjustments.distortion, context: context
            ) ?? BrownConradyDistortion.apply(to: output, amount: adjustments.distortion)
        }
        output = applyGeometry(to: output, adjustments: adjustments)
        if adjustments.vignette != 0 {
            let filter = CIFilter.vignetteEffect()
            filter.inputImage = output
            filter.intensity = Float(adjustments.vignette / 100)
            filter.radius = Float(max(output.extent.width, output.extent.height) * 0.7)
            filter.falloff = 0.6
            output = filter.outputImage ?? output
        }
        return output
    }

    private func fastNoiseReduction(_ image: CIImage, strength: Double) -> CIImage {
        let filter = CIFilter(name: "CINoiseReduction")
        filter?.setValue(image, forKey: kCIInputImageKey)
        filter?.setValue(Float(strength / 100), forKey: "inputNoiseLevel")
        filter?.setValue(Float(0.5 + strength / 200), forKey: "inputSharpness")
        return filter?.outputImage ?? image
    }

    private func perceptualColorAdjust(_ image: CIImage, saturation: Double,
                                       vibrance: Double) -> CIImage? {
        let extent = image.extent
        guard extent.width * extent.height <= 4_000_000 else { return nil }
        return MetalImageProcessor.shared.labChroma(
            image, saturation: CGFloat(saturation / 100),
            vibrance: CGFloat(vibrance / 100), context: context
        ) ?? cpuPerceptualColorAdjust(image, saturation: saturation, vibrance: vibrance)
    }

    private func cpuPerceptualColorAdjust(_ image: CIImage, saturation: Double,
                                          vibrance: Double) -> CIImage? {
        let extent = image.extent
        guard let raster = context.createCGImage(image, from: extent),
              let adjusted = CIELabColorAdjustment.adjust(
                raster, saturation: CGFloat(saturation / 100),
                vibrance: CGFloat(vibrance / 100)
              ) else { return nil }
        return CIImage(cgImage: adjusted)
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)
    }

    private func fallbackColorAdjust(_ image: CIImage, saturation: Double,
                                     vibrance: Double) -> CIImage {
        var output = image
        if saturation != 0 {
            let filter = CIFilter.colorControls()
            filter.inputImage = output
            filter.saturation = Float(1 + saturation / 100)
            output = filter.outputImage ?? output
        }
        if vibrance != 0 {
            let filter = CIFilter(name: "CIVibrance")
            filter?.setValue(output, forKey: kCIInputImageKey)
            filter?.setValue(Float(vibrance / 100), forKey: kCIInputAmountKey)
            output = filter?.outputImage ?? output
        }
        return output
    }

    private func nonLocalMeansDenoise(_ image: CIImage, strength: Double) -> CIImage? {
        let extent = image.extent
        guard extent.width * extent.height <= 4_000_000 else { return nil }
        if let denoised = MetalImageProcessor.shared.nonLocalMeans(
            image, strength: CGFloat(strength / 100), context: context
        ) { return denoised }
        guard let raster = context.createCGImage(image, from: extent),
              let denoised = NonLocalMeansDenoising.denoise(
                raster, strength: CGFloat(strength / 100)
              ) else { return nil }
        return CIImage(cgImage: denoised)
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)
    }

    private func applyHealSpots(to image: CIImage, spots: [HealSpot], quality: RenderQuality) -> CIImage {
        let extent = image.extent
        let maxDimension = max(extent.width, extent.height)
        var output = image

        for spot in spots {
            let target = CGPoint(x: extent.minX + spot.targetX * extent.width,
                                 y: extent.minY + spot.targetY * extent.height)
            let source = CGPoint(x: extent.minX + spot.sourceX * extent.width,
                                 y: extent.minY + spot.sourceY * extent.height)
            let radius = max(1, spot.radiusNorm * maxDimension)

            let replacement: CIImage
            if spot.useInpaint {
                replacement = teleaInpaint(output, target: target, radius: radius,
                                           strength: CGFloat(spot.strength),
                                           iterationScale: quality.repairIterationScale, extent: extent)
                    ?? fallbackInpaint(output, radius: radius, extent: extent)
            } else {
                replacement = poissonClone(output, target: target, source: source,
                                           radius: radius, strength: CGFloat(spot.strength),
                                           iterationScale: quality.repairIterationScale,
                                           extent: extent) ?? output.transformed(by: CGAffineTransform(
                                            translationX: target.x - source.x, y: target.y - source.y))
            }

            let mask = CIFilter(name: "CIRadialGradient")
            mask?.setValue(CIVector(x: target.x, y: target.y), forKey: "inputCenter")
            mask?.setValue(Float(radius * 0.55), forKey: "inputRadius0")
            mask?.setValue(Float(radius), forKey: "inputRadius1")
            mask?.setValue(CIColor.white, forKey: "inputColor0")
            mask?.setValue(CIColor.clear, forKey: "inputColor1")

            let strength = min(1, max(0, spot.strength))
            let strengthImage = CIImage(color: CIColor(red: CGFloat(strength),
                                                        green: CGFloat(strength),
                                                        blue: CGFloat(strength)))
                .cropped(to: extent)
            let strengthMask = CIFilter(name: "CIMultiplyCompositing")
            strengthMask?.setValue(mask?.outputImage, forKey: kCIInputImageKey)
            strengthMask?.setValue(strengthImage, forKey: kCIInputBackgroundImageKey)

            let blend = CIFilter(name: "CIBlendWithMask")
            blend?.setValue(replacement, forKey: kCIInputImageKey)
            blend?.setValue(output, forKey: kCIInputBackgroundImageKey)
            blend?.setValue(strengthMask?.outputImage ?? mask?.outputImage, forKey: kCIInputMaskImageKey)
            output = (blend?.outputImage ?? output).cropped(to: extent)
        }
        return output
    }

    private func applyHealSpotsAsync(to image: CIImage, spots: [HealSpot],
                                     quality: RenderQuality) async -> CIImage {
        if spots.count > 1, canProcessHealSpotsConcurrently(spots) {
            return await applyIndependentHealSpotsAsync(to: image, spots: spots, quality: quality)
        }
        let extent = image.extent
        let maxDimension = max(extent.width, extent.height)
        var output = image
        for spot in spots {
            let target = CGPoint(x: extent.minX + spot.targetX * extent.width,
                                 y: extent.minY + spot.targetY * extent.height)
            let source = CGPoint(x: extent.minX + spot.sourceX * extent.width,
                                 y: extent.minY + spot.sourceY * extent.height)
            let radius = max(1, spot.radiusNorm * maxDimension)
            let replacement: CIImage
            if spot.useInpaint {
                replacement = await teleaInpaintAsync(
                    output, target: target, radius: radius, strength: CGFloat(spot.strength),
                    iterationScale: quality.repairIterationScale, extent: extent
                ) ?? output
            } else {
                replacement = await poissonCloneAsync(
                    output, target: target, source: source, radius: radius,
                    strength: CGFloat(spot.strength), iterationScale: quality.repairIterationScale,
                    extent: extent
                ) ?? output
            }
            let mask = CIFilter(name: "CIRadialGradient")
            mask?.setValue(CIVector(x: target.x, y: target.y), forKey: "inputCenter")
            mask?.setValue(Float(radius * 0.55), forKey: "inputRadius0")
            mask?.setValue(Float(radius), forKey: "inputRadius1")
            mask?.setValue(CIColor.white, forKey: "inputColor0")
            mask?.setValue(CIColor.clear, forKey: "inputColor1")
            let strength = min(1, max(0, spot.strength))
            let strengthImage = CIImage(color: CIColor(red: CGFloat(strength), green: CGFloat(strength), blue: CGFloat(strength)))
                .cropped(to: extent)
            let strengthMask = CIFilter(name: "CIMultiplyCompositing")
            strengthMask?.setValue(mask?.outputImage, forKey: kCIInputImageKey)
            strengthMask?.setValue(strengthImage, forKey: kCIInputBackgroundImageKey)
            let blend = CIFilter(name: "CIBlendWithMask")
            blend?.setValue(replacement, forKey: kCIInputImageKey)
            blend?.setValue(output, forKey: kCIInputBackgroundImageKey)
            blend?.setValue(strengthMask?.outputImage ?? mask?.outputImage, forKey: kCIInputMaskImageKey)
            output = (blend?.outputImage ?? output).cropped(to: extent)
        }
        return output
    }

    private func canProcessHealSpotsConcurrently(_ spots: [HealSpot]) -> Bool {
        for lhsIndex in spots.indices {
            for rhsIndex in spots.indices where rhsIndex > lhsIndex {
                let lhs = spots[lhsIndex]
                let rhs = spots[rhsIndex]
                let dx = lhs.targetX - rhs.targetX
                let dy = lhs.targetY - rhs.targetY
                let distance = sqrt(dx * dx + dy * dy)
                if distance <= lhs.radiusNorm + rhs.radiusNorm { return false }
            }
        }
        return true
    }

    private func applyIndependentHealSpotsAsync(to image: CIImage, spots: [HealSpot],
                                                quality: RenderQuality) async -> CIImage {
        let extent = image.extent
        let maxDimension = max(extent.width, extent.height)
        let base = image
        let replacements = await withTaskGroup(of: [(Int, CIImage?)].self,
                                                returning: [(Int, CIImage?)].self) { group in
            // Independent spots can overlap GPU work, but launching one task
            // per spot creates an unbounded number of command buffers and
            // scratch textures. Two workers preserve useful parallelism while
            // keeping the VRAM peak predictable.
            let workerCount = min(2, spots.count)
            for worker in 0..<workerCount {
                group.addTask { [self] in
                    var workerResults: [(Int, CIImage?)] = []
                    for index in stride(from: worker, to: spots.count, by: workerCount) {
                        guard !Task.isCancelled else { break }
                        let spot = spots[index]
                        let target = CGPoint(x: extent.minX + spot.targetX * extent.width,
                                             y: extent.minY + spot.targetY * extent.height)
                        let source = CGPoint(x: extent.minX + spot.sourceX * extent.width,
                                             y: extent.minY + spot.sourceY * extent.height)
                        let radius = max(1, spot.radiusNorm * maxDimension)
                        let replacement: CIImage?
                        if spot.useInpaint {
                            replacement = await self.teleaInpaintAsync(
                                base, target: target, radius: radius, strength: CGFloat(spot.strength),
                                iterationScale: quality.repairIterationScale, extent: extent
                            )
                        } else {
                            replacement = await self.poissonCloneAsync(
                                base, target: target, source: source, radius: radius,
                                strength: CGFloat(spot.strength), iterationScale: quality.repairIterationScale,
                                extent: extent
                            )
                        }
                        workerResults.append((index, replacement))
                    }
                    return workerResults
                }
            }
            var results: [(Int, CIImage?)] = []
            for await workerResults in group { results.append(contentsOf: workerResults) }
            return results.sorted { $0.0 < $1.0 }
        }

        var output = image
        for (index, replacement) in replacements {
            guard let replacement else { continue }
            let spot = spots[index]
            let target = CGPoint(x: extent.minX + spot.targetX * extent.width,
                                 y: extent.minY + spot.targetY * extent.height)
            let radius = max(1, spot.radiusNorm * maxDimension)
            let mask = CIFilter(name: "CIRadialGradient")
            mask?.setValue(CIVector(x: target.x, y: target.y), forKey: "inputCenter")
            mask?.setValue(Float(radius * 0.55), forKey: "inputRadius0")
            mask?.setValue(Float(radius), forKey: "inputRadius1")
            mask?.setValue(CIColor.white, forKey: "inputColor0")
            mask?.setValue(CIColor.clear, forKey: "inputColor1")
            let strength = min(1, max(0, spot.strength))
            let strengthImage = CIImage(color: CIColor(red: CGFloat(strength), green: CGFloat(strength), blue: CGFloat(strength)))
                .cropped(to: extent)
            let strengthMask = CIFilter(name: "CIMultiplyCompositing")
            strengthMask?.setValue(mask?.outputImage, forKey: kCIInputImageKey)
            strengthMask?.setValue(strengthImage, forKey: kCIInputBackgroundImageKey)
            let blend = CIFilter(name: "CIBlendWithMask")
            blend?.setValue(replacement, forKey: kCIInputImageKey)
            blend?.setValue(output, forKey: kCIInputBackgroundImageKey)
            blend?.setValue(strengthMask?.outputImage ?? mask?.outputImage, forKey: kCIInputMaskImageKey)
            output = (blend?.outputImage ?? output).cropped(to: extent)
        }
        return output
    }

    private func teleaInpaint(_ image: CIImage, target: CGPoint, radius: CGFloat,
                              strength: CGFloat, iterationScale: CGFloat,
                              extent: CGRect) -> CIImage? {
        guard extent.width * extent.height <= 4_000_000, radius <= 180 else { return nil }
        // CIImage coordinates use a lower-left origin; a CGImage raster uses a
        // top-left row order for the bitmap context used by TeleaInpainting.
        let rasterCenter = CGPoint(
            x: target.x - extent.minX,
            y: extent.height - (target.y - extent.minY)
        )
        if let repaired = MetalImageProcessor.shared.teleaInpaint(
            image, center: rasterCenter, radius: radius, strength: strength,
            iterationScale: iterationScale, context: context
        ) {
            return repaired
        }
        guard let raster = context.createCGImage(image, from: extent) else { return nil }
        guard let repaired = TeleaInpainting.inpaint(
            raster, center: rasterCenter, radius: max(1, Int(radius.rounded())),
            strength: strength
        ) else { return nil }
        return CIImage(cgImage: repaired)
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)
    }

    private func teleaInpaintAsync(_ image: CIImage, target: CGPoint, radius: CGFloat,
                                   strength: CGFloat, iterationScale: CGFloat,
                                   extent: CGRect) async -> CIImage? {
        guard extent.width * extent.height <= 4_000_000, radius <= 180 else { return nil }
        let center = CGPoint(x: target.x - extent.minX,
                             y: extent.height - (target.y - extent.minY))
        return await MetalImageProcessor.shared.teleaInpaintAsync(
            image, center: center, radius: radius, strength: strength,
            iterationScale: iterationScale, context: context
        )
    }

    private func fallbackInpaint(_ image: CIImage, radius: CGFloat, extent: CGRect) -> CIImage {
        let blur = CIFilter(name: "CIGaussianBlur")
        blur?.setValue(image, forKey: kCIInputImageKey)
        blur?.setValue(Float(radius * 0.35), forKey: kCIInputRadiusKey)
        return (blur?.outputImage ?? image).cropped(to: extent)
    }

    private func poissonClone(_ image: CIImage, target: CGPoint, source: CGPoint,
                              radius: CGFloat, strength: CGFloat, iterationScale: CGFloat,
                              extent: CGRect) -> CIImage? {
        guard extent.width * extent.height <= 4_000_000, radius <= 180 else { return nil }
        let targetRaster = CGPoint(
            x: target.x - extent.minX,
            y: extent.height - (target.y - extent.minY)
        )
        let sourceRaster = CGPoint(
            x: source.x - extent.minX,
            y: extent.height - (source.y - extent.minY)
        )
        if let blended = MetalImageProcessor.shared.poissonClone(
            image, sourceCenter: sourceRaster, targetCenter: targetRaster,
            radius: radius, strength: strength, iterationScale: iterationScale, context: context
        ) {
            return blended
        }
        guard let raster = context.createCGImage(image, from: extent) else { return nil }
        guard let blended = PoissonClone.blend(
            raster, sourceCenter: sourceRaster, targetCenter: targetRaster,
            radius: max(1, Int(radius.rounded())), strength: strength
        ) else { return nil }
        return CIImage(cgImage: blended)
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)
    }

    private func poissonCloneAsync(_ image: CIImage, target: CGPoint, source: CGPoint,
                                   radius: CGFloat, strength: CGFloat, iterationScale: CGFloat,
                                   extent: CGRect) async -> CIImage? {
        guard extent.width * extent.height <= 4_000_000, radius <= 180 else { return nil }
        let targetCenter = CGPoint(x: target.x - extent.minX,
                                   y: extent.height - (target.y - extent.minY))
        let sourceCenter = CGPoint(x: source.x - extent.minX,
                                   y: extent.height - (source.y - extent.minY))
        return await MetalImageProcessor.shared.poissonCloneAsync(
            image, sourceCenter: sourceCenter, targetCenter: targetCenter,
            radius: radius, strength: strength, iterationScale: iterationScale,
            context: context
        )
    }

    private func applyGradients(to image: CIImage, gradients: [LinearGradient]) -> CIImage {
        var output = image
        for gradient in gradients {
            let extent = output.extent
            let radians = CGFloat(gradient.angle * .pi / 180)
            let center = CGPoint(x: extent.minX + gradient.centerX * extent.width,
                                 y: extent.minY + gradient.centerY * extent.height)
            let distance = max(1, CGFloat(gradient.range) * max(extent.width, extent.height))
            let direction = CGVector(dx: sin(radians) * distance,
                                     dy: cos(radians) * distance)
            let maskFilter = CIFilter(name: "CILinearGradient")
            maskFilter?.setValue(CIVector(x: center.x - direction.dx, y: center.y - direction.dy),
                                  forKey: "inputPoint0")
            maskFilter?.setValue(CIVector(x: center.x + direction.dx, y: center.y + direction.dy),
                                  forKey: "inputPoint1")
            maskFilter?.setValue(CIColor.black, forKey: "inputColor0")
            maskFilter?.setValue(CIColor.white, forKey: "inputColor1")
            guard let mask = maskFilter?.outputImage?.cropped(to: extent) else { continue }

            var adjusted = output
            if gradient.exposure != 0 {
                let exposure = CIFilter.exposureAdjust()
                exposure.inputImage = adjusted
                exposure.ev = Float(gradient.exposure)
                adjusted = exposure.outputImage ?? adjusted
            }
            if gradient.contrast != 0 || gradient.saturation != 0 {
                let controls = CIFilter.colorControls()
                controls.inputImage = adjusted
                controls.contrast = Float(1 + gradient.contrast / 100)
                controls.saturation = Float(1 + gradient.saturation / 100)
                adjusted = controls.outputImage ?? adjusted
            }
            if gradient.highlights != 0 || gradient.shadows != 0 {
                var tonal = ImageAdjustments()
                tonal.highlights = gradient.highlights
                tonal.shadows = gradient.shadows
                adjusted = applyToneCurve(to: adjusted, adjustments: tonal)
            }
            let blend = CIFilter.blendWithMask()
            blend.inputImage = adjusted
            blend.backgroundImage = output
            blend.maskImage = mask
            output = blend.outputImage?.cropped(to: extent) ?? output
        }
        return output
    }

    private func applyGeometry(to image: CIImage, adjustments: ImageAdjustments) -> CIImage {
        var output = image
        let rotation = ((adjustments.rotation % 360) + 360) % 360
        if rotation != 0 {
            let orientation: Int32
            switch rotation {
            case 90: orientation = 6
            case 180: orientation = 3
            default: orientation = 8
            }
            output = output.oriented(forExifOrientation: orientation)
        }

        if adjustments.cropAngle != 0 {
            let extent = output.extent
            let center = CGPoint(x: extent.midX, y: extent.midY)
            let radians = CGFloat(adjustments.cropAngle * .pi / 180)
            let transform = CGAffineTransform(translationX: center.x, y: center.y)
                .rotated(by: radians)
                .translatedBy(x: -center.x, y: -center.y)
            output = output.transformed(by: transform)
        }

        let extent = output.extent
        let x = min(1, max(0, adjustments.cropX))
        let y = min(1, max(0, adjustments.cropY))
        var cropX = x
        var cropY = y
        var width = min(1 - x, max(0.001, adjustments.cropWidth))
        var height = min(1 - y, max(0.001, adjustments.cropHeight))
        if let aspect = Self.cropAspectRatio(adjustments.cropAspectRatio) {
            let currentAspect = width * extent.width / (height * extent.height)
            if currentAspect > aspect {
                let newWidth = min(width, height * extent.height * aspect / extent.width)
                cropX += (width - newWidth) / 2
                width = newWidth
            } else if currentAspect < aspect {
                let newHeight = min(height, width * extent.width / aspect / extent.height)
                cropY += (height - newHeight) / 2
                height = newHeight
            }
        }
        if cropX > 0 || cropY > 0 || width < 1 || height < 1 {
            let rect = CGRect(x: extent.minX + extent.width * cropX,
                              y: extent.minY + extent.height * cropY,
                              width: extent.width * width,
                              height: extent.height * height)
            output = output.cropped(to: rect)
                .transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        }
        return output
    }

    private static func cropAspectRatio(_ value: String) -> CGFloat? {
        guard value.caseInsensitiveCompare("Original") != .orderedSame else { return nil }
        let parts = value.split(separator: ":")
        guard parts.count == 2, let width = Double(parts[0]),
              let height = Double(parts[1]), height > 0 else { return nil }
        return CGFloat(width / height)
    }

    private func applyToneCurve(to image: CIImage, adjustments: ImageAdjustments) -> CIImage {
        let dimension = 32
        let key = "\(adjustments.contrast)|\(adjustments.highlights)|\(adjustments.shadows)|\(adjustments.whites)|\(adjustments.blacks)" as NSString
        let cubeData: Data
        if let cached = Self.toneCurveCache.object(forKey: key) {
            cubeData = Data(cached)
        } else {
            var cube = [Float]()
            cube.reserveCapacity(dimension * dimension * dimension * 4)

            for blue in 0..<dimension {
                for green in 0..<dimension {
                    for red in 0..<dimension {
                        let r = Float(red) / Float(dimension - 1)
                        let g = Float(green) / Float(dimension - 1)
                        let b = Float(blue) / Float(dimension - 1)
                        cube.append(ToneCurve.value(r, adjustments: adjustments))
                        cube.append(ToneCurve.value(g, adjustments: adjustments))
                        cube.append(ToneCurve.value(b, adjustments: adjustments))
                        cube.append(1)
                    }
                }
            }
            cubeData = Data(bytes: cube, count: cube.count * MemoryLayout<Float>.size)
            Self.toneCurveCache.setObject(cubeData as NSData, forKey: key)
        }

        let filter = CIFilter(name: "CIColorCube")
        filter?.setValue(image, forKey: kCIInputImageKey)
        filter?.setValue(dimension, forKey: "inputCubeDimension")
        filter?.setValue(cubeData, forKey: "inputCubeData")
        return filter?.outputImage ?? image
    }

    func makePreview(_ image: CIImage, adjustments: ImageAdjustments,
                     maxDimension: CGFloat = 1800,
                     quality: RenderQuality = .finalPreview) -> CGImage? {
        let signpostID = MorrowPerformanceLog.begin("Preview render")
        defer { MorrowPerformanceLog.end("Preview render", id: signpostID) }
        let dimension = min(maxDimension, quality.previewDimension)
        let sourceScale = min(1, dimension / max(image.extent.width, image.extent.height))
        let previewSource = sourceScale < 1
            ? image.transformed(by: CGAffineTransform(scaleX: sourceScale, y: sourceScale))
            : image
        let rendered = render(previewSource, adjustments: adjustments, quality: quality)
        let scale = min(1, dimension / max(rendered.extent.width, rendered.extent.height))
        let output = scale < 1
            ? rendered.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : rendered
        return context.createCGImage(output, from: output.extent)
    }

    func makePreviewAsync(_ image: CIImage, adjustments: ImageAdjustments,
                          maxDimension: CGFloat = 1800,
                          quality: RenderQuality = .finalPreview) async -> CGImage? {
        let signpostID = MorrowPerformanceLog.begin("Preview render")
        defer { MorrowPerformanceLog.end("Preview render", id: signpostID) }
        let dimension = min(maxDimension, quality.previewDimension)
        let sourceScale = min(1, dimension / max(image.extent.width, image.extent.height))
        let previewSource = sourceScale < 1
            ? image.transformed(by: CGAffineTransform(scaleX: sourceScale, y: sourceScale))
            : image
        let rendered = await renderAsync(previewSource, adjustments: adjustments, quality: quality)
        let scale = min(1, dimension / max(rendered.extent.width, rendered.extent.height))
        let output = scale < 1
            ? rendered.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : rendered
        return context.createCGImage(output, from: output.extent)
    }
}

enum ToneCurve {
    static func value(_ input: Float, adjustments: ImageAdjustments) -> Float {
        let blacks = adjustments.blacks / 100
        let whites = adjustments.whites / 100
        let contrast = adjustments.contrast / 100
        let highlights = adjustments.highlights / 100
        let shadows = adjustments.shadows / 100

        let blackPoint = min(0.4, max(-0.1, -blacks * 0.12))
        let whitePoint = min(1.1, max(0.6, 1 - whites * 0.12))
        let span = max(0.001, whitePoint - blackPoint)
        var value = min(1, max(0, (Double(input) - blackPoint) / span))

        let highlightWeight = value * value
        let shadowWeight = (1 - value) * (1 - value)
        value += highlights * 0.28 * highlightWeight + shadows * 0.28 * shadowWeight
        value = min(1, max(0, value))

        let distance = value - 0.5
        value = 0.5 + distance * (1 + contrast) + contrast * 0.6 * distance * (0.25 - distance * distance)
        return Float(min(1, max(0, value)))
    }
}
