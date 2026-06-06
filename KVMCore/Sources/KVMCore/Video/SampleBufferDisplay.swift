import Accelerate
@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import Foundation
import QuartzCore

/// The render sink the coordinator fans frames out to. A protocol so tests can
/// substitute an inspectable fake for the real `AVSampleBufferDisplayLayer`-backed
/// `SampleBufferDisplay`.
public protocol SampleBufferDisplaying: AnyObject {
    func enqueue(_ sampleBuffer: CMSampleBuffer, renderMode: SampleBufferRenderMode)
    func flush()
}

public final class SampleBufferDisplay: SampleBufferDisplaying {
    public let layer: CALayer
    private let sampleLayer: AVSampleBufferDisplayLayer
    private var enqueuedCount = 0

    /// When set, frames rendered through the `.directLatestFrame` (CPU) path are
    /// downscaled so their longest side is at most this many pixels before the
    /// `CGImage` is built. The minimap sets this so it pays a small (~target²)
    /// allocation instead of duplicating the main display's full-resolution
    /// (e.g. ~33 MB at 4K) per-frame copy. `nil` (the default, used by the main
    /// display) keeps full resolution.
    public var directFrameMaxDimension: CGFloat?

    public init() {
        layer = CALayer()
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
        layer.masksToBounds = true
        layer.contentsGravity = .resizeAspect

        sampleLayer = AVSampleBufferDisplayLayer()
        sampleLayer.videoGravity = .resizeAspect
        sampleLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        sampleLayer.masksToBounds = true
        layer.addSublayer(sampleLayer)
    }

    public func setVideoTransform(_ transform: CGAffineTransform) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setAffineTransform(transform)
        CATransaction.commit()
    }

    public func enqueue(_ sampleBuffer: CMSampleBuffer, renderMode: SampleBufferRenderMode = .sampleBuffer) {
        switch renderMode {
        case .sampleBuffer:
            enqueueSampleBuffer(sampleBuffer, flushQueuedFrames: false)
        case .sampleBufferFlushingQueuedFrames:
            enqueueSampleBuffer(sampleBuffer, flushQueuedFrames: true)
        case .directLatestFrame:
            enqueueDirectFrame(sampleBuffer)
        }
    }

    private func enqueueSampleBuffer(_ sampleBuffer: CMSampleBuffer, flushQueuedFrames: Bool) {
        let renderer = sampleLayer.sampleBufferRenderer
        if renderer.status == .failed {
            KVMLog.video.error("Sample buffer display layer failed: \(String(describing: renderer.error), privacy: .public)")
            renderer.flush()
        }
        if flushQueuedFrames {
            renderer.flush()
        }
        enqueuedCount += 1
        if enqueuedCount == 1 || enqueuedCount % 120 == 0 {
            KVMLog.video.info("Sample buffer display layer enqueue count: \(self.enqueuedCount, privacy: .public)")
        }
        let enqueue = { [sampleLayer, layer] in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            sampleLayer.isHidden = false
            sampleLayer.frame = layer.bounds
            layer.contents = nil
            CATransaction.commit()
            sampleLayer.sampleBufferRenderer.enqueue(sampleBuffer)
        }
        if Thread.isMainThread {
            enqueue()
        } else {
            DispatchQueue.main.async(execute: enqueue)
        }
    }

    private func enqueueDirectFrame(_ sampleBuffer: CMSampleBuffer) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        guard let cgImage = makeOpaqueImage(from: imageBuffer, maxDimension: directFrameMaxDimension) else { return }
        enqueuedCount += 1
        if enqueuedCount == 1 || enqueuedCount % 120 == 0 {
            KVMLog.video.info("Direct frame display count: \(self.enqueuedCount, privacy: .public)")
        }

        let display = { [layer, sampleLayer] in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            sampleLayer.sampleBufferRenderer.flush()
            sampleLayer.isHidden = true
            sampleLayer.frame = layer.bounds
            layer.contents = cgImage
            CATransaction.commit()
        }
        if Thread.isMainThread {
            display()
        } else {
            DispatchQueue.main.async(execute: display)
        }
    }

    private func makeOpaqueImage(from pixelBuffer: CVImageBuffer, maxDimension: CGFloat?) -> CGImage? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return nil }

        let target = Self.targetSize(sourceWidth: width, sourceHeight: height, maxDimension: maxDimension)
        let destinationBytesPerRow = target.width * 4

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let sourceBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        var data = Data(count: destinationBytesPerRow * target.height)

        let copied = data.withUnsafeMutableBytes { destination -> Bool in
            guard let destinationBase = destination.baseAddress else { return false }
            if target.width == width, target.height == height {
                // Full resolution: strip any row padding with a straight per-row copy.
                for row in 0..<height {
                    let source = baseAddress.advanced(by: row * sourceBytesPerRow)
                    let rowDestination = destinationBase.advanced(by: row * destinationBytesPerRow)
                    memcpy(rowDestination, source, destinationBytesPerRow)
                }
                return true
            }
            // Downscale. vImage scales row-for-row in the same top-down order as
            // the source, so the resulting image matches the full-resolution path's
            // orientation exactly (a CoreGraphics draw would risk a vertical flip).
            var source = vImage_Buffer(
                data: baseAddress,
                height: vImagePixelCount(height),
                width: vImagePixelCount(width),
                rowBytes: sourceBytesPerRow
            )
            var dest = vImage_Buffer(
                data: destinationBase,
                height: vImagePixelCount(target.height),
                width: vImagePixelCount(target.width),
                rowBytes: destinationBytesPerRow
            )
            let error = vImageScale_ARGB8888(&source, &dest, nil, vImage_Flags(kvImageHighQualityResampling))
            return error == kvImageNoError
        }
        guard copied else { return nil }

        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)
        )
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: target.width,
            height: target.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: destinationBytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    /// Fits `(sourceWidth, sourceHeight)` within `maxDimension` on its longest
    /// side, preserving aspect ratio. Returns the source size unchanged when
    /// `maxDimension` is nil/non-positive or the source already fits (never
    /// upscales).
    static func targetSize(sourceWidth: Int, sourceHeight: Int, maxDimension: CGFloat?) -> (width: Int, height: Int) {
        guard let maxDimension, maxDimension > 0 else { return (sourceWidth, sourceHeight) }
        let longest = CGFloat(max(sourceWidth, sourceHeight))
        guard longest > maxDimension else { return (sourceWidth, sourceHeight) }
        let scale = maxDimension / longest
        let width = max(1, Int((CGFloat(sourceWidth) * scale).rounded()))
        let height = max(1, Int((CGFloat(sourceHeight) * scale).rounded()))
        return (width, height)
    }

    public func flush() {
        enqueuedCount = 0
        KVMLog.video.info("Sample buffer display layer flush")
        let flush = { [layer, sampleLayer] in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            sampleLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
            layer.contents = nil
            CATransaction.commit()
        }
        if Thread.isMainThread {
            flush()
        } else {
            DispatchQueue.main.async(execute: flush)
        }
    }
}

