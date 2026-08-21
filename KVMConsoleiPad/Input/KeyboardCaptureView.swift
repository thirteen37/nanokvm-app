import KVMCore
import SwiftUI
import UIKit

struct VirtualKeyTap: Equatable {
    let id: UUID
    let usage: UInt8
    let transientModifier: UInt8
}

struct KeyboardCaptureView: UIViewRepresentable {
    let isEnabled: Bool
    let keyboardFocusToken: Int
    let extraModifierByte: UInt8
    let pendingVirtualKey: VirtualKeyTap?
    let onKeyboardReport: @MainActor (HIDKeyboardReport) -> Void
    let onMomentaryModifiersConsumed: @MainActor () -> Void

    func makeUIView(context: Context) -> KeyboardCaptureUIView {
        let view = KeyboardCaptureUIView()
        view.onKeyboardReport = onKeyboardReport
        view.onMomentaryModifiersConsumed = onMomentaryModifiersConsumed
        view.isCaptureEnabled = isEnabled
        view.extraModifierByte = extraModifierByte
        return view
    }

    func updateUIView(_ uiView: KeyboardCaptureUIView, context: Context) {
        uiView.onKeyboardReport = onKeyboardReport
        uiView.onMomentaryModifiersConsumed = onMomentaryModifiersConsumed
        uiView.isCaptureEnabled = isEnabled
        uiView.extraModifierByte = extraModifierByte
        if context.coordinator.lastKeyboardFocusToken != keyboardFocusToken {
            context.coordinator.lastKeyboardFocusToken = keyboardFocusToken
            uiView.becomeFirstResponder()
        } else if isEnabled, !uiView.isFirstResponder {
            uiView.becomeFirstResponder()
        }
        if let pending = pendingVirtualKey, context.coordinator.lastVirtualKeyID != pending.id {
            context.coordinator.lastVirtualKeyID = pending.id
            uiView.sendVirtualKey(usage: pending.usage, transientModifier: pending.transientModifier)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var lastKeyboardFocusToken = 0
        var lastVirtualKeyID: UUID?
    }
}

final class KeyboardCaptureUIView: UIView, UIKeyInput {
    var isCaptureEnabled = false
    var extraModifierByte: UInt8 = 0
    var onKeyboardReport: (@MainActor (HIDKeyboardReport) -> Void)?
    var onMomentaryModifiersConsumed: (@MainActor () -> Void)?

