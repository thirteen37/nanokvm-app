@preconcurrency import CoreImage
@preconcurrency import CoreVideo
import Foundation
import Metal

/// Expands studio/limited-range YCbCr frames to full-range RGB on the GPU.
///
/// The GLKVM stream is genuine studio range (luma 16–235, chroma 16–240) tagged
/// `video_full_range_flag = 0`, but this display path renders YCbCr as full-range
/// identity — it never applies the 16–235 → 0–255 expansion, leaving blacks grey,
/// whites dim, and colors muted. Core Image *does* honor the video-range tag, so
/// converting each frame through it produces correctly expanded full-range RGB.
///
/// Doing this on the GPU (rather than rewriting VideoToolbox's output buffer in
/// place) matters for three reasons: it never mutates the decoder's buffer — which
/// VideoToolbox reuses as a reference frame, so in-place edits corrupt later frames
/// — it avoids a per-frame GPU↔CPU round-trip, and the float YCbCr→RGB conversion
/// avoids the banding an 8-bit studio→full stretch would introduce.
final class FullRangeVideoExpander {
    private let context: CIContext
    private let outputColorSpace: CGColorSpace
    /// Per-channel black lift applied after the YCbCr→RGB expansion: `out =
    /// (in - blackLift) / (1 - blackLift)`, which remaps the chosen studio black
    /// point to true black while keeping white at 1. Zero when the black point is
    /// the standard studio 16 (no extra crush).
    private let blackLift: CGFloat
    private var pool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0

    /// - Parameter studioBlackPoint: studio luma level (≥16) to map to true black.
    init?(studioBlackPoint: Int = 16) {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        // Core Image expands the standard studio black (16) to 0, so a black point
        // of P leaves studio-P sitting at (P-16)/219 in the full-range output.
        blackLift = CGFloat(max(0, studioBlackPoint - 16)) / 219.0
    }

    /// Returns a new full-range BGRA pixel buffer with `source`'s studio-range
    /// YCbCr expanded, or `nil` if a buffer could not be produced (caller should
    /// fall back to displaying `source` unmodified). `source` is never mutated.
    func expand(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        guard width > 0, height > 0, let pool = pool(width: width, height: height) else { return nil }

        var destination: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &destination) == kCVReturnSuccess,
              let destination else { return nil }

        // CIImage reads `source`'s color attachments (video-range, BT.709) and
        // expands to full range during the YCbCr→RGB conversion.
        var image = CIImage(cvPixelBuffer: source)
        if blackLift > 0 {
            let scale = 1.0 / (1.0 - blackLift)
            let bias = -blackLift * scale
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: scale, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: scale, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: scale, w: 0),
                "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0),
            ])
        }
        context.render(image, to: destination, bounds: image.extent, colorSpace: outputColorSpace)
        return destination
    }

    private func pool(width: Int, height: Int) -> CVPixelBufferPool? {
        if let pool, poolWidth == width, poolHeight == height {
            return pool
        }

        let pixelBufferAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]() as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var newPool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            nil,
            pixelBufferAttributes as CFDictionary,
            &newPool
        ) == kCVReturnSuccess else { return nil }

        pool = newPool
        poolWidth = width
        poolHeight = height
        return newPool
    }
}