public enum SampleBufferRenderMode: Sendable {
    case sampleBuffer
    case sampleBufferFlushingQueuedFrames
    case directLatestFrame
}

public final class SampleBufferRenderCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private let renderMode: SampleBufferRenderMode
    private weak var display: (any SampleBufferDisplaying)?
    private weak var minimapDisplay: (any SampleBufferDisplaying)?
    /// The most recent *accepted* frame, retained so a minimap attaching mid-stream
    /// (or while the host screen is static) can be seeded immediately instead of
    /// staying black until the next frame arrives.
    private var lastSampleBuffer: CMSampleBuffer?
    private var lastPresentationTime: CMTime?
    private var sampleObserver: (@Sendable (CMSampleBuffer) -> Void)?

    public init(flushQueuedFrames: Bool = false) {
        self.renderMode = flushQueuedFrames ? .sampleBufferFlushingQueuedFrames : .sampleBuffer
    }

    public init(renderMode: SampleBufferRenderMode) {
        self.renderMode = renderMode
    }

    public func attach(display: any SampleBufferDisplaying) {
        lock.lock()
        let displayChanged = self.display !== display
        if displayChanged {
            self.display = display
            lastPresentationTime = nil
        }
        lock.unlock()

        if displayChanged {
            display.flush()
        }
    }

    public func detach(display: any SampleBufferDisplaying) {
        lock.lock()
        if self.display === display {
            self.display = nil
            lastPresentationTime = nil
        }
        lock.unlock()
    }

    /// Attaches a secondary "minimap" display fed the same frames as the main
    /// `display`. This is a separate channel: attaching it must NOT evict the
    /// main display. On a fresh attach the minimap is seeded with the last
    /// accepted frame so it shows content immediately on a static host screen.
    public func attachMinimap(display: any SampleBufferDisplaying) {
        lock.lock()
        let changed = self.minimapDisplay !== display
        if changed {
            self.minimapDisplay = display
        }
        let seed = lastSampleBuffer
        lock.unlock()

        guard changed else { return }
        display.flush()
        if let seed {
            display.enqueue(seed, renderMode: renderMode)
        }
    }

    public func detachMinimap(display: any SampleBufferDisplaying) {
        lock.lock()
        if self.minimapDisplay === display {
            self.minimapDisplay = nil
        }
        lock.unlock()
    }

    public func enqueue(_ sampleBuffer: CMSampleBuffer) {
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        lock.lock()
        let observer = sampleObserver
        guard shouldAccept(presentationTime: presentationTime) else {
            lock.unlock()
            observer?(sampleBuffer)
            return
        }
        lastPresentationTime = presentationTime
        lastSampleBuffer = sampleBuffer
        let display = display
        let minimapDisplay = minimapDisplay
        lock.unlock()

        observer?(sampleBuffer)
        display?.enqueue(sampleBuffer, renderMode: renderMode)
        minimapDisplay?.enqueue(sampleBuffer, renderMode: renderMode)
    }

    /// Installs an observer that fires for every sample buffer the coordinator
    /// receives (including ones that would be filtered out as non-monotonic).
    /// `LatencyBench` uses this to tap decoded frames without disturbing the
    /// production render pipeline.
    public func setSampleObserver(_ observer: (@Sendable (CMSampleBuffer) -> Void)?) {
        lock.lock()
        sampleObserver = observer
        lock.unlock()
    }

    public func flush() {
        lock.lock()
        lastPresentationTime = nil
        lastSampleBuffer = nil
        let display = display
        let minimapDisplay = minimapDisplay
        lock.unlock()

        display?.flush()
        minimapDisplay?.flush()
    }

    private func shouldAccept(presentationTime: CMTime) -> Bool {
        guard let lastPresentationTime else { return true }
        return CMTimeCompare(presentationTime, lastPresentationTime) > 0
    }
}
