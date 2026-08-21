import KVMCore
@testable import KVMConsoleiPad
import UIKit
import XCTest

final class KVMConsoleiPadTests: XCTestCase {
    func test_uiKeyHIDUsageRoundTripsThroughKeyboardReport() {
        let report = HIDKeyboardReport(keycodes: [UInt8(UIKeyboardHIDUsage.keyboardA.rawValue)])

        XCTAssertEqual(report.bootReportBytes, [0, 0, 0x04, 0, 0, 0, 0, 0])
    }

    func test_modifierStateMergesMomentaryAndLockedBits() {
        var state = ModifierKeyState()

        state.toggleMomentary(HIDModifierBit.leftControl.rawValue)
        state.toggleLocked(HIDModifierBit.leftShift.rawValue)

        XCTAssertEqual(
            state.activeModifierByte,
            HIDModifierBit.leftControl.rawValue | HIDModifierBit.leftShift.rawValue
        )

        state.consumeMomentary()

        XCTAssertEqual(state.activeModifierByte, HIDModifierBit.leftShift.rawValue)
    }

    func test_characterMapUppercaseAddsShift() throws {
        let stroke = try XCTUnwrap(CharacterHIDMap.stroke(for: "A"))

        XCTAssertEqual(stroke.usage, 0x04)
        XCTAssertEqual(stroke.modifier, HIDModifierBit.leftShift.rawValue)
    }

    func test_pointerDragResolverTreatsDirectTouchAsPrimaryDrag() {
        XCTAssertEqual(
            PointerDragButtonResolver.buttonNumber(buttonMask: [], touchCount: 1),
            0
        )
        XCTAssertNil(PointerDragButtonResolver.buttonNumber(buttonMask: [], touchCount: 2))
    }

    func test_pointerDragResolverUsesIndirectPointerButtonMask() {
        XCTAssertEqual(
            PointerDragButtonResolver.buttonNumber(buttonMask: .primary, touchCount: 0),
            0
        )
        XCTAssertEqual(
            PointerDragButtonResolver.buttonNumber(buttonMask: .secondary, touchCount: 0),
            1
        )
        XCTAssertNil(PointerDragButtonResolver.buttonNumber(buttonMask: [], touchCount: 0))
    }

    func test_pointerScrollResolverAllowsTrackpadAndMultiTouchScroll() {
        XCTAssertTrue(PointerScrollResolver.shouldEmitWheel(touchCount: 0))
        XCTAssertFalse(PointerScrollResolver.shouldEmitWheel(touchCount: 1))
        XCTAssertTrue(PointerScrollResolver.shouldEmitWheel(touchCount: 2))
    }

    func test_modifierBarHiddenWhenPhysicalKeyboardConnected() {
        XCTAssertFalse(
            ModifierBarVisibility.shouldShow(userEnabled: true, physicalKeyboardConnected: true)
        )
    }

    func test_modifierBarVisibleWhenEnabledAndNoPhysicalKeyboard() {
        XCTAssertTrue(
            ModifierBarVisibility.shouldShow(userEnabled: true, physicalKeyboardConnected: false)
        )
    }

    func test_modifierBarHiddenWhenUserDisablesIt() {
        XCTAssertFalse(
            ModifierBarVisibility.shouldShow(userEnabled: false, physicalKeyboardConnected: false)
        )
    }

    // MARK: Tap button routing

