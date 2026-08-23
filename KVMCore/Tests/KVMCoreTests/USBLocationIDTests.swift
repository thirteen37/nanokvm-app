#if os(macOS)
import XCTest
@testable import KVMCore

final class USBLocationIDTests: XCTestCase {
    // A UVC uniqueID is "0x" + locationID + VID(4) + PID(4). Only the tail identifies
    // the hardware; the locationID changes whenever the stick moves to another port.
    func testSplitsUVCUniqueIDIntoLocationAndVendorProduct() {
        XCTAssertEqual(USBLocationID.vendorProductTail(ofVideoUniqueID: "0x2120000345f2131"), "345f2131")
        XCTAssertEqual(USBLocationID.locationID(ofVideoUniqueID: "0x2120000345f2131"), 0x0212_0000)
    }

    func testSameStickInADifferentPortKeepsItsVendorProductTail() {
        XCTAssertEqual(
            USBLocationID.vendorProductTail(ofVideoUniqueID: "0x1120000345f2131"),
            USBLocationID.vendorProductTail(ofVideoUniqueID: "0x2120000345f2131")
        )
        XCTAssertNotEqual(
            USBLocationID.locationID(ofVideoUniqueID: "0x1120000345f2131"),
            USBLocationID.locationID(ofVideoUniqueID: "0x2120000345f2131")
        )
    }

    func testRejectsNonUSBUniqueIDs() {
        // Continuity cameras report a UUID, not a locationID+VID/PID string.
        XCTAssertNil(USBLocationID.vendorProductTail(ofVideoUniqueID: "47009D72-9914-4C70-B4D2-D6ED00000001"))
        XCTAssertNil(USBLocationID.locationID(ofVideoUniqueID: "47009D72-9914-4C70-B4D2-D6ED00000001"))
        XCTAssertNil(USBLocationID.vendorProductTail(ofVideoUniqueID: "0x345f2131"))
        XCTAssertNil(USBLocationID.locationID(ofVideoUniqueID: ""))
    }

    // The NanoKVM-USB is a hub with the capture chip and the CH340 behind it, so the two
    // halves of one stick share a parent hub no matter which Mac port it lands in.
    func testCaptureChipAndSerialBridgeOnOneStickShareAParentHub() {
        let camera = USBLocationID.parentLocationID(0x0212_0000)
        let serial = USBLocationID.parentLocationID(0x0214_0000)
        XCTAssertEqual(camera, 0x0210_0000)
        XCTAssertEqual(serial, 0x0210_0000)
    }

    func testParentOfAHubIsItsOwnParentPort() {
        XCTAssertEqual(USBLocationID.parentLocationID(0x0210_0000), 0x0200_0000)
    }

    func testDevicesOnDifferentControllersAreNeverSiblings() {
        XCTAssertNotEqual(
            USBLocationID.parentLocationID(0x0212_0000),
            USBLocationID.parentLocationID(0x0112_0000)
        )
    }

    // A device plugged straight into the Mac has no hub parent; reporting itself signals
    // "no sibling relationship can be derived" so callers don't pair unrelated devices.
    func testRootDeviceReportsItselfAsItsOwnParent() {
        XCTAssertEqual(USBLocationID.parentLocationID(0x0200_0000), 0x0200_0000)
    }
}
#endif
