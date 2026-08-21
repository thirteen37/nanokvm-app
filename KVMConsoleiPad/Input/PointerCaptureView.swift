import KVMCore
import SwiftUI
import UIKit

struct PointerCaptureView: UIViewRepresentable {
    let isEnabled: Bool
    let isScrollInverted: Bool
    let videoSize: CGSize?
    let zoom: ViewerZoomState
    let onMouseReport: @MainActor (HIDMouseAbsoluteReport) -> Void
    let onMouseRelease: @MainActor (HIDMouseAbsoluteReport) -> Void

    func makeUIView(context: Context) -> PointerCaptureUIView {
        let view = PointerCaptureUIView()
        view.onMouseReport = onMouseReport
        view.onMouseRelease = onMouseRelease
        view.isCaptureEnabled = isEnabled
        view.isScrollInverted = isScrollInverted
        view.videoSize = videoSize
        view.zoom = zoom
        return view
    }

    func updateUIView(_ uiView: PointerCaptureUIView, context: Context) {
        uiView.onMouseReport = onMouseReport
        uiView.onMouseRelease = onMouseRelease
        uiView.isCaptureEnabled = isEnabled
        uiView.isScrollInverted = isScrollInverted
        uiView.videoSize = videoSize
        uiView.zoom = zoom
    }
}

final class PointerCaptureUIView: UIView, UIGestureRecognizerDelegate {
    var isCaptureEnabled = false {
        didSet {
            if !isCaptureEnabled {
                releaseHeldButtons()
            }
        }
    }
    var isScrollInverted = true
    var videoSize: CGSize?
    var zoom: ViewerZoomState?
    var onMouseReport: (@MainActor (HIDMouseAbsoluteReport) -> Void)?
    var onMouseRelease: (@MainActor (HIDMouseAbsoluteReport) -> Void)?

    private let mouseReportBuilder = HIDMouseAbsoluteReportBuilder()
    private var scrollAccumulator = MouseScrollAccumulator()
    private var activeDragButtonNumber: Int?
    private let clickSequencer = SynthesizedTapSequencer()
    private weak var pinchRecognizer: UIPinchGestureRecognizer?
    private weak var pointerPanRecognizer: UIPanGestureRecognizer?
    private var pinchAnchorVideo: CGPoint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = true

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        addGestureRecognizer(hover)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.allowedScrollTypesMask = [.continuous, .discrete]
        pan.maximumNumberOfTouches = 2
        pan.delegate = self
        addGestureRecognizer(pan)
        pointerPanRecognizer = pan

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        addGestureRecognizer(pinch)
        pinchRecognizer = pinch

