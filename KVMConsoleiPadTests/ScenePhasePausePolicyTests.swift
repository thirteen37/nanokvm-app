@testable import KVMConsoleiPad
import SwiftUI
import XCTest

final class ScenePhasePausePolicyTests: XCTestCase {
    func test_backgroundWithLiveSessionPauses() {
        XCTAssertEqual(
            ScenePhasePausePolicy.action(phase: .background, sessionIsLive: true, isPaused: false),
            .pause
        )
    }

    func test_backgroundWithIdleSessionDoesNothing() {
        XCTAssertEqual(
            ScenePhasePausePolicy.action(phase: .background, sessionIsLive: false, isPaused: false),
            .none
        )
    }

    func test_activeWhilePausedResumes() {
        XCTAssertEqual(
            ScenePhasePausePolicy.action(phase: .active, sessionIsLive: false, isPaused: true),
            .resume
        )
    }

    func test_activeWhenNotPausedDoesNothing() {
        XCTAssertEqual(
            ScenePhasePausePolicy.action(phase: .active, sessionIsLive: true, isPaused: false),
            .none
        )
    }

    func test_inactiveIsIgnored() {
        XCTAssertEqual(
            ScenePhasePausePolicy.action(phase: .inactive, sessionIsLive: true, isPaused: false),
            .none
        )
        XCTAssertEqual(
            ScenePhasePausePolicy.action(phase: .inactive, sessionIsLive: false, isPaused: true),
            .none
        )
    }
}