    private let builder = HIDKeyboardReportBuilder()
    private let virtualKeySequencer = SynthesizedTapSequencer()

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { false }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, isCaptureEnabled {
            becomeFirstResponder()
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard isCaptureEnabled else {
            super.pressesBegan(presses, with: event)
            return
        }
        for press in presses {
            guard let usage = press.key?.keyCode.rawValue, let keyUsage = UInt8(exactly: usage) else { continue }
            if let bit = HIDModifierBit.bit(forHIDUsage: keyUsage) {
                emit(builder.modifierChanged(bit: bit, isPressed: true))
            } else {
                emit(withExtraModifiers(builder.keyDown(usage: keyUsage), eventModifiers: press.key?.modifierFlags ?? []))
                consumeMomentary()
            }
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard isCaptureEnabled else {
            super.pressesEnded(presses, with: event)
            return
        }
        for press in presses {
            guard let usage = press.key?.keyCode.rawValue, let keyUsage = UInt8(exactly: usage) else { continue }
            if let bit = HIDModifierBit.bit(forHIDUsage: keyUsage) {
                emit(builder.modifierChanged(bit: bit, isPressed: false))
            } else {
                emit(withExtraModifiers(builder.keyUp(usage: keyUsage), eventModifiers: press.key?.modifierFlags ?? []))
            }
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard isCaptureEnabled else {
            super.pressesCancelled(presses, with: event)
            return
        }
        virtualKeySequencer.flushPendingRelease()
        emit(builder.reset())
        super.pressesCancelled(presses, with: event)
    }

    func insertText(_ text: String) {
        guard isCaptureEnabled else { return }
        for character in text {
            guard let stroke = CharacterHIDMap.stroke(for: character) else { continue }
            sendVirtualKey(usage: stroke.usage, transientModifier: extraModifierByte | stroke.modifier)
            consumeMomentary()
        }
    }

    func deleteBackward() {
        guard isCaptureEnabled else { return }
        sendVirtualKey(usage: 0x2A, transientModifier: extraModifierByte)
        consumeMomentary()
    }

    func sendVirtualKey(usage: UInt8, transientModifier: UInt8) {
        // Combine synthesized modifier bits with whatever real modifiers the builder is
        // currently tracking, then on release drop only the synthesized bits — this keeps a
        // hardware modifier (e.g. held BT-keyboard Shift) asserted on the host and prevents
        // the synthesized one from sticking. The release re-reads the builder rather than
        // capturing it, so a hardware modifier pressed during the hold survives too.
        virtualKeySequencer.tap(
            down: { [weak self] in
                guard let self else { return }
                self.emit(HIDKeyboardReport(
                    modifier: self.builder.modifierByte | transientModifier,
                    keycodes: [usage]
                ))
            },
            up: { [weak self] in
                guard let self else { return }
                self.emit(HIDKeyboardReport(modifier: self.builder.modifierByte, keycodes: []))
            }
        )
    }

    private func withExtraModifiers(_ report: HIDKeyboardReport, eventModifiers: UIKeyModifierFlags) -> HIDKeyboardReport {
        HIDKeyboardReport(
            modifier: report.modifier | extraModifierByte | eventModifiers.hidModifierByte,
            keycodes: report.keycodes
        )
    }

    // UIView press handling runs on the main thread; assuming MainActor
    // isolation here keeps the call site synchronous and avoids the
    // run-loop hop that `Task { @MainActor in ... }` would impose on every
    // keystroke.
    private func emit(_ report: HIDKeyboardReport) {
        guard let onKeyboardReport else { return }
        MainActor.assumeIsolated {
            onKeyboardReport(report)
        }
    }

    private func consumeMomentary() {
        guard let onMomentaryModifiersConsumed else { return }
        MainActor.assumeIsolated {
            onMomentaryModifiersConsumed()
        }
    }
}

extension UIKeyModifierFlags {
    var hidModifierByte: UInt8 {
        var value: UInt8 = 0
        if contains(.control) { value |= HIDModifierBit.leftControl.rawValue }
        if contains(.shift) { value |= HIDModifierBit.leftShift.rawValue }
        if contains(.alternate) { value |= HIDModifierBit.leftAlt.rawValue }
        if contains(.command) { value |= HIDModifierBit.leftGUI.rawValue }
        return value
    }
}

enum CharacterHIDMap {
    static func stroke(for character: Character) -> (usage: UInt8, modifier: UInt8)? {
        if let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 {
            return stroke(for: scalar)
        }
        return nil
    }

    private static func stroke(for scalar: UnicodeScalar) -> (usage: UInt8, modifier: UInt8)? {
        let shift = HIDModifierBit.leftShift.rawValue
        switch scalar.value {
        case 0x0A, 0x0D: return (0x28, 0)
        case 0x09: return (0x2B, 0)
        case 0x20: return (0x2C, 0)
        case 0x61...0x7A:
            return (UInt8(0x04 + scalar.value - 0x61), 0)
        case 0x41...0x5A:
            return (UInt8(0x04 + scalar.value - 0x41), shift)
        case 0x31...0x39:
            return (UInt8(0x1E + scalar.value - 0x31), 0)
        case 0x30:
            return (0x27, 0)
        default:
            return symbolMap[Character(scalar)]
        }
    }

    private static let symbolMap: [Character: (usage: UInt8, modifier: UInt8)] = [
        "-": (0x2D, 0), "_": (0x2D, HIDModifierBit.leftShift.rawValue),
        "=": (0x2E, 0), "+": (0x2E, HIDModifierBit.leftShift.rawValue),
        "[": (0x2F, 0), "{": (0x2F, HIDModifierBit.leftShift.rawValue),
        "]": (0x30, 0), "}": (0x30, HIDModifierBit.leftShift.rawValue),
        "\\": (0x31, 0), "|": (0x31, HIDModifierBit.leftShift.rawValue),
        ";": (0x33, 0), ":": (0x33, HIDModifierBit.leftShift.rawValue),
        "'": (0x34, 0), "\"": (0x34, HIDModifierBit.leftShift.rawValue),
        "`": (0x35, 0), "~": (0x35, HIDModifierBit.leftShift.rawValue),
        ",": (0x36, 0), "<": (0x36, HIDModifierBit.leftShift.rawValue),
        ".": (0x37, 0), ">": (0x37, HIDModifierBit.leftShift.rawValue),
        "/": (0x38, 0), "?": (0x38, HIDModifierBit.leftShift.rawValue),
        "!": (0x1E, HIDModifierBit.leftShift.rawValue),
        "@": (0x1F, HIDModifierBit.leftShift.rawValue),
        "#": (0x20, HIDModifierBit.leftShift.rawValue),
        "$": (0x21, HIDModifierBit.leftShift.rawValue),
        "%": (0x22, HIDModifierBit.leftShift.rawValue),
        "^": (0x23, HIDModifierBit.leftShift.rawValue),
        "&": (0x24, HIDModifierBit.leftShift.rawValue),
        "*": (0x25, HIDModifierBit.leftShift.rawValue),
        "(": (0x26, HIDModifierBit.leftShift.rawValue),
        ")": (0x27, HIDModifierBit.leftShift.rawValue)
    ]
}
