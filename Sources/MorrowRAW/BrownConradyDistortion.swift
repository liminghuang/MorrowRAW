import CoreImage
import Foundation

/// Legacy fallback used only if the Apple-GPU Brown–Conrady kernel cannot run.
/// The ARM path is implemented by `MetalImageProcessor`; this fallback keeps
/// the editor usable on unusual Core Image/Metal initialization failures.
enum BrownConradyDistortion {
    static func apply(to image: CIImage, amount: Double) -> CIImage {
        let extent = image.extent
        let filter = CIFilter(name: "CIPinchDistortion")
        filter?.setValue(image, forKey: kCIInputImageKey)
        filter?.setValue(CIVector(x: extent.midX, y: extent.midY), forKey: "inputCenter")
        filter?.setValue(Float(max(extent.width, extent.height) * 0.75), forKey: "inputRadius")
        filter?.setValue(Float(-amount / 100 * 0.5), forKey: "inputScale")
        return (filter?.outputImage ?? image).cropped(to: extent)
    }
}
