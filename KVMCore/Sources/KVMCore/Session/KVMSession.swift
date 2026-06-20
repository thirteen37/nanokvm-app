import CoreGraphics
import Foundation

public struct KVMSessionConfiguration: Equatable, Sendable {
    public let device: Device
    public let password: String
    public let passwordAccount: String

    public init(device: Device, password: String, passwordAccount: String) {
        self.device = device
        self.password = password
        self.passwordAccount = passwordAccount
    }
}

/// Errors raised when a connection attempt is cancelled (e.g. `disconnect()` or a superseding
/// `connect()`) should not be surfaced as `.error` or retried. Shared by the session retry loops.
nonisolated func isCancellationError(_ error: Error) -> Bool {
    error is CancellationError || (error as? URLError)?.code == .cancelled
}

public enum KVMSessionState: Equatable {
    case disconnected
    case connecting
    case streaming
    case error(String)

    public var displayText: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting..."
        case .streaming: return "Streaming"
        case .error: return "Error"
        }
    }

    public var errorMessage: String? {
        if case .error(let message) = self {
            return message
        }
        return nil
    }
}

public enum ATXPowerState: Equatable, Sendable {
    case on
    case off
}

public struct KVMHostStatus: Equatable, Sendable {
    public var atxPower: ATXPowerState?
    public var hdmiSignal: Bool?

    public init(atxPower: ATXPowerState? = nil, hdmiSignal: Bool? = nil) {
        self.atxPower = atxPower
        self.hdmiSignal = hdmiSignal
    }
}

@MainActor
public protocol KVMSession: AnyObject {
    var onStateChange: ((KVMSessionState) -> Void)? { get set }
    var onVideoSize: ((CGSize?) -> Void)? { get set }
    var onFlush: (() -> Void)? { get set }
    var onHostStatusChange: ((KVMHostStatus?) -> Void)? { get set }
    var state: KVMSessionState { get }
    var isStreaming: Bool { get }
    var powerControl: KVMPowerControl? { get }
    var hostStatus: KVMHostStatus? { get }

    func connect(_ configuration: KVMSessionConfiguration)
    func disconnect(updateState: Bool)
    func sendKeyboardReport(_ report: HIDKeyboardReport)
    func sendMouseReport(_ report: HIDMouseAbsoluteReport)
}
