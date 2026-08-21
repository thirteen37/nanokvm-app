import KVMCore
import SwiftUI

/// A host for UI tests that need real multi-touch against `PointerCaptureView`.
///
/// The gesture recognizers in `PointerCaptureUIView` arbitrate against each other, and that
/// arbitration cannot be exercised from a unit test — synthesizing touches needs a running app.
/// This target exists only so `GestureHarnessUITests` has somewhere to tap. It is never shipped.
@main
struct GestureHarnessApp: App {
    var body: some Scene {
        WindowGroup {
            GestureHarnessView()
        }
    }
}

struct GestureHarnessView: View {
    @StateObject private var zoom = ViewerZoomState()
    // A click is a press followed by a release 50ms later, so the *last* report is always the
    // release. The presses are what the tests are asking about, so keep those.
    @State private var presses: [Int] = []
    @State private var wheelNotches = 0
    @State private var reportCount = 0

    /// Square so the aspect-fit rect is predictable regardless of the simulator's screen size.
    private let videoSize = CGSize(width: 1000, height: 1000)

    var body: some View {
        ZStack {
            Color.black

            PointerCaptureView(
                isEnabled: true,
                isScrollInverted: false,
                videoSize: videoSize,
                zoom: zoom,
                onMouseReport: { report in record(report) },
                onMouseRelease: { report in record(report) }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("pointerCapture")
        }
        .ignoresSafeArea()
        .overlay(alignment: .top) {
            // The UI test reads this rather than the view hierarchy: gesture output is a stream of
            // reports, not view state, so it has to be surfaced somewhere XCUITest can see it.
            Text(stateDescription)
                .accessibilityIdentifier("state")
                .foregroundStyle(.white)
                .font(.caption)
                .padding(6)
        }
    }

    private func record(_ report: HIDMouseAbsoluteReport) {
        reportCount += 1
        if report.buttons != 0 {
            presses.append(Int(report.buttons))
        }
        if report.wheel != 0 {
            wheelNotches += 1
        }
    }

    private var stateDescription: String {
        let pressList = presses.map(String.init).joined(separator: ",")
        let scale = String(format: "%.2f", zoom.scale)
        return "presses=[\(pressList)] wheel=\(wheelNotches) count=\(reportCount) scale=\(scale)"
    }
}