        let primaryTap = UITapGestureRecognizer(target: self, action: #selector(handlePrimaryTap(_:)))
        primaryTap.buttonMaskRequired = .primary
        addGestureRecognizer(primaryTap)

        let secondaryTap = UITapGestureRecognizer(target: self, action: #selector(handleSecondaryTap(_:)))
        secondaryTap.buttonMaskRequired = .secondary
        addGestureRecognizer(secondaryTap)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func handleHover(_ recognizer: UIHoverGestureRecognizer) {
        guard isCaptureEnabled else { return }
        // `move` keeps the buttons byte, so emitting one while a synthesized click is still held
        // would read on the host as a drag. The pointer catches up when the click releases.
        guard !clickSequencer.isHoldingPress else { return }
        let location = recognizer.location(in: self)
        let effective = effectiveRect()
        let normalized = MouseCoordinateMapper.normalizedPoint(clientPoint: location, effectiveRect: effective)
        let absolute = MouseCoordinateMapper.absolutePoint(clientPoint: location, effectiveRect: effective)
        emit(mouseReportBuilder.move(x: absolute.x, y: absolute.y))
        zoom?.cursorNormalized = normalized
        zoom?.ensureCursorVisible(cursorNormalized: normalized)
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard isCaptureEnabled else {
            releaseHeldButtons()
            return
        }
        let location = recognizer.location(in: self)
        let effective = effectiveRect()
        let normalized = MouseCoordinateMapper.normalizedPoint(clientPoint: location, effectiveRect: effective)
        let point = MouseCoordinateMapper.absolutePoint(clientPoint: location, effectiveRect: effective)
        let dragButtonNumber = activeDragButtonNumber
            ?? PointerDragButtonResolver.buttonNumber(
                buttonMask: recognizer.buttonMask,
                touchCount: recognizer.numberOfTouches
            )

        switch recognizer.state {
        case .began:
            if let dragButtonNumber {
                clickSequencer.cancelAll()
                activeDragButtonNumber = dragButtonNumber
                emit(mouseReportBuilder.buttonDown(buttonNumber: dragButtonNumber, x: point.x, y: point.y))
            } else {
                emit(mouseReportBuilder.move(x: point.x, y: point.y))
            }
        case .changed:
            if activeDragButtonNumber == nil, let dragButtonNumber {
                clickSequencer.cancelAll()
                activeDragButtonNumber = dragButtonNumber
                emit(mouseReportBuilder.buttonDown(buttonNumber: dragButtonNumber, x: point.x, y: point.y))
            }
            emit(mouseReportBuilder.move(x: point.x, y: point.y))
        case .ended, .cancelled, .failed:
            if let activeDragButtonNumber {
                emit(mouseReportBuilder.buttonUp(buttonNumber: activeDragButtonNumber, x: point.x, y: point.y))
                self.activeDragButtonNumber = nil
            } else {
                emit(mouseReportBuilder.move(x: point.x, y: point.y))
            }
        default:
            break
        }

        if recognizer.state == .changed || recognizer.state == .began {
            zoom?.cursorNormalized = normalized
            if activeDragButtonNumber != nil || dragButtonNumber != nil {
                zoom?.ensureCursorVisible(cursorNormalized: normalized)
            }
        }

        guard activeDragButtonNumber == nil, dragButtonNumber == nil else {
            recognizer.setTranslation(.zero, in: self)
            return
        }

        // Trackpad scroll input reports `numberOfTouches == 0`; two-or-more direct
        // touches are routed to wheel scrolling. One-finger pans move or drag the pointer.
        guard PointerScrollResolver.shouldEmitWheel(touchCount: recognizer.numberOfTouches) else {
            recognizer.setTranslation(.zero, in: self)
            return
        }
        // While a pinch is in flight, suppress wheel emission — the two fingers are zooming.
        if let pinch = pinchRecognizer, pinch.state == .began || pinch.state == .changed {
            recognizer.setTranslation(.zero, in: self)
            return
        }
        // `translation(in:)` is cumulative since the gesture began (or last reset), and
        // `MouseScrollAccumulator` adds its argument to its own running total. Reset every
        // callback so each call contributes only the delta since the previous one.
        let translation = recognizer.translation(in: self)
        recognizer.setTranslation(.zero, in: self)
        if let wheelDelta = scrollAccumulator.notches(
            for: translation.y,
            isInverted: isScrollInverted
        ) {
            emit(mouseReportBuilder.wheel(wheelDelta, x: point.x, y: point.y))
        }
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        guard let zoom else { return }
        let centroid = recognizer.location(in: self)
        let baseRect = MouseCoordinateMapper.aspectFitRect(for: videoSize, in: bounds)
        guard baseRect.width > 0, baseRect.height > 0 else {
            recognizer.scale = 1
            return
        }
        switch recognizer.state {
        case .began:
            // Anchor the video point currently under the centroid for the rest of the gesture so
            // the fingers grip that point: subsequent spreads scale around it AND translations of
            // the centroid pan it to follow the fingers.
            pinchAnchorVideo = CGPoint(
                x: zoom.center.x + (centroid.x - bounds.midX) / (baseRect.width * zoom.scale),
                y: zoom.center.y + (centroid.y - bounds.midY) / (baseRect.height * zoom.scale)
            )
            recognizer.scale = 1
        case .changed:
            guard let anchor = pinchAnchorVideo else { return }
            let factor = recognizer.scale
            recognizer.scale = 1
            zoom.applyPinchPan(
                factor: factor,
                anchorVideo: anchor,
                centroidInContainer: centroid,
                containerBounds: bounds,
                baseRect: baseRect
            )
        case .ended, .cancelled, .failed:
            pinchAnchorVideo = nil
        default:
            break
        }
    }

    @objc private func handlePrimaryTap(_ recognizer: UITapGestureRecognizer) {
        emitClick(buttonNumber: 0, at: recognizer.location(in: self))
    }

    @objc private func handleSecondaryTap(_ recognizer: UITapGestureRecognizer) {
        emitClick(buttonNumber: 1, at: recognizer.location(in: self))
    }

    private func emitClick(buttonNumber: Int, at location: CGPoint) {
        guard isCaptureEnabled else { return }
        let effective = effectiveRect()
        let normalized = MouseCoordinateMapper.normalizedPoint(clientPoint: location, effectiveRect: effective)
        let point = MouseCoordinateMapper.absolutePoint(clientPoint: location, effectiveRect: effective)
        clickSequencer.tap(
            down: { [weak self] in
                guard let self else { return }
                self.emit(self.mouseReportBuilder.buttonDown(buttonNumber: buttonNumber, x: point.x, y: point.y))
            },
            up: { [weak self] in
                guard let self else { return }
                self.emitRelease(self.mouseReportBuilder.buttonUp(buttonNumber: buttonNumber, x: point.x, y: point.y))
            }
        )
        zoom?.cursorNormalized = normalized
    }

    private func releaseHeldButtons() {
        clickSequencer.cancelAll()
        guard activeDragButtonNumber != nil else { return }
        activeDragButtonNumber = nil
        emitRelease(mouseReportBuilder.reset())
    }

    // UIGestureRecognizer callbacks run on the main thread; assuming
    // MainActor isolation here keeps the call site synchronous and avoids
    // the run-loop hop that `Task { @MainActor in ... }` would impose on
    // every pointer event.
    private func emit(_ report: HIDMouseAbsoluteReport) {
        guard let onMouseReport else { return }
        MainActor.assumeIsolated {
            onMouseReport(report)
        }
    }

    /// Releases go through their own channel: by the time capture is switched off the guarded
    /// path drops everything, which would strand a held button on the host.
    private func emitRelease(_ report: HIDMouseAbsoluteReport) {
        guard let onMouseRelease else { return }
        MainActor.assumeIsolated {
            onMouseRelease(report)
        }
    }

    private func effectiveRect() -> CGRect {
        let baseRect = MouseCoordinateMapper.aspectFitRect(for: videoSize, in: bounds)
        guard let zoom else { return baseRect }
        return zoom.effectiveVideoRect(in: bounds, baseRect: baseRect)
    }

    // MARK: UIGestureRecognizerDelegate

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        // Pinch should coexist with the pointer pan so two-finger zoom/pan doesn't fail-cancel
        // the pan's wheel-scroll tracking (we suppress wheel emission while pinch is active).
        return true
    }
}

enum PointerDragButtonResolver {
    static func buttonNumber(buttonMask: UIEvent.ButtonMask, touchCount: Int) -> Int? {
        if buttonMask.contains(.primary) {
            return 0
        }
        if buttonMask.contains(.secondary) {
            return 1
        }
        if touchCount == 1 {
            return 0
        }
        return nil
    }
}

enum PointerScrollResolver {
    static func shouldEmitWheel(touchCount: Int) -> Bool {
        touchCount == 0 || touchCount >= 2
    }
}
