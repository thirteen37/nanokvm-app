import Combine
import Foundation

public enum FullscreenKeyCaptureMode: Equatable, Sendable {
    case allKeys
    case limited
    case off
}

@MainActor
public final class ViewerViewModel: ObservableObject {
    @Published public var device: Device
    @Published public var state: KVMSessionState = .disconnected
    @Published public var errorMessage: String?
    @Published public var videoSize: CGSize?
    @Published public var isKeyboardCaptureEnabled = true
    @Published public var isMouseCaptureEnabled = true
    @Published public var isScrollInverted = true
    @Published public var passwordPrompt: String?
    @Published public var passwordInput: String = ""
    @Published public var isFullscreen: Bool = false
    @Published public var showFullscreenBanner: Bool = false
    @Published public var fullscreenKeyCaptureMode: FullscreenKeyCaptureMode = .off
    @Published public var hostStatus: KVMHostStatus?

    public var toggleFullscreen: (() -> Void)?
    public let renderCoordinator: SampleBufferRenderCoordinator
    public let zoom = ViewerZoomState()

    private let session: any KVMSession
    private let passwordStore: PasswordStore
    private let onConnected: ((Device.ID) -> Void)?
    private var bannerTask: Task<Void, Never>?
    private var zoomObservers: Set<AnyCancellable> = []

    public init(
        device: Device,
        passwordStore: PasswordStore = KeychainPasswordStore(),
        session injectedSession: (any KVMSession)? = nil,
        onConnected: ((Device.ID) -> Void)? = nil
    ) {
        let renderCoordinator = SampleBufferRenderCoordinator(renderMode: Self.renderMode(for: device.kvmType))
        self.device = device
        self.passwordStore = passwordStore
        self.onConnected = onConnected
        self.renderCoordinator = renderCoordinator
        self.session = injectedSession ?? KVMSessionFactory.make(
            for: device,
            passwordStore: passwordStore,
            renderCoordinator: renderCoordinator
        )
        session.onStateChange = { [weak self] state in
            guard let self else { return }
            self.state = state
            self.errorMessage = state.errorMessage
            if state == .streaming {
                self.onConnected?(self.device.id)
            }
        }
        session.onVideoSize = { [weak self] videoSize in
            guard let self else { return }
            if self.videoSize != videoSize {
                self.videoSize = videoSize
                self.zoom.videoSize = videoSize
            }
        }
        session.onFlush = { [weak self] in
            self?.flushVideo()
        }
        session.onHostStatusChange = { [weak self] status in
            self?.hostStatus = status
        }

        // Forward only scale/center changes — the body uses those to drive VideoRenderView. Other
        // zoom @Published fields (notably the per-mouse-event cursorNormalized) would re-render the
        // viewer and re-run updateUIView/updateNSView on every cursor move; MinimapView observes
        // the zoom directly via @ObservedObject and handles those updates on its own.
        zoom.$scale.dropFirst().map { _ in () }
            .merge(with: zoom.$center.dropFirst().map { _ in () })
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &zoomObservers)

        attemptAutoConnect()
    }

    private static func renderMode(for kvmType: Device.KVMType) -> SampleBufferRenderMode {
        switch kvmType {
        case .appleScreenSharing, .vnc:
            return .directLatestFrame
        case .nanoKVMLite, .nanoKVMUSB, .comet:
            return .sampleBuffer
        }
    }

    public var isStreaming: Bool { session.isStreaming }
    public var powerControl: KVMPowerControl? { session.powerControl }
    public var supportsPowerControl: Bool { device.kvmType == .comet }
    public var supportsHostStatus: Bool { device.kvmType == .comet }

    public func reconnect() {
        guard device.kvmType.requiresPasswordAuthentication else {
            passwordPrompt = nil
            connect(with: "")
            return
        }
        if let savedPassword = savedPassword(), !savedPassword.isEmpty {
            passwordPrompt = nil
            connect(with: savedPassword)
        } else {
            passwordPrompt = ""
            passwordInput = ""
        }
    }

    public func submitPassword() {
        let password = passwordInput
        guard !password.isEmpty else { return }
        passwordPrompt = nil
        connect(with: password)
    }

    public func disconnect() {
        session.disconnect(updateState: true)
    }

    public func handleTripleEscape() {
        isKeyboardCaptureEnabled = false
        isMouseCaptureEnabled = false
        toggleFullscreen?()
    }

    public func presentFullscreenBanner() {
        bannerTask?.cancel()
        showFullscreenBanner = true
        bannerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.showFullscreenBanner = false
            }
        }
    }

    public func clearFullscreenBanner() {
        bannerTask?.cancel()
        bannerTask = nil
        showFullscreenBanner = false
    }

    public func setFullscreenKeyCaptureMode(_ mode: FullscreenKeyCaptureMode) {
        fullscreenKeyCaptureMode = mode
    }

    public func sendKeyboardReport(_ report: HIDKeyboardReport) {
        guard isKeyboardCaptureEnabled else { return }
        session.sendKeyboardReport(report)
    }

    public func sendMouseReport(_ report: HIDMouseAbsoluteReport) {
        guard isMouseCaptureEnabled else { return }
        session.sendMouseReport(report)
    }

    /// Releases input that is still held, bypassing the capture guard on purpose.
    ///
    /// A button or key held when capture is switched off would otherwise stay pressed on the host
    /// forever: every later report — including the release itself — is dropped by the guard above.
    /// Only pass reports that clear held state.
    public func sendInputRelease(mouse report: HIDMouseAbsoluteReport) {
        session.sendMouseReport(report)
    }

    public func sendInputRelease(keyboard report: HIDKeyboardReport) {
        session.sendKeyboardReport(report)
    }

    public func powerOn() {
        performPowerAction { try await $0.powerOn() }
    }

    public func powerOff() {
        performPowerAction { try await $0.powerOff() }
    }

    public func forceOff() {
        performPowerAction { try await $0.forceOff() }
    }

    public func resetPower() {
        performPowerAction { try await $0.reset() }
    }

    public func longPressPower() {
        performPowerAction { try await $0.longPressPower() }
    }

    private func attemptAutoConnect() {
        guard device.kvmType.requiresPasswordAuthentication else {
            connect(with: "")
            return
        }
        if let savedPassword = savedPassword(), !savedPassword.isEmpty {
            connect(with: savedPassword)
        } else {
            passwordPrompt = ""
        }
    }

    private func connect(with password: String) {
        session.connect(KVMSessionConfiguration(
            device: device,
            password: password,
            passwordAccount: keychainAccount()
        ))
    }

    private func savedPassword() -> String? {
        do {
            return try passwordStore.password(for: keychainAccount())
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    private func keychainAccount() -> String {
        KeychainPasswordAccount(
            scheme: device.scheme,
            host: device.host,
            port: device.port,
            username: device.username
        ).rawValue
    }

    private func flushVideo() {
        renderCoordinator.flush()
        videoSize = nil
        zoom.videoSize = nil
        zoom.cursorNormalized = nil
        zoom.reset()
    }

    private func performPowerAction(_ action: @escaping @Sendable (KVMPowerControl) async throws -> Void) {
        guard let powerControl else { return }
        Task {
            do {
                try await action(powerControl)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
