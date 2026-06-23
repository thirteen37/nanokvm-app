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
}
