@preconcurrency import AVFoundation
import KVMCore
import SwiftUI

struct VideoRenderView: NSViewRepresentable {
    let renderCoordinator: SampleBufferRenderCoordinator
    let scale: CGFloat
    let center: CGPoint
    let videoSize: CGSize?

    func makeCoordinator() -> Coordinator {
        Coordinator(renderCoordinator: renderCoordinator)
    }

    func makeNSView(context: Context) -> SampleBufferDisplayView {
        let view = SampleBufferDisplayView()
        context.coordinator.renderCoordinator.attach(display: view.display)
        view.applyZoom(scale: scale, center: center, videoSize: videoSize)
        return view
    }

    func updateNSView(_ nsView: SampleBufferDisplayView, context: Context) {
        context.coordinator.renderCoordinator.attach(display: nsView.display)
        nsView.applyZoom(scale: scale, center: center, videoSize: videoSize)
    }

    static func dismantleNSView(_ nsView: SampleBufferDisplayView, coordinator: Coordinator) {
        coordinator.renderCoordinator.detach(display: nsView.display)
    }

    final class Coordinator {
        let renderCoordinator: SampleBufferRenderCoordinator

        init(renderCoordinator: SampleBufferRenderCoordinator) {
            self.renderCoordinator = renderCoordinator
        }
    }
}

/// Renders the full unzoomed remote frame for the zoom minimap. It reuses
/// `SampleBufferDisplayView` (default scale 1 / center 0.5 → identity transform,
/// i.e. the whole frame) and feeds off the coordinator's separate minimap
/// channel, so it never evicts the main viewer display.
struct MinimapVideoRenderView: NSViewRepresentable {
    let renderCoordinator: SampleBufferRenderCoordinator

    /// The minimap is at most `MinimapView.maxSize` (200 pt) on its longest side;
    /// at up to 2× Retina that is 400 px. Capping the `.directLatestFrame` CPU
    /// frame at this size avoids duplicating the main display's full-resolution
    /// per-frame copy just to render a thumbnail.
    private static let maxPixelDimension: CGFloat = 400

    func makeCoordinator() -> Coordinator {
        Coordinator(renderCoordinator: renderCoordinator)
    }

    func makeNSView(context: Context) -> SampleBufferDisplayView {
        let view = SampleBufferDisplayView()
        view.display.directFrameMaxDimension = Self.maxPixelDimension
        context.coordinator.renderCoordinator.attachMinimap(display: view.display)
        return view
    }

    func updateNSView(_ nsView: SampleBufferDisplayView, context: Context) {
        nsView.display.directFrameMaxDimension = Self.maxPixelDimension
        context.coordinator.renderCoordinator.attachMinimap(display: nsView.display)
    }

    static func dismantleNSView(_ nsView: SampleBufferDisplayView, coordinator: Coordinator) {
        coordinator.renderCoordinator.detachMinimap(display: nsView.display)
    }

    final class Coordinator {
        let renderCoordinator: SampleBufferRenderCoordinator

        init(renderCoordinator: SampleBufferRenderCoordinator) {
            self.renderCoordinator = renderCoordinator
        }
    }
}

final class SampleBufferDisplayView: NSView {
    let display = SampleBufferDisplay()
    private var currentScale: CGFloat = 1.0
    private var currentCenter: CGPoint = CGPoint(x: 0.5, y: 0.5)
    private var currentVideoSize: CGSize?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let container = CALayer()
        container.backgroundColor = CGColor(gray: 0, alpha: 1)
        container.masksToBounds = true
        layer = container
        container.addSublayer(display.layer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        layer?.frame = bounds
        // Setting `.frame` while an affine transform is non-identity is documented as undefined
        // (Core Animation back-solves bounds against the transform). Reset to identity, then
        // size the layer, then reapply the zoom transform.
        display.setVideoTransform(.identity)
        display.layer.frame = bounds
        refreshTransform()
    }

    func applyZoom(scale: CGFloat, center: CGPoint, videoSize: CGSize?) {
        currentScale = scale
        currentCenter = center
        currentVideoSize = videoSize
        refreshTransform()
    }

    private func refreshTransform() {
        let baseRect = MouseCoordinateMapper.aspectFitRect(for: currentVideoSize, in: bounds)
        let tx = -(currentCenter.x - 0.5) * baseRect.width * currentScale
        // The NSView backing layer is y-up; center.y is in y-down (top of video = 0), so panning
        // toward the bottom of the video means moving the layer's content up in screen space —
        // which is +y in this layer's coordinate system.
        let ty = (currentCenter.y - 0.5) * baseRect.height * currentScale
        let transform = CGAffineTransform(scaleX: currentScale, y: currentScale)
            .concatenating(CGAffineTransform(translationX: tx, y: ty))
        display.setVideoTransform(transform)
    }
}
