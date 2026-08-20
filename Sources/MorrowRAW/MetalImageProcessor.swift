import CoreImage
import Foundation
import Metal
import simd

/// Apple-GPU image kernels used by the ARM-only build.
///
/// CPU implementations remain available as correctness fallbacks, while this
/// class keeps the hot preview operations on MTLTextures and avoids the
/// CIImage -> CGImage -> CPU -> CIImage round-trip.
final class MetalImageProcessor {
    static let shared = MetalImageProcessor()

    private final class TexturePool {
        private let device: MTLDevice
        private let maxCachedTextures = 16
        private var buckets: [String: [MTLTexture]] = [:]
        private var cachedTextureCount = 0
        private let lock = NSLock()

        init(device: MTLDevice) {
            self.device = device
        }

        func acquire(width: Int, height: Int) -> MTLTexture? {
            let key = "\(width)x\(height)"
            lock.lock()
            if var bucket = buckets[key], let texture = bucket.popLast() {
                buckets[key] = bucket
                cachedTextureCount = max(0, cachedTextureCount - 1)
                lock.unlock()
                return texture
            }
            lock.unlock()

            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false
            )
            descriptor.usage = [.shaderRead, .shaderWrite]
            return device.makeTexture(descriptor: descriptor)
        }

        func recycle(_ texture: MTLTexture) {
            let key = "\(texture.width)x\(texture.height)"
            lock.lock()
            var bucket = buckets[key, default: []]
            if bucket.count < 8, cachedTextureCount < maxCachedTextures {
                bucket.append(texture)
                buckets[key] = bucket
                cachedTextureCount += 1
            }
            lock.unlock()
        }
    }

    private struct NLMUniforms {
        var hSquared: Float
    }

    private struct LabUniforms {
        var saturation: Float
        var vibrance: Float
    }

    private struct DistortionUniforms {
        var k1: Float
        var k2: Float
        var center: SIMD2<Float>
        var scale: SIMD2<Float>
    }

    private struct InpaintUniforms {
        var center: SIMD2<Float>
        var radius: Float
        var searchRadius: Float
        var strength: Float
        var iteration: UInt32
        var iterations: UInt32
    }

    private struct PoissonUniforms {
        var sourceCenter: SIMD2<Float>
        var targetCenter: SIMD2<Float>
        var radius: Float
        var strength: Float
        var iteration: UInt32
        var iterations: UInt32
    }

    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private let nlmPipeline: MTLComputePipelineState?
    private let labPipeline: MTLComputePipelineState?
    private let distortionPipeline: MTLComputePipelineState?
    private let teleaPipeline: MTLComputePipelineState?
    private let poissonPipeline: MTLComputePipelineState?
    private let texturePool: TexturePool?

    private init() {
        let device = MTLCreateSystemDefaultDevice()
        self.device = device
        commandQueue = device?.makeCommandQueue()
        texturePool = device.map(TexturePool.init)
        guard let device,
              let url = Bundle.module.url(forResource: "ImageKernels", withExtension: "metal"),
              let source = try? String(contentsOf: url),
              !source.isEmpty else {
            nlmPipeline = nil
            labPipeline = nil
            distortionPipeline = nil
            teleaPipeline = nil
            poissonPipeline = nil
            return
        }
        var nlm: MTLComputePipelineState?
        var lab: MTLComputePipelineState?
        var distortion: MTLComputePipelineState?
        var telea: MTLComputePipelineState?
        var poisson: MTLComputePipelineState?
        do {
            let library = try device.makeLibrary(source: source, options: nil)
            guard let nlmFunction = library.makeFunction(name: "nonLocalMeans"),
                  let labFunction = library.makeFunction(name: "labChroma"),
                  let teleaFunction = library.makeFunction(name: "teleaIterative"),
                  let poissonFunction = library.makeFunction(name: "poissonIterative") else {
                print("MetalImageProcessor: compiled library is missing expected kernels")
                nlm = nil
                lab = nil
                self.nlmPipeline = nlm
                self.labPipeline = lab
                self.distortionPipeline = nil
                self.teleaPipeline = nil
                self.poissonPipeline = nil
                return
            }
            nlm = try device.makeComputePipelineState(function: nlmFunction)
            lab = try device.makeComputePipelineState(function: labFunction)
            guard let distortionFunction = library.makeFunction(name: "brownConrady") else {
                print("MetalImageProcessor: compiled library is missing brownConrady")
                distortion = nil
                throw NSError(domain: "MetalImageProcessor", code: 1)
            }
            distortion = try device.makeComputePipelineState(function: distortionFunction)
            telea = try device.makeComputePipelineState(function: teleaFunction)
            poisson = try device.makeComputePipelineState(function: poissonFunction)
        } catch {
            print("MetalImageProcessor initialization failed: \(error)")
            nlm = nil
            lab = nil
            distortion = nil
            telea = nil
            poisson = nil
        }
        nlmPipeline = nlm
        labPipeline = lab
        distortionPipeline = distortion
        teleaPipeline = telea
        poissonPipeline = poisson
    }

    func nonLocalMeans(_ image: CIImage, strength: CGFloat, context: CIContext) -> CIImage? {
        let h = Float(0.035 + max(0, min(1, strength)) * 0.11)
        var uniforms = NLMUniforms(hSquared: h * h)
        return apply(image, pipeline: nlmPipeline, context: context,
                     uniforms: &uniforms, uniformSize: MemoryLayout<NLMUniforms>.stride)
    }

    func nonLocalMeansAsync(_ image: CIImage, strength: CGFloat,
                            context: CIContext) async -> CIImage? {
        let h = Float(0.035 + max(0, min(1, strength)) * 0.11)
        var uniforms = NLMUniforms(hSquared: h * h)
        return await applyAsync(image, pipeline: nlmPipeline, context: context,
                                uniforms: &uniforms,
                                uniformSize: MemoryLayout<NLMUniforms>.stride)
    }

    func labChroma(_ image: CIImage, saturation: CGFloat, vibrance: CGFloat,
                   context: CIContext) -> CIImage? {
        var uniforms = LabUniforms(saturation: Float(saturation), vibrance: Float(vibrance))
        return apply(image, pipeline: labPipeline, context: context,
                     uniforms: &uniforms, uniformSize: MemoryLayout<LabUniforms>.stride)
    }

    func labChromaAsync(_ image: CIImage, saturation: CGFloat, vibrance: CGFloat,
                        context: CIContext) async -> CIImage? {
        var uniforms = LabUniforms(saturation: Float(saturation), vibrance: Float(vibrance))
        return await applyAsync(image, pipeline: labPipeline, context: context,
                                uniforms: &uniforms,
                                uniformSize: MemoryLayout<LabUniforms>.stride)
    }

    func brownConrady(_ image: CIImage, amount: Double, context: CIContext) -> CIImage? {
        let extent = image.extent.integral
        let center = SIMD2<Float>(Float(extent.midX), Float(extent.midY))
        let scale = SIMD2<Float>(Float(max(1, extent.width * 0.5)),
                                 Float(max(1, extent.height * 0.5)))
        var uniforms = DistortionUniforms(
            k1: Float(-amount / 100 * 0.35), k2: 0,
            center: center, scale: scale
        )
        return apply(image, pipeline: distortionPipeline, context: context,
                     uniforms: &uniforms, uniformSize: MemoryLayout<DistortionUniforms>.stride)
    }

    func brownConradyAsync(_ image: CIImage, amount: Double,
                           context: CIContext) async -> CIImage? {
        let extent = image.extent.integral
        var uniforms = DistortionUniforms(
            k1: Float(-amount / 100 * 0.35), k2: 0,
            center: SIMD2<Float>(Float(extent.midX), Float(extent.midY)),
            scale: SIMD2<Float>(Float(max(1, extent.width * 0.5)),
                                Float(max(1, extent.height * 0.5)))
        )
        return await applyAsync(image, pipeline: distortionPipeline, context: context,
                                uniforms: &uniforms,
                                uniformSize: MemoryLayout<DistortionUniforms>.stride)
    }

    func teleaInpaint(_ image: CIImage, center: CGPoint, radius: CGFloat,
                      strength: CGFloat, iterationScale: CGFloat = 1,
                      context: CIContext) -> CIImage? {
        guard radius > 0, radius <= 180 else { return nil }
        let iterations = max(1, min(220, Int((CGFloat(radius.rounded()) + 1) * iterationScale)))
        var uniforms = InpaintUniforms(
            center: SIMD2<Float>(Float(center.x), Float(center.y)),
            radius: Float(radius), searchRadius: Float(min(4, max(2, Int(radius / 8) + 2))),
            strength: Float(strength), iteration: 0, iterations: UInt32(iterations)
        )
        return applyIterative(image, pipeline: teleaPipeline, context: context,
                              uniforms: &uniforms, uniformSize: MemoryLayout<InpaintUniforms>.stride,
                              iterations: iterations)
    }

    func teleaInpaintAsync(_ image: CIImage, center: CGPoint, radius: CGFloat,
                           strength: CGFloat, iterationScale: CGFloat = 1,
                           context: CIContext) async -> CIImage? {
        guard radius > 0, radius <= 180 else { return nil }
        let iterations = max(1, min(220, Int((CGFloat(radius.rounded()) + 1) * iterationScale)))
        var uniforms = InpaintUniforms(
            center: SIMD2<Float>(Float(center.x), Float(center.y)),
            radius: Float(radius), searchRadius: Float(min(4, max(2, Int(radius / 8) + 2))),
            strength: Float(strength), iteration: 0, iterations: UInt32(iterations)
        )
        return await applyIterativeAsync(image, pipeline: teleaPipeline, context: context,
                                         uniforms: &uniforms,
                                         uniformSize: MemoryLayout<InpaintUniforms>.stride,
                                         iterations: iterations)
    }

    func poissonClone(_ image: CIImage, sourceCenter: CGPoint, targetCenter: CGPoint,
                      radius: CGFloat, strength: CGFloat, iterationScale: CGFloat = 1,
                      context: CIContext) -> CIImage? {
        guard radius > 0, radius <= 180 else { return nil }
        let iterations = max(1, min(120, Int(CGFloat(max(32, Int(radius.rounded()) * 2)) * iterationScale)))
        var uniforms = PoissonUniforms(
            sourceCenter: SIMD2<Float>(Float(sourceCenter.x), Float(sourceCenter.y)),
            targetCenter: SIMD2<Float>(Float(targetCenter.x), Float(targetCenter.y)),
            radius: Float(radius), strength: Float(strength), iteration: 0,
            iterations: UInt32(iterations)
        )
        return applyIterative(image, pipeline: poissonPipeline, context: context,
                              uniforms: &uniforms, uniformSize: MemoryLayout<PoissonUniforms>.stride,
                              iterations: iterations)
    }

    func poissonCloneAsync(_ image: CIImage, sourceCenter: CGPoint, targetCenter: CGPoint,
                           radius: CGFloat, strength: CGFloat, iterationScale: CGFloat = 1,
                           context: CIContext) async -> CIImage? {
        guard radius > 0, radius <= 180 else { return nil }
        let iterations = max(1, min(120, Int(CGFloat(max(32, Int(radius.rounded()) * 2)) * iterationScale)))
        var uniforms = PoissonUniforms(
            sourceCenter: SIMD2<Float>(Float(sourceCenter.x), Float(sourceCenter.y)),
            targetCenter: SIMD2<Float>(Float(targetCenter.x), Float(targetCenter.y)),
            radius: Float(radius), strength: Float(strength), iteration: 0,
            iterations: UInt32(iterations)
        )
        return await applyIterativeAsync(image, pipeline: poissonPipeline, context: context,
                                         uniforms: &uniforms,
                                         uniformSize: MemoryLayout<PoissonUniforms>.stride,
                                         iterations: iterations)
    }

    private func apply<T>(_ image: CIImage, pipeline: MTLComputePipelineState?,
                          context: CIContext, uniforms: inout T,
                          uniformSize: Int) -> CIImage? {
        guard let device, let commandQueue, let pipeline,
              let extent = image.extent.integral as CGRect? else { return nil }
        let width = max(1, Int(extent.width))
        let height = max(1, Int(extent.height))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        guard let texturePool,
              let input = texturePool.acquire(width: width, height: height) else { return nil }
        guard let output = device.makeTexture(descriptor: descriptor) else {
            texturePool.recycle(input)
            return nil
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            texturePool.recycle(input)
            return nil
        }
        defer { texturePool.recycle(input) }

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        context.render(image, to: input, commandBuffer: commandBuffer,
                       bounds: extent, colorSpace: colorSpace)
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        withUnsafeBytes(of: &uniforms) { rawBuffer in
            encoder.setBytes(rawBuffer.baseAddress!, length: uniformSize, index: 0)
        }
        let widthThreads = max(1, min(pipeline.threadExecutionWidth, width))
        let heightThreads = max(1, min(pipeline.maxTotalThreadsPerThreadgroup / widthThreads, height))
        encoder.dispatchThreads(
            MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: widthThreads, height: heightThreads, depth: 1)
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed,
              let result = CIImage(mtlTexture: output, options: [
                .colorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any
              ]) else { return nil }
        return result.transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: image.extent)
    }

    private func applyAsync<T>(_ image: CIImage, pipeline: MTLComputePipelineState?,
                               context: CIContext, uniforms: inout T,
                               uniformSize: Int) async -> CIImage? {
        await withCheckedContinuation { continuation in
            enqueue(image, pipeline: pipeline, context: context, uniforms: &uniforms,
                    uniformSize: uniformSize) { result in
                continuation.resume(returning: result)
            }
        }
    }

    private func enqueue<T>(_ image: CIImage, pipeline: MTLComputePipelineState?,
                            context: CIContext, uniforms: inout T, uniformSize: Int,
                            completion: @escaping (CIImage?) -> Void) {
        guard let device, let commandQueue, let pipeline,
              let texturePool, let extent = image.extent.integral as CGRect? else {
            completion(nil)
            return
        }
        let width = max(1, Int(extent.width))
        let height = max(1, Int(extent.height))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        guard let input = texturePool.acquire(width: width, height: height) else {
            completion(nil)
            return
        }
        guard let output = device.makeTexture(descriptor: descriptor) else {
            texturePool.recycle(input)
            completion(nil)
            return
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            texturePool.recycle(input)
            completion(nil)
            return
        }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            texturePool.recycle(input)
            completion(nil)
            return
        }
        context.render(image, to: input, commandBuffer: commandBuffer,
                       bounds: extent, colorSpace: colorSpace)
        // The encoder must follow the CI render command in this command buffer.
        guard let encoder = makeEncoder(commandBuffer: commandBuffer, pipeline: pipeline,
                                        input: input, output: output, uniforms: &uniforms,
                                        uniformSize: uniformSize, width: width, height: height) else {
            texturePool.recycle(input)
            completion(nil)
            return
        }
        encoder.endEncoding()
        commandBuffer.addCompletedHandler { [texturePool] buffer in
            texturePool.recycle(input)
            guard buffer.status == .completed,
                  let result = CIImage(mtlTexture: output, options: [.colorSpace: colorSpace]) else {
                completion(nil)
                return
            }
            completion(result.transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
                .cropped(to: image.extent))
        }
        commandBuffer.commit()
    }

    private func makeEncoder<T>(commandBuffer: MTLCommandBuffer,
                               pipeline: MTLComputePipelineState,
                               input: MTLTexture, output: MTLTexture,
                               uniforms: inout T, uniformSize: Int,
                               width: Int, height: Int) -> MTLComputeCommandEncoder? {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        withUnsafeBytes(of: &uniforms) { rawBuffer in
            encoder.setBytes(rawBuffer.baseAddress!, length: uniformSize, index: 0)
        }
        let widthThreads = max(1, min(pipeline.threadExecutionWidth, width))
        let heightThreads = max(1, min(pipeline.maxTotalThreadsPerThreadgroup / widthThreads, height))
        encoder.dispatchThreads(
            MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: widthThreads, height: heightThreads, depth: 1)
        )
        return encoder
    }

    private func applyIterative<T>(_ image: CIImage, pipeline: MTLComputePipelineState?,
                                   context: CIContext, uniforms: inout T,
                                   uniformSize: Int, iterations: Int) -> CIImage? {
        guard let device, let commandQueue, let pipeline,
              let extent = image.extent.integral as CGRect? else { return nil }
        let width = max(1, Int(extent.width))
        let height = max(1, Int(extent.height))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        guard let texturePool,
              let original = texturePool.acquire(width: width, height: height) else { return nil }
        guard let ping = texturePool.acquire(width: width, height: height) else {
            texturePool.recycle(original)
            return nil
        }
        guard let pong = device.makeTexture(descriptor: descriptor) else {
            texturePool.recycle(original)
            texturePool.recycle(ping)
            return nil
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            texturePool.recycle(original)
            texturePool.recycle(ping)
            return nil
        }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            texturePool.recycle(original)
            texturePool.recycle(ping)
            return nil
        }

        context.render(image, to: original, commandBuffer: commandBuffer,
                       bounds: extent, colorSpace: colorSpace)
        copyTexture(original, to: ping, width: width, height: height,
                    commandBuffer: commandBuffer) {
            context.render(image, to: ping, commandBuffer: commandBuffer,
                           bounds: extent, colorSpace: colorSpace)
        }

        var previous = ping
        var output = pong
        for iteration in 0..<iterations {
            setIteration(iteration, in: &uniforms)
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(original, index: 0)
            encoder.setTexture(previous, index: 1)
            encoder.setTexture(output, index: 2)
            withUnsafeBytes(of: &uniforms) { rawBuffer in
                encoder.setBytes(rawBuffer.baseAddress!, length: uniformSize, index: 0)
            }
            let widthThreads = max(1, min(pipeline.threadExecutionWidth, width))
            let heightThreads = max(1, min(pipeline.maxTotalThreadsPerThreadgroup / widthThreads, height))
            encoder.setThreadgroupMemoryLength(
                (widthThreads + 2) * (heightThreads + 2) * MemoryLayout<SIMD4<UInt16>>.stride,
                index: 0
            )
            encoder.dispatchThreads(
                MTLSize(width: width, height: height, depth: 1),
                threadsPerThreadgroup: MTLSize(width: widthThreads, height: heightThreads, depth: 1)
            )
            encoder.endEncoding()
            swap(&previous, &output)
        }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        // `original` and `ping` came from the pool; `pong` is a standalone
        // texture. The final texture is still retained by the returned CIImage,
        // so only recycle the pooled scratch texture when it is not the final
        // result. Recycling the standalone `pong` would pollute the pool with
        // an unleased texture, while recycling the final pooled texture would
        // let a later render overwrite the CIImage's backing storage.
        texturePool.recycle(original)
        if output === ping {
            texturePool.recycle(output)
        }
        guard commandBuffer.status == .completed,
              let result = CIImage(mtlTexture: previous, options: [.colorSpace: colorSpace]) else {
            return nil
        }
        return result.transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: image.extent)
    }

    private func applyIterativeAsync<T>(_ image: CIImage, pipeline: MTLComputePipelineState?,
                                        context: CIContext, uniforms: inout T,
                                        uniformSize: Int, iterations: Int) async -> CIImage? {
        await withCheckedContinuation { continuation in
            enqueueIterative(image, pipeline: pipeline, context: context, uniforms: &uniforms,
                             uniformSize: uniformSize, iterations: iterations) { result in
                continuation.resume(returning: result)
            }
        }
    }

    private func enqueueIterative<T>(_ image: CIImage, pipeline: MTLComputePipelineState?,
                                     context: CIContext, uniforms: inout T,
                                     uniformSize: Int, iterations: Int,
                                     completion: @escaping (CIImage?) -> Void) {
        guard let device, let commandQueue, let pipeline, let texturePool,
              let extent = image.extent.integral as CGRect?, iterations > 0 else {
            completion(nil)
            return
        }
        let width = max(1, Int(extent.width))
        let height = max(1, Int(extent.height))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        guard let original = texturePool.acquire(width: width, height: height) else {
            completion(nil)
            return
        }
        guard let ping = texturePool.acquire(width: width, height: height) else {
            texturePool.recycle(original)
            completion(nil)
            return
        }
        guard let pong = device.makeTexture(descriptor: descriptor) else {
            texturePool.recycle(original)
            texturePool.recycle(ping)
            completion(nil)
            return
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            texturePool.recycle(original)
            texturePool.recycle(ping)
            completion(nil)
            return
        }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            texturePool.recycle(original)
            texturePool.recycle(ping)
            completion(nil)
            return
        }

        context.render(image, to: original, commandBuffer: commandBuffer,
                       bounds: extent, colorSpace: colorSpace)
        copyTexture(original, to: ping, width: width, height: height,
                    commandBuffer: commandBuffer) {
            context.render(image, to: ping, commandBuffer: commandBuffer,
                           bounds: extent, colorSpace: colorSpace)
        }

        var previous = ping
        var output = pong
        for iteration in 0..<iterations {
            setIteration(iteration, in: &uniforms)
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
                texturePool.recycle(original)
                texturePool.recycle(ping)
                completion(nil)
                return
            }
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(original, index: 0)
            encoder.setTexture(previous, index: 1)
            encoder.setTexture(output, index: 2)
            withUnsafeBytes(of: &uniforms) { rawBuffer in
                encoder.setBytes(rawBuffer.baseAddress!, length: uniformSize, index: 0)
            }
            let widthThreads = max(1, min(pipeline.threadExecutionWidth, width))
            let heightThreads = max(1, min(pipeline.maxTotalThreadsPerThreadgroup / widthThreads, height))
            encoder.setThreadgroupMemoryLength(
                (widthThreads + 2) * (heightThreads + 2) * MemoryLayout<SIMD4<UInt16>>.stride,
                index: 0
            )
            encoder.dispatchThreads(
                MTLSize(width: width, height: height, depth: 1),
                threadsPerThreadgroup: MTLSize(width: widthThreads, height: heightThreads, depth: 1)
            )
            encoder.endEncoding()
            swap(&previous, &output)
        }

        let finalTexture = previous
        let scratchTexture = output
        commandBuffer.addCompletedHandler { [texturePool] buffer in
            texturePool.recycle(original)
            if scratchTexture === ping {
                texturePool.recycle(scratchTexture)
            }
            guard buffer.status == .completed,
                  let result = CIImage(mtlTexture: finalTexture, options: [.colorSpace: colorSpace]) else {
                completion(nil)
                return
            }
            completion(result.transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
                .cropped(to: image.extent))
        }
        commandBuffer.commit()
    }

    private func setIteration<T>(_ iteration: Int, in uniforms: inout T) {
        withUnsafeMutableBytes(of: &uniforms) { rawBuffer in
            // Both iterative uniform structs place iteration after their two
            // float2/float fields; use typed overloads below for exact layout.
            if T.self == InpaintUniforms.self {
                rawBuffer.storeBytes(of: UInt32(iteration), toByteOffset: 20, as: UInt32.self)
            } else if T.self == PoissonUniforms.self {
                rawBuffer.storeBytes(of: UInt32(iteration), toByteOffset: 24, as: UInt32.self)
            }
        }
    }

    private func copyTexture(_ source: MTLTexture, to destination: MTLTexture,
                             width: Int, height: Int, commandBuffer: MTLCommandBuffer,
                             fallback: () -> Void) {
        guard let blit = commandBuffer.makeBlitCommandEncoder() else {
            fallback()
            return
        }
        blit.copy(from: source,
                  sourceSlice: 0,
                  sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: destination,
                  destinationSlice: 0,
                  destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
    }
}
