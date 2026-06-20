import CoreGraphics
@preconcurrency import CoreMedia
@preconcurrency import CoreVideo
import Foundation

@MainActor
public final class GLKVMSession: KVMSession {
    public var onStateChange: ((KVMSessionState) -> Void)?
    public var onVideoSize: ((CGSize?) -> Void)?
    public var onFlush: (() -> Void)?
    public var onHostStatusChange: ((KVMHostStatus?) -> Void)?

    public private(set) var state: KVMSessionState = .disconnected {
        didSet {
            onStateChange?(state)
        }
    }

    public private(set) var hostStatus: KVMHostStatus? {
        didSet {
            guard hostStatus != oldValue else { return }
            onHostStatusChange?(hostStatus)
        }
    }

    private var client: GLKVMClient?
    private var controlSocket: GLKVMControlSocket?
    private var mouseMoveCoalescer: MouseMoveCoalescer?
    private var mediaSocket: GLKVMH264MediaSocket?
    private var decoder: H264Decoder?
    private var streamTask: Task<Void, Never>?
    private var generation: Int = 0
    private let passwordStore: PasswordStore
    private let renderCoordinator: SampleBufferRenderCoordinator

    public init(
        passwordStore: PasswordStore = KeychainPasswordStore(),
        renderCoordinator: SampleBufferRenderCoordinator = SampleBufferRenderCoordinator()
    ) {
        self.passwordStore = passwordStore
        self.renderCoordinator = renderCoordinator
    }

    public var isStreaming: Bool {
        streamTask != nil
    }

    public var powerControl: KVMPowerControl? {
        client
    }

    public func connect(_ configuration: KVMSessionConfiguration) {
        disconnect(updateState: false)
        generation &+= 1
        let myGeneration = generation
        state = .connecting
        KVMLog.glkvm.info("Connecting GLKVM session to \(configuration.device.host, privacy: .public):\(configuration.device.port, privacy: .public)")

        let client = GLKVMClient(device: configuration.device)
        let decoder = H264Decoder(colorOverride: .glkvm) { [renderCoordinator] sampleBuffer in
            renderCoordinator.enqueue(sampleBuffer)
            let videoSize = Self.videoSize(from: sampleBuffer)
            Task { @MainActor [weak self] in
                guard let self, self.generation == myGeneration else { return }
                self.onVideoSize?(videoSize)
            }
        }
        self.client = client
        self.decoder = decoder

        streamTask = Task { [weak self] in
            var localControlSocket: GLKVMControlSocket?
            var localMouseMoveCoalescer: MouseMoveCoalescer?
            var localMediaSocket: GLKVMH264MediaSocket?
            var handedOff = false
            do {
                try await client.login(password: configuration.password)
                KVMLog.glkvm.info("GLKVM login succeeded")
                try Task.checkCancellation()
                try? self?.passwordStore.savePassword(configuration.password, for: configuration.passwordAccount)

                guard let authToken = await client.authToken else {
                    throw GLKVMError.missingAuthToken
                }

                try await client.setStreamerVideoFormatH264()
                KVMLog.glkvm.info("GLKVM streamer video format set to H.264")

                let controlSocket = GLKVMControlSocket(device: configuration.device, authToken: authToken)
                await controlSocket.setOnDisconnect { [weak self] error in
                    Task { @MainActor in
                        guard let self, self.generation == myGeneration else { return }
                        guard self.state == .connecting || self.state == .streaming else { return }
                        self.finishWithError(error)
                    }
                }
                await controlSocket.setOnHostStatusUpdate { [weak self] status in
                    Task { @MainActor in
                        guard let self, self.generation == myGeneration else { return }
                        self.hostStatus = status
                    }
                }
                try await controlSocket.connect()
                localControlSocket = controlSocket
                let mouseMoveCoalescer = MouseMoveCoalescer { report in
                    await controlSocket.sendMouseAbsoluteReport(report)
                }
                localMouseMoveCoalescer = mouseMoveCoalescer

                await MainActor.run {
                    guard let self, self.generation == myGeneration, self.state == .connecting else { return }
                    self.controlSocket = controlSocket
                    self.mouseMoveCoalescer = mouseMoveCoalescer
                }
                KVMLog.glkvm.info("GLKVM control socket is ready")

                let mediaSocket = GLKVMH264MediaSocket(device: configuration.device, authToken: authToken)
                let frames = try mediaSocket.frames()
                localMediaSocket = mediaSocket

                handedOff = await MainActor.run { () -> Bool in
                    guard let self, self.generation == myGeneration, self.state == .connecting else { return false }
                    self.mediaSocket = mediaSocket
                    self.state = .streaming
                    return true
                }
                KVMLog.glkvm.info("GLKVM direct H.264 pipeline started")

                guard handedOff else {
                    mediaSocket.cancel()
                    await mouseMoveCoalescer.cancel()
                    await controlSocket.close()
                    return
                }

                for try await frame in frames {
                    try Task.checkCancellation()
                    try decoder.decode(frame)
                }

                await MainActor.run {
                    guard let self, self.generation == myGeneration else { return }
                    self.finishDisconnected()
                }
            } catch {
                if !handedOff {
                    localMediaSocket?.cancel()
                }
                if let socket = localControlSocket, !handedOff {
                    await socket.close()
                }
                if let coalescer = localMouseMoveCoalescer, !handedOff {
                    await coalescer.cancel()
                }
                let isCancellation = (error is CancellationError)
                    || (error as? URLError)?.code == .cancelled
                await MainActor.run {
                    guard let self, self.generation == myGeneration else { return }
                    if isCancellation {
                        self.clearResources(cancelTask: false)
                    } else {
                        self.finishWithError(error)
                    }
                }
            }
        }
    }

