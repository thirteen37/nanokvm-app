import XCTest
@testable import KVMCore

final class HIDKeyboardReportTests: XCTestCase {
    func test_reportBuildsNanoKVMKeyboardMessage() {
        let report = HIDKeyboardReport(modifier: 0x02, keycodes: [0x04, 0x05])

        XCTAssertEqual(
            report.nanoKVMMessageData,
            Data([0x01, 0x02, 0x00, 0x04, 0x05, 0x00, 0x00, 0x00, 0x00])
        )
    }

    func test_reportTruncatesToSixKeys() {
        let report = HIDKeyboardReport(keycodes: [1, 2, 3, 4, 5, 6, 7])

        XCTAssertEqual(report.bootReportBytes, [0, 0, 1, 2, 3, 4, 5, 6])
    }

    func test_builderTracksKeysAndModifiers() {
        let builder = HIDKeyboardReportBuilder()

        XCTAssertEqual(builder.keyDown(usage: 0x04), HIDKeyboardReport(keycodes: [0x04]))
        XCTAssertEqual(builder.modifierChanged(bit: 0x02, isPressed: true), HIDKeyboardReport(modifier: 0x02, keycodes: [0x04]))
        XCTAssertEqual(builder.keyDown(usage: 0x05), HIDKeyboardReport(modifier: 0x02, keycodes: [0x04, 0x05]))
        XCTAssertEqual(builder.keyUp(usage: 0x04), HIDKeyboardReport(modifier: 0x02, keycodes: [0x05]))
        XCTAssertEqual(builder.modifierChanged(bit: 0x02, isPressed: false), HIDKeyboardReport(keycodes: [0x05]))
        XCTAssertEqual(builder.reset(), HIDKeyboardReport())
    }

    func test_builderIgnoresDuplicateKeyDowns() {
        let builder = HIDKeyboardReportBuilder()

        _ = builder.keyDown(usage: 0x04)
        XCTAssertEqual(builder.keyDown(usage: 0x04), HIDKeyboardReport(keycodes: [0x04]))
    }

    func test_currentReportReflectsHeldKeysAndModifiers() {
        let builder = HIDKeyboardReportBuilder()
        _ = builder.modifierChanged(bit: HIDModifierBit.leftControl.rawValue, isPressed: true)
        _ = builder.keyDown(usage: 0x04)

        let report = builder.currentReport

        XCTAssertEqual(report.modifier, HIDModifierBit.leftControl.rawValue)
        XCTAssertEqual(report.keycodes, [0x04])
    }
}
