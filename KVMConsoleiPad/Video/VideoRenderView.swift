import KVMCore
import SwiftUI

struct VideoRenderView: UIViewRepresentable {
    let renderCoordinator: SampleBufferRenderCoordinator
    let scale: CGFloat
    let center: CGPoint
    let videoSize: CGSize?

    func makeCoordinator() -> Coordinator {
        Coordinator(renderCoordinator: renderCoordinator)
    }

    func makeUIView(context: Context) -> SampleBufferDisplayUIView {
        let view = SampleBufferDisplayUIView()
        context.coordinator.renderCoordinator.attach(display: view.display)
        view.applyZoom(scale: scale, center: center, videoSize: videoSize)
        return view
    }

    func updateUIView(_ uiView: SampleBufferDisplayUIView, context: Context) {
        context.coordinator.renderCoordinator.attach(display: uiView.display)
        uiView.applyZoom(scale: scale, center: center, videoSize: videoSize)
    }

    static func dismantleUIView(_ uiView: SampleBufferDisplayUIView, coordinator: Coordinator) {
        coordinator.renderCoordinator.detach(display: uiView.display)
    }

    final class Coordinator {
        let renderCoordinator: SampleBufferRenderCoordinator

        init(renderCoordinator: SampleBufferRenderCoordinator) {
            self.renderCoordinator = renderCoordinator
        }
    }
}

/// Renders the full unzoomed remote frame for the zoom minimap. It reuses
/// `SampleBufferDisplayUIView` (default scale 1 / center 0.5 → identity
/// transform, i.e. the whole frame) and feeds off the coordinator's separate
/// minimap channel, so it never evicts the main viewer display.
struct MinimapVideoRenderView: UIViewRepresentable {
    let renderCoordinator: SampleBufferRenderCoordinator

    /// The minimap is at most `MinimapView.maxSize` (200 pt) on its longest side;
    /// at 2× Retina that is 400 px. Capping the `.directLatestFrame` CPU frame at
    /// this size avoids duplicating the main display's full-resolution per-frame
    /// copy just to render a thumbnail.
    private static let maxPixelDimension: CGFloat = 400

    func makeCoordinator() -> Coordinator {
        Coordinator(renderCoordinator: renderCoordinator)
    }

    func makeUIView(context: Context) -> SampleBufferDisplayUIView {
        let view = SampleBufferDisplayUIView()
        view.display.directFrameMaxDimension = Self.maxPixelDimension
        context.coordinator.renderCoordinator.attachMinimap(display: view.display)
        return view
    }

    func updateUIView(_ uiView: SampleBufferDisplayUIView, context: Context) {
        uiView.display.directFrameMaxDimension = Self.maxPixelDimension
        context.coordinator.renderCoordinator.attachMinimap(display: uiView.display)
    }

    static func dismantleUIView(_ uiView: SampleBufferDisplayUIView, coordinator: Coordinator) {
        coordinator.renderCoordinator.detachMinimap(display: uiView.display)
    }

    final class Coordinator {
        let renderCoordinator: SampleBufferRenderCoordinator

        init(renderCoordinator: SampleBufferRenderCoordinator) {
            self.renderCoordinator = renderCoordinator
        }
    }
}

final class SampleBufferDisplayUIView: UIView {
    let display = SampleBufferDisplay()
    private var currentScale: CGFloat = 1.0
    private var currentCenter: CGPoint = CGPoint(x: 0.5, y: 0.5)
    private var currentVideoSize: CGSize?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        layer.addSublayer(display.layer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyZoom(scale: CGFloat, center: CGPoint, videoSize: CGSize?) {
        currentScale = scale
        currentCenter = center
        currentVideoSize = videoSize
        refreshTransform()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Setting `.frame` while an affine transform is non-identity is documented as undefined
        // (Core Animation back-solves bounds against the transform). Reset to identity, then
        // size the layer, then reapply the zoom transform.
        display.setVideoTransform(.identity)
        display.layer.frame = bounds
        refreshTransform()
    }

    private func refreshTransform() {
        let baseRect = MouseCoordinateMapper.aspectFitRect(for: currentVideoSize, in: bounds)
        let tx = -(currentCenter.x - 0.5) * baseRect.width * currentScale
        let ty = -(currentCenter.y - 0.5) * baseRect.height * currentScale
        let transform = CGAffineTransform(scaleX: currentScale, y: currentScale)
            .concatenating(CGAffineTransform(translationX: tx, y: ty))
        display.setVideoTransform(transform)
    }
}