    public func disconnect(updateState: Bool = true) {
        KVMLog.glkvm.info("Disconnecting GLKVM session; updateState=\(updateState, privacy: .public)")
        clearResources(cancelTask: true)
        if updateState {
            state = .disconnected
        }
        onFlush?()
    }

    public func sendKeyboardReport(_ report: HIDKeyboardReport) {
        guard let controlSocket else { return }
        Task(priority: .userInitiated) {
            await controlSocket.sendKeyboardReport(report)
        }
    }

    public func sendMouseReport(_ report: HIDMouseAbsoluteReport) {
        guard let mouseMoveCoalescer else { return }
        Task(priority: .userInitiated) {
            await mouseMoveCoalescer.enqueue(report)
        }
    }

    private func finishDisconnected() {
        clearResources(cancelTask: false)
        state = .disconnected
        onFlush?()
    }

    private func finishWithError(_ error: Error) {
        KVMLog.glkvm.error("GLKVM session failed: \(error.localizedDescription, privacy: .public)")
        clearResources(cancelTask: false)
        state = .error(error.localizedDescription)
        onFlush?()
    }

    private func clearResources(cancelTask: Bool) {
        if cancelTask {
            streamTask?.cancel()
        }
        streamTask = nil
        hostStatus = nil
        mediaSocket?.cancel()
        mediaSocket = nil

        let controlSocket = controlSocket
        self.controlSocket = nil
        let mouseMoveCoalescer = mouseMoveCoalescer
        self.mouseMoveCoalescer = nil
        let client = client
        self.client = nil
        Task {
            await mouseMoveCoalescer?.cancel()
            await controlSocket?.close()
            await client?.close()
        }

        decoder?.invalidate()
        decoder = nil
    }

    nonisolated private static func videoSize(from sampleBuffer: CMSampleBuffer) -> CGSize? {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return nil
        }
        return CGSize(
            width: CVPixelBufferGetWidth(imageBuffer),
            height: CVPixelBufferGetHeight(imageBuffer)
        )
    }
}
