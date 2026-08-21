import CoreGraphics
@testable import KVMCore
import XCTest

/// `sendMouseReport` / `sendKeyboardReport` drop everything once capture is switched off. That is
/// right for ordinary input and wrong for a release: a button or key held at that moment would stay
/// pressed on the host forever. `sendInputRelease` is the deliberate bypass — these tests pin both
/// halves of that behaviour.
@MainActor
final class ViewerViewModelInputReleaseTests: XCTestCase {
    func test_mouseReportIsDroppedWhileCaptureIsDisabled() {
        let session = MockKVMSession()
        let model = makeModel(session: session)

        model.isMouseCaptureEnabled = false
        model.sendMouseReport(HIDMouseAbsoluteReport(buttons: 0x01, x: 10, y: 20))

        XCTAssertTrue(session.mouseReports.isEmpty)
    }

    func test_mouseReleaseReachesTheSessionWhileCaptureIsDisabled() {
        let session = MockKVMSession()
        let model = makeModel(session: session)

        model.isMouseCaptureEnabled = false
        model.sendInputRelease(mouse: HIDMouseAbsoluteReport(buttons: 0, x: 10, y: 20))

        XCTAssertEqual(session.mouseReports.count, 1)
        XCTAssertEqual(session.mouseReports.first?.buttons, 0)
    }

    func test_keyboardReportIsDroppedWhileCaptureIsDisabled() {
        let session = MockKVMSession()
        let model = makeModel(session: session)

        model.isKeyboardCaptureEnabled = false
        model.sendKeyboardReport(HIDKeyboardReport(keycodes: [0x04]))

        XCTAssertTrue(session.keyboardReports.isEmpty)
    }

    func test_keyboardReleaseReachesTheSessionWhileCaptureIsDisabled() {
        let session = MockKVMSession()
        let model = makeModel(session: session)

        model.isKeyboardCaptureEnabled = false
        model.sendInputRelease(keyboard: HIDKeyboardReport(keycodes: []))

        XCTAssertEqual(session.keyboardReports.count, 1)
        XCTAssertEqual(session.keyboardReports.first?.keycodes, [])
    }

    private func makeModel(session: MockKVMSession) -> ViewerViewModel {
        // nanoKVMUSB is the one type that needs no password, so construction doesn't reach the
        // keychain or stall on a password prompt.
        ViewerViewModel(
            device: Device(name: "Test", host: "127.0.0.1", kvmType: .nanoKVMUSB),
            passwordStore: StubPasswordStore(),
            session: session
        )
    }
}

@MainActor
private final class MockKVMSession: KVMSession {
    var onStateChange: ((KVMSessionState) -> Void)?
    var onVideoSize: ((CGSize?) -> Void)?
    var onFlush: (() -> Void)?
    var onHostStatusChange: ((KVMHostStatus?) -> Void)?
    var state: KVMSessionState = .disconnected
    var isStreaming = false
    var powerControl: KVMPowerControl?
    var hostStatus: KVMHostStatus?

    private(set) var mouseReports: [HIDMouseAbsoluteReport] = []
    private(set) var keyboardReports: [HIDKeyboardReport] = []

    func connect(_ configuration: KVMSessionConfiguration) {}
    func disconnect(updateState: Bool) {}

    func sendKeyboardReport(_ report: HIDKeyboardReport) {
        keyboardReports.append(report)
    }

    func sendMouseReport(_ report: HIDMouseAbsoluteReport) {
        mouseReports.append(report)
    }
}

private struct StubPasswordStore: PasswordStore {
    func password(for account: String) throws -> String? { nil }
    func savePassword(_ password: String, for account: String) throws {}
    func deletePassword(for account: String) throws {}
}
