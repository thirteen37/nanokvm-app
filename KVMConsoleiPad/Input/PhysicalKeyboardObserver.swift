import Combine
import GameController
import SwiftUI

/// Tracks whether a hardware keyboard is currently attached to the device.
///
/// The on-screen modifier-key bar exists so that touch/on-screen-keyboard users
/// can send Ctrl/Alt/Cmd/etc. When a physical keyboard is connected those keys
/// are already available, so the bar is redundant and the viewer hides it.
@MainActor
final class PhysicalKeyboardObserver: ObservableObject {
    @Published private(set) var isConnected: Bool

    private var observers: [NSObjectProtocol] = []

    init() {
        isConnected = GCKeyboard.coalesced != nil

        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .GCKeyboardDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.isConnected = true }
        })
        observers.append(center.addObserver(
            forName: .GCKeyboardDidDisconnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // A disconnect notification can fire while another keyboard is still
            // attached, so re-read the coalesced keyboard rather than assuming none.
            MainActor.assumeIsolated { self?.isConnected = GCKeyboard.coalesced != nil }
        })
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

/// Resolves whether the modifier-key bar should be visible. Kept as a pure
/// function so the precedence rule (hardware keyboard wins over the user toggle)
/// is unit-testable without a live `GCKeyboard`.
enum ModifierBarVisibility {
    static func shouldShow(userEnabled: Bool, physicalKeyboardConnected: Bool) -> Bool {
        userEnabled && !physicalKeyboardConnected
    }
}
