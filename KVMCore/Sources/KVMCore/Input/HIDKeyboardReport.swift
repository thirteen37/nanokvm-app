import Foundation

public struct HIDKeyboardReport: Equatable, Sendable {
    public static let maxKeys = 6

    public var modifier: UInt8
    public var keycodes: [UInt8]

    public init(modifier: UInt8 = 0, keycodes: [UInt8] = []) {
        self.modifier = modifier
        self.keycodes = Array(keycodes.prefix(Self.maxKeys))
    }

    public var bootReportBytes: [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 8)
        bytes[0] = modifier
        for (index, keycode) in keycodes.prefix(Self.maxKeys).enumerated() {
            bytes[index + 2] = keycode
        }
        return bytes
    }

    public var nanoKVMMessageData: Data {
        Data([0x01] + bootReportBytes)
    }
}

public final class HIDKeyboardReportBuilder {
    private var modifier: UInt8 = 0
    private var pressedKeys: [UInt8] = []

    public init() {}

    public var modifierByte: UInt8 { modifier }

    /// The keys and modifiers currently held. Callers that synthesize a keystroke release it by
    /// emitting this rather than an empty report, so real keys held at the same time survive.
    public var currentReport: HIDKeyboardReport {
        HIDKeyboardReport(modifier: modifier, keycodes: pressedKeys)
    }

    public func keyDown(usage: UInt8) -> HIDKeyboardReport {
        if !pressedKeys.contains(usage), pressedKeys.count < HIDKeyboardReport.maxKeys {
            pressedKeys.append(usage)
        }
        return currentReport
    }

    public func keyUp(usage: UInt8) -> HIDKeyboardReport {
        pressedKeys.removeAll { $0 == usage }
        return currentReport
    }

    public func modifierChanged(bit: UInt8, isPressed: Bool) -> HIDKeyboardReport {
        if isPressed {
            modifier |= bit
        } else {
            modifier &= ~bit
        }
        return currentReport
    }

    public func reset() -> HIDKeyboardReport {
        modifier = 0
        pressedKeys.removeAll()
        return currentReport
    }

}