    /// A direct touch carries no buttons, and `buttonMaskRequired` is only evaluated for indirect
    /// input — so without a touch-type restriction a finger tap matches the secondary recognizer
    /// too, and UIKit lets that one win. Every tap then arrives at the host as a right click.
    @MainActor
    func test_secondaryTapIgnoresDirectTouches() {
        let view = PointerCaptureUIView()
        let taps = (view.gestureRecognizers ?? []).compactMap { $0 as? UITapGestureRecognizer }
        let secondary = taps.first { $0.buttonMaskRequired == .secondary }
        let primary = taps.first { $0.buttonMaskRequired == .primary }

        XCTAssertEqual(
            secondary?.allowedTouchTypes,
            [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)],
            "a finger tap must never reach the secondary recognizer"
        )
        XCTAssertNotNil(primary, "finger taps still need a primary recognizer to land on")
        XCTAssertFalse(
            primary?.allowedTouchTypes == [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)],
            "the primary recognizer must keep accepting direct touches"
        )
    }

    /// The only way to right-click without a trackpad or mouse attached.
    @MainActor
    func test_twoFingerTapIsTheTouchscreenRightClick() {
        let view = PointerCaptureUIView()
        let taps = (view.gestureRecognizers ?? []).compactMap { $0 as? UITapGestureRecognizer }
        let twoFinger = taps.first { $0.numberOfTouchesRequired == 2 }

        XCTAssertNotNil(twoFinger, "a bare touchscreen has no other way to send a secondary click")
        XCTAssertEqual(
            twoFinger?.allowedTouchTypes,
            [NSNumber(value: UITouch.TouchType.direct.rawValue)],
            "a trackpad two-finger tap already arrives as an indirect secondary click; both firing would double-click"
        )
    }

    /// The two-finger tap has to be arbitrated against pan and pinch differently, and the
    /// difference was established by running real multi-touch through `GestureHarnessUITests`:
    ///
    /// - The **pan** claims two touches the moment they land and begins before the tap can
    ///   complete, so it must wait for the tap to fail. That is what makes the tap fire at all.
    /// - The **pinch** must NOT wait: making it wait starves it completely, so a spread fires a
    ///   right click instead of zooming. It is kept off the tap by mutual exclusion instead —
    ///   a pinch begins as soon as the fingers move, which cancels the tap.
    @MainActor
    func test_twoFingerTapArbitratesAgainstPanAndPinchDifferently() {
        let view = PointerCaptureUIView()
        let recognizers = view.gestureRecognizers ?? []
        let taps = recognizers.compactMap { $0 as? UITapGestureRecognizer }
        guard
            let twoFinger = taps.first(where: { $0.numberOfTouchesRequired == 2 }),
            let pinch = recognizers.compactMap({ $0 as? UIPinchGestureRecognizer }).first,
            let pan = recognizers.compactMap({ $0 as? UIPanGestureRecognizer }).first
        else {
            return XCTFail("expected a two-finger tap, a pinch and a pan on the capture view")
        }

        XCTAssertTrue(
            view.gestureRecognizer(pan, shouldRequireFailureOf: twoFinger),
            "without this the pan begins first and the two-finger tap never fires"
        )
        XCTAssertFalse(
            view.gestureRecognizer(pinch, shouldRequireFailureOf: twoFinger),
            "making the pinch wait starves it: a spread fires a right click instead of zooming"
        )
        XCTAssertFalse(
            view.gestureRecognizer(pinch, shouldRecognizeSimultaneouslyWith: twoFinger),
            "otherwise a spread both zooms and fires a right click"
        )
        XCTAssertTrue(
            view.gestureRecognizer(pinch, shouldRecognizeSimultaneouslyWith: pan),
            "pinch and pan still coexist so zooming doesn't fail-cancel wheel tracking"
        )
    }

    // MARK: Synthesized tap dwell

    @MainActor
    func test_synthesizedTapHoldsButtonBeforeReleasing() async {
        let sleeper = RecordingSleeper()
        let sequencer = SynthesizedTapSequencer(sleep: { await sleeper.sleep($0) })
        let log = TapLog()
        let released = expectation(description: "release emitted")

        sequencer.tap(
            down: { log.append("down") },
            up: { log.append("up"); released.fulfill() }
        )

        XCTAssertEqual(log.events, ["down"], "release must not be emitted in the same instant as the press")

        await fulfillment(of: [released], timeout: 2)

        XCTAssertEqual(log.events, ["down", "up"])
        XCTAssertEqual(
            sleeper.durations,
            [SynthesizedTapSequencer.defaultPressDuration],
            "the button has to be held long enough for the host to poll it"
        )
    }

    /// `insertText` synthesizes a whole string's keystrokes in one pass, so taps queued while
    /// another is still held must each get their own hold rather than collapsing.
    @MainActor
    func test_queuedTapsEachGetTheirOwnHold() async {
        let sleeper = RecordingSleeper()
        let sequencer = SynthesizedTapSequencer(sleep: { await sleeper.sleep($0) })
        let log = TapLog()
        let finished = expectation(description: "second release emitted")

        sequencer.tap(down: { log.append("down1") }, up: { log.append("up1") })
        sequencer.tap(down: { log.append("down2") }, up: { log.append("up2"); finished.fulfill() })

        XCTAssertEqual(log.events, ["down1"], "the queued tap must wait for the held one to be released")

        await fulfillment(of: [finished], timeout: 2)

        XCTAssertEqual(log.events, ["down1", "up1", "down2", "up2"])
        XCTAssertEqual(sleeper.durations.count, 2, "each tap gets its own hold")
    }

    // MARK: Virtual keys

    @MainActor
    func test_virtualKeyIsHeldRatherThanReleasedInTheSameInstant() async {
        let view = KeyboardCaptureUIView()
        let log = TapLog()
        let released = expectation(description: "key release emitted")
        view.onKeyboardReport = { _ in log.append("down") }
        view.onKeyboardRelease = { _ in
            log.append("up")
            released.fulfill()
        }

        view.sendVirtualKey(usage: 0x04, transientModifier: HIDModifierBit.leftShift.rawValue)

        XCTAssertEqual(log.events, ["down"], "the key release must not land in the same instant as the press")

        await fulfillment(of: [released], timeout: 2)

        XCTAssertEqual(log.events, ["down", "up"])
    }

    @MainActor
    func test_disablingCaptureReleasesAHeldVirtualKey() {
        let view = KeyboardCaptureUIView()
        let log = TapLog()
        view.onKeyboardReport = { _ in log.append("down") }
        view.onKeyboardRelease = { _ in log.append("up") }
        view.isCaptureEnabled = true

        view.sendVirtualKey(usage: 0x04, transientModifier: 0)
        XCTAssertEqual(log.events, ["down"])

        view.isCaptureEnabled = false

        XCTAssertEqual(log.events, ["down", "up"], "a key held when capture is switched off must be released")
    }
}

/// Collects emitted tap phases by reference so the escaping down/up closures don't have to
/// capture a mutable local.
private final class TapLog {
    private(set) var events: [String] = []

    func append(_ event: String) {
        events.append(event)
    }
}

/// Stands in for `Task.sleep`: records the dwell that was asked for and returns immediately, so
/// the tests assert ordering and duration without waiting on the clock.
private final class RecordingSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var storedDurations: [Duration] = []

    var durations: [Duration] {
        lock.withLock { storedDurations }
    }

    func sleep(_ duration: Duration) async {
        lock.withLock { storedDurations.append(duration) }
    }
}
