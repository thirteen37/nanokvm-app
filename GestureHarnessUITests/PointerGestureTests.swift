import XCTest

/// Real multi-touch against the real recognizers. Unit tests can assert how `PointerCaptureUIView`
/// is *configured*, but not which recognizer wins when several want the same touches — and that
/// arbitration is what broke the two-finger right click in 1.0.6.
final class PointerGestureTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    func test_oneFingerTapSendsThePrimaryButton() {
        let surface = app.otherElements["pointerCapture"]
        XCTAssertTrue(surface.waitForExistence(timeout: 10))

        surface.tap()

        XCTAssertTrue(waitForState(containing: "presses=[1]"), "one-finger tap should press the left button, got \(stateText)")
    }

    func test_twoFingerTapSendsTheSecondaryButton() {
        let surface = app.otherElements["pointerCapture"]
        XCTAssertTrue(surface.waitForExistence(timeout: 10))

        surface.tap(withNumberOfTaps: 1, numberOfTouches: 2)

        XCTAssertTrue(
            waitForState(containing: "presses=[2]"),
            "two-finger tap should press the right button, got \(stateText)"
        )
    }

    func test_pinchZoomsWithoutSendingAClick() {
        let surface = app.otherElements["pointerCapture"]
        XCTAssertTrue(surface.waitForExistence(timeout: 10))

        surface.pinch(withScale: 3, velocity: 3)

        XCTAssertTrue(waitForState(satisfying: { !$0.contains("scale=1.00") }), "pinch should zoom, got \(stateText)")
        XCTAssertTrue(
            stateText.contains("presses=[]"),
            "a pinch must not also fire a click, got \(stateText)"
        )
    }

    private var stateText: String {
        app.staticTexts["state"].label
    }

    private func waitForState(containing needle: String) -> Bool {
        waitForState(satisfying: { $0.contains(needle) })
    }

    private func waitForState(satisfying predicate: @escaping (String) -> Bool) -> Bool {
        let element = app.staticTexts["state"]
        let matches = NSPredicate { object, _ in
            guard let element = object as? XCUIElement else { return false }
            return predicate(element.label)
        }
        let expectation = XCTNSPredicateExpectation(predicate: matches, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: 5) == .completed
    }
}
