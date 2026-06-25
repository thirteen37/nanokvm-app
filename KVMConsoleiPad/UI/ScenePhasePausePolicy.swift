import SwiftUI

/// What the viewer should do with its stream in response to a scene-phase change.
enum BackgroundPauseAction: Equatable {
    case none
    case pause
    case resume
}

/// Pure decision for pausing/resuming a viewer's KVM stream as its window moves
/// between scene phases. Kept separate from the view so the rule is unit-testable.
///
/// `.inactive` is deliberately ignored: it fires transiently (App Switcher, Control
/// Center, multitasking gestures) and for genuinely side-by-side windows both scenes
/// stay `.active`, so we only pause on a real `.background`.
enum ScenePhasePausePolicy {
    static func action(phase: ScenePhase, sessionIsLive: Bool, isPaused: Bool) -> BackgroundPauseAction {
        switch phase {
        case .background:
            return sessionIsLive ? .pause : .none
        case .active:
            return isPaused ? .resume : .none
        case .inactive:
            return .none
        @unknown default:
            return .none
        }
    }
}
