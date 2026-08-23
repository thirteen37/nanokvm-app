#if os(macOS)
@preconcurrency import AVFoundation
import Foundation
import IOKit
import IOKit.serial

public struct USBSerialPort: Hashable, Sendable {
    public let path: String
    public let displayName: String
    /// USB `locationID` of the device behind this port, used to pair it with the capture
    /// chip on the same stick after a replug. `nil` when the IOKit walk can't find one.
    public let locationID: UInt32?

    public init(path: String, displayName: String, locationID: UInt32? = nil) {
        self.path = path
        self.displayName = displayName
        self.locationID = locationID
    }
}

@MainActor
public enum USBKVMDeviceDiscovery {
    /// Returns USB-attached UVC capture devices (cameras). On macOS 15+ all external
    /// cameras report as `.external`.
    public static func videoDevices() -> [AVCaptureDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external],
            mediaType: .video,
            position: .unspecified
        )
        return discovery.devices
    }

    /// Returns USB-CDC serial ports suitable for the NanoKVM-USB's CH9329 bridge.
    /// Uses IOKit's service registry so we get the vendor/product display name even
    /// when running under the app sandbox.
    public static func serialPorts() -> [USBSerialPort] {
        var iterator: io_iterator_t = 0
        guard let matching = IOServiceMatching(kIOSerialBSDServiceValue) else { return [] }
        // Restrict to /dev/cu.* nodes (callout devices, the right side for outbound serial).
        let dict = matching as NSMutableDictionary
        dict[kIOSerialBSDTypeKey] = kIOSerialBSDAllTypes

        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard result == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var ports: [USBSerialPort] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let path = stringProperty(service, key: kIOCalloutDeviceKey) else { continue }
            guard isLikelyUSBSerial(path: path) else { continue }
            let usb = usbAttributes(for: service)
            let displayName = usb.productName.map { "\($0) (\((path as NSString).lastPathComponent))" }
                ?? (path as NSString).lastPathComponent
            ports.append(
                USBSerialPort(path: path, displayName: displayName, locationID: usb.locationID)
            )
        }

        return ports.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private static func isLikelyUSBSerial(path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return name.hasPrefix("cu.usbserial")
            || name.hasPrefix("cu.usbmodem")
            || name.hasPrefix("cu.wchusbserial")
            || name.hasPrefix("cu.SLAB_USBtoUART")
    }

    private static func stringProperty(_ service: io_object_t, key: String) -> String? {
        guard let raw = IORegistryEntryCreateCFProperty(
            service,
            key as CFString,
            kCFAllocatorDefault,
            0
        ) else { return nil }
        return raw.takeRetainedValue() as? String
    }

    /// Walks up the IOKit parent chain until we hit a USB device node, then returns its
    /// product/vendor name and `locationID`. The name can appear a tier below the node
    /// carrying the locationID, so the walk keeps going until it has both or runs out.
    private static func usbAttributes(
        for service: io_object_t
    ) -> (productName: String?, locationID: UInt32?) {
        var current: io_registry_entry_t = service
        IOObjectRetain(current)
        defer { IOObjectRelease(current) }

        var productName: String?
        var locationID: UInt32?

        for _ in 0..<8 {
            if productName == nil {
                productName = stringProperty(current, key: "USB Product Name")
                    ?? stringProperty(current, key: "USB Vendor Name")
            }
            if locationID == nil {
                locationID = numberProperty(current, key: "locationID")
            }
            if productName != nil, locationID != nil { break }

            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else {
                break
            }
            IOObjectRelease(current)
            current = parent
        }
        return (productName, locationID)
    }

    private static func numberProperty(_ service: io_object_t, key: String) -> UInt32? {
        guard let raw = IORegistryEntryCreateCFProperty(
            service,
            key as CFString,
            kCFAllocatorDefault,
            0
        ) else { return nil }
        return (raw.takeRetainedValue() as? NSNumber)?.uint32Value
    }

    /// Re-resolves a saved camera selection. `AVCaptureDevice.uniqueID` embeds the USB
    /// port the stick was in when it was picked, so an exact hit is only the happy path;
    /// otherwise fall back to the one attached camera with the same vendor/product.
    public static func resolveVideoUniqueID(saved: String) -> String? {
        if AVCaptureDevice(uniqueID: saved) != nil { return saved }

        guard let tail = USBLocationID.vendorProductTail(ofVideoUniqueID: saved) else { return nil }
        let matches = videoDevices().filter {
            USBLocationID.vendorProductTail(ofVideoUniqueID: $0.uniqueID) == tail
        }
        // Two identical sticks attached: nothing distinguishes them, so make the user pick.
        guard matches.count == 1 else { return nil }
        return matches[0].uniqueID
    }

    /// Re-resolves a saved serial selection. `/dev/cu.usbserial-NNNN` names encode the USB
    /// port too, so when the saved node is gone, pair the serial bridge to the already
    /// resolved capture chip by finding the port that hangs off the same hub — on a
    /// NanoKVM-USB the two are functions of one hub, whichever Mac port it lands in.
    public static func resolveSerialPath(saved: String, videoUniqueID: String) -> String? {
        let ports = serialPorts()
        if ports.contains(where: { $0.path == saved }) { return saved }

        guard let cameraLocation = USBLocationID.locationID(ofVideoUniqueID: videoUniqueID) else {
            return nil
        }
        let siblings = ports.filter { port in
            guard let location = port.locationID else { return false }
            return USBLocationID.areSiblings(cameraLocation, location)
        }
        guard siblings.count == 1 else { return nil }
        return siblings[0].path
    }
}
#endif
