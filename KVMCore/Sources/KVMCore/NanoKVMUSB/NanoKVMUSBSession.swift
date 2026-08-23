#if os(macOS)
import CoreGraphics
import Foundation

private final class WeakSession: @unchecked Sendable {
    weak var value: NanoKVMUSBSession?
    init(value: NanoKVMUSBSession?) { self.value = value }
}

public enum NanoKVMUSBError: Error, LocalizedError {
    case missingVideoDevice
    case missingSerialDevice

    public var errorDescription: String? {
        switch self {
        case .missingVideoDevice:
            return "No USB video device has been selected for this NanoKVM USB."
        case .missingSerialDevice:
            return "No USB serial port has been selected for this NanoKVM USB."
        }
    }
}

@MainActor
public final class NanoKVMUSBSession: KVMSession {
    public var onStateChange: ((KVMSessionState) -> Void)?
    public var onVideoSize: ((CGSize?) -> Void)?
    public var onFlush: (() -> Void)?
    public var onHostStatusChange: ((KVMHostStatus?) -> Void)?

    public private(set) var state: KVMSessionState = .disconnected {
        didSet { onStateChange?(state) }
    }

    public var powerControl: KVMPowerControl? { nil }
    public var hostStatus: KVMHostStatus? { nil }
    public var isStreaming: Bool { state == .streaming }

    private let renderCoordinator: SampleBufferRenderCoordinator
    private var captureSource: UVCCaptureSource?
    private var serialTransport: CH9329SerialTransport?
    private var mouseMoveCoalescer: MouseMoveCoalescer?
    private var generation: Int = 0

    public init(
        passwordStore: PasswordStore = KeychainPasswordStore(),
        renderCoordinator: SampleBufferRenderCoordinator = SampleBufferRenderCoordinator()
    ) {
        // NanoKVM USB has no auth; the password store is accepted for API symmetry but unused.
        _ = passwordStore
        self.renderCoordinator = renderCoordinator
    }

    public func connect(_ configuration: KVMSessionConfiguration) {
        disconnect(updateState: false)
        generation &+= 1
        let myGeneration = generation
        state = .connecting

        guard let savedVideoID = configuration.device.videoDeviceUniqueID, !savedVideoID.isEmpty else {
            finishWithError(NanoKVMUSBError.missingVideoDevice)
            return
        }
        guard let savedSerialPath = configuration.device.serialDevicePath, !savedSerialPath.isEmpty else {
            finishWithError(NanoKVMUSBError.missingSerialDevice)
            return
        }

        // Both saved identifiers encode the USB port the stick was plugged into when it
        // was picked, so moving it to another port invalidates them. Re-resolve against
        // what's attached now before opening anything.
        guard let videoID = USBKVMDeviceDiscovery.resolveVideoUniqueID(saved: savedVideoID) else {
            finishWithError(UVCCaptureError.deviceNotFound(uniqueID: savedVideoID))
            return
        }
        guard let serialPath = USBKVMDeviceDiscovery.resolveSerialPath(
            saved: savedSerialPath,
            videoUniqueID: videoID
        ) else {
            finishWithError(CH9329SerialError.portNotFound(path: savedSerialPath))
            return
        }

        let capture = UVCCaptureSource(renderCoordinator: renderCoordinator)
        capture.onVideoSize = { [weak self] size in
            guard let self, self.generation == myGeneration else { return }
            self.onVideoSize?(size)
        }
        capture.onRuntimeError = { [weak self] error in
            guard let self, self.generation == myGeneration else { return }
            guard self.state == .connecting || self.state == .streaming else { return }
            self.finishWithError(error)
        }

        let transport = CH9329SerialTransport(devicePath: serialPath)
        captureSource = capture
        serialTransport = transport
        mouseMoveCoalescer = MouseMoveCoalescer { [weak transport] report in
            guard let transport else { return }
            let packet = CH9329Protocol.absoluteMousePacket(report)
            do {
                try await transport.send(packet)
            } catch {
                KVMLog.video.error(
                    "CH9329 mouse send failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        Task { [weak self] in
            // Camera authorization must be confirmed before startRunning(): a denied or
            // restricted camera yields no frames and posts no runtime error, which would
            // otherwise leave the viewer black yet marked .streaming once the serial opens.
            guard await UVCCaptureSource.ensureAuthorized() else {
                await MainActor.run {
                    guard let self, self.generation == myGeneration else { return }
                    self.finishWithError(UVCCaptureError.cameraAccessDenied)
                }
                return
            }

            let shouldProceed = await MainActor.run { () -> Bool in
                guard let self, self.generation == myGeneration, self.state == .connecting else { return false }
                return true
            }
            guard shouldProceed else { return }

            do {
                try await capture.start(deviceUniqueID: videoID)
                try await transport.open()
                let weakSelfBox = WeakSession(value: self)
                await transport.setOnDisconnect { error in
                    Task { @MainActor in
                        guard let session = weakSelfBox.value, session.generation == myGeneration else { return }
                        guard session.state == .connecting || session.state == .streaming else { return }
                        session.finishWithError(error ?? CH9329SerialError.closed)
                    }
                }
                let handedOff = await MainActor.run { () -> Bool in
                    guard let self, self.generation == myGeneration, self.state == .connecting else { return false }
                    self.state = .streaming
                    return true
                }
                if !handedOff {
                    // A disconnect/reconnect bumped the generation while startup was in
                    // flight; self.captureSource/serialTransport now point at the new
                    // attempt's objects, so tear down these orphans to free the camera
                    // and the serial fd.
                    await MainActor.run { capture.stop() }
                    await transport.close()
                }
            } catch {
                await MainActor.run { capture.stop() }
                await transport.close()
                await MainActor.run {
                    guard let self, self.generation == myGeneration else { return }
                    self.finishWithError(error)
                }
            }
        }
    }

    public func disconnect(updateState: Bool = true) {
        generation &+= 1
        captureSource?.stop()
        captureSource = nil

        let transport = serialTransport
        serialTransport = nil
        let coalescer = mouseMoveCoalescer
        mouseMoveCoalescer = nil
        Task {
            await coalescer?.cancel()
            await transport?.close()
        }

        if updateState {
            state = .disconnected
        }
        onFlush?()
    }

    public func sendKeyboardReport(_ report: HIDKeyboardReport) {
        guard let transport = serialTransport else { return }
        let packet = CH9329Protocol.keyboardPacket(report)
        Task(priority: .userInitiated) {
            do {
                try await transport.send(packet)
            } catch {
                KVMLog.video.error(
                    "CH9329 keyboard send failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    public func sendMouseReport(_ report: HIDMouseAbsoluteReport) {
        guard let coalescer = mouseMoveCoalescer else { return }
        Task(priority: .userInitiated) {
            await coalescer.enqueue(report)
        }
    }

    private func finishWithError(_ error: Error) {
        captureSource?.stop()
        captureSource = nil

        let transport = serialTransport
        serialTransport = nil
        let coalescer = mouseMoveCoalescer
        mouseMoveCoalescer = nil
        Task {
            await coalescer?.cancel()
            await transport?.close()
        }

        state = .error(error.localizedDescription)
        onFlush?()
    }
}
#endif
