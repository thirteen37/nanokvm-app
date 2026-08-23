#if os(macOS)
import Foundation

/// Pure arithmetic over Apple's USB `locationID` and the UVC `uniqueID` strings built
/// from it. Both `AVCaptureDevice.uniqueID` and a `/dev/cu.usbserial-NNNN` name encode
/// *where* a device is plugged in, so they change the moment it moves to another port.
/// These helpers separate the part that identifies the hardware (vendor/product) and the
/// part that describes the topology (which hub it hangs off), so a saved selection can be
/// re-resolved after a replug.
enum USBLocationID {
    /// The trailing `VID`+`PID` of a UVC `uniqueID` — the only portion that survives a
    /// move to a different USB port. Returns `nil` for IDs that aren't USB-shaped
    /// (Continuity cameras report a UUID instead).
    static func vendorProductTail(ofVideoUniqueID id: String) -> String? {
        guard let hex = usbHex(ofVideoUniqueID: id) else { return nil }
        return String(hex.suffix(8))
    }

    /// The `locationID` prefix of a UVC `uniqueID`.
    static func locationID(ofVideoUniqueID id: String) -> UInt32? {
        guard let hex = usbHex(ofVideoUniqueID: id) else { return nil }
        return UInt32(hex.dropLast(8), radix: 16)
    }

    /// The `locationID` of the hub a device hangs off.
    ///
    /// A locationID is a nibble-per-tier path: the top byte is the controller and each
    /// following nibble is a port number, zero-padded on the right. Clearing the lowest
    /// non-zero port nibble therefore walks up exactly one tier. A device plugged straight
    /// into the Mac has no hub above it and reports itself, so callers can tell that no
    /// sibling relationship is derivable.
    static func parentLocationID(_ location: UInt32) -> UInt32 {
        // Only the low six nibbles are the port path; the top byte is the controller, and
        // devices on different controllers must never come out as siblings.
        for shift in stride(from: UInt32(0), through: UInt32(20), by: 4)
        where (location >> shift) & 0xF != 0 {
            return location & ~(UInt32(0xF) << shift)
        }
        return location
    }

    /// True when two USB devices hang off the same hub — i.e. are two functions of one
    /// composite gadget such as the NanoKVM-USB stick.
    static func areSiblings(_ lhs: UInt32, _ rhs: UInt32) -> Bool {
        let parent = parentLocationID(lhs)
        guard parent != lhs else { return false }
        return parent == parentLocationID(rhs)
    }

    private static func usbHex(ofVideoUniqueID id: String) -> String? {
        guard id.hasPrefix("0x") else { return nil }
        let hex = id.dropFirst(2)
        // locationID + VID(4) + PID(4): at least one digit of location must remain.
        guard hex.count > 8, hex.allSatisfy(\.isHexDigit) else { return nil }
        return String(hex)
    }
}
#endif
