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

    /// `setStreamerVideoFormatH264()` restarts the device's streamer when it switches format; the
    /// media stream we open immediately after can catch that restart and throw. Retry the post-login
    /// setup a bounded number of times before surfacing an error.
    private static let maxConnectAttempts = 3
    private static let connectRetryBackoff: Duration = .milliseconds(750)
    /// Bounds each attempt's `.connecting` state: if the media stream accepts the socket but never
    /// delivers a frame (a stalled streamer, kept alive by the socket's 1s heartbeats), the attempt
    /// fails and retries rather than hanging.
    private static let connectFirstFrameTimeout: Duration = .seconds(5)

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
            do {
                // Login + password save stay outside the retry scope so an auth failure surfaces
                // immediately (keeping the password-prompt path unchanged).
                try await client.login(password: configuration.password)
                KVMLog.glkvm.info("GLKVM login succeeded")
                try Task.checkCancellation()
                try? self?.passwordStore.savePassword(configuration.password, for: configuration.passwordAccount)

                guard let authToken = await client.authToken else {
                    throw GLKVMError.missingAuthToken
                }

                var attempt = 0
                while true {
                    if attempt > 0 {
                        // Task.sleep throws on cancel, routing to the outer catch's cancellation path.
                        try await Task.sleep(for: Self.connectRetryBackoff)
                    }
                    try Task.checkCancellation()
                    attempt += 1

                    var localControlSocket: GLKVMControlSocket?
                    var localMouseMoveCoalescer: MouseMoveCoalescer?
                    var localMediaSocket: GLKVMH264MediaSocket?
                    var handedOff = false
                    do {
                        try await client.setStreamerVideoFormatH264()
                        KVMLog.glkvm.info("GLKVM streamer video format set to H.264 (attempt \(attempt, privacy: .public))")

                        let controlSocket = GLKVMControlSocket(device: configuration.device, authToken: authToken)
                        // Host-status updates are harmless while connecting, so arm them before connect().
                        await controlSocket.setOnHostStatusUpdate { [weak self] status in
                            Task { @MainActor in
                                guard let self, self.generation == myGeneration else { return }
                                self.hostStatus = status
                            }
                        }
                        try await controlSocket.connect()
                        localControlSocket = controlSocket
                        // Arm onDisconnect right after connect() so a post-connect drop is never
                        // missed, but only act once streaming: while connecting (including retries)
                        // the retry loop is the sole failure handler, so the callback no-ops and
                        // can't race us to .error.
                        await controlSocket.setOnDisconnect { [weak self] error in
                            Task { @MainActor in
                                guard let self, self.generation == myGeneration else { return }
                                guard self.state == .streaming else { return }
                                self.finishWithError(error)
                            }
                        }
                        let mouseMoveCoalescer = MouseMoveCoalescer { report in
                            await controlSocket.sendMouseAbsoluteReport(report)
                        }
                        localMouseMoveCoalescer = mouseMoveCoalescer

                        let mediaSocket = GLKVMH264MediaSocket(device: configuration.device, authToken: authToken)
                        var frameIterator = try mediaSocket
                            .frames(firstFrameTimeout: Self.connectFirstFrameTimeout)
                            .makeAsyncIterator()
                        localMediaSocket = mediaSocket

                        // Await the first frame *before* handoff — see NanoKVMSession for the full
                        // rationale. setStreamerVideoFormatH264() restarts the streamer, so the media
                        // stream fails on its first receive(), which surfaces only here; awaiting it
                        // inside the attempt is what lets the bounded retry absorb the restart race.
                        // A stalled streamer trips the socket's first-frame timeout, which routes here.
                        guard let firstFrame = try await frameIterator.next() else {
                            try Task.checkCancellation()
                            throw GLKVMH264MediaError.streamEndedBeforeFirstFrame
                        }
                        try Task.checkCancellation()

                        // The retry loop doesn't otherwise observe control-socket failures, so catch a
                        // drop during this connecting window here (onDisconnect only acts once
                        // streaming) — otherwise we'd hand off to live video with dead keyboard/mouse.
                        guard await controlSocket.isOpen else {
                            throw GLKVMControlSocketError.disconnectedBeforeStreaming
                        }

                        // Single-phase handoff: assign control socket, coalescer, and media socket
                        // together so each attempt is atomic and never leaks a socket into self.
                        handedOff = await MainActor.run { () -> Bool in
                            guard let self, self.generation == myGeneration, self.state == .connecting else { return false }
                            self.controlSocket = controlSocket
                            self.mouseMoveCoalescer = mouseMoveCoalescer
                            self.mediaSocket = mediaSocket
                            self.state = .streaming
                            return true
                        }

                        guard handedOff else {
                            // Superseded by a newer connect/disconnect — orderly teardown, no retry.
                            mediaSocket.cancel()
                            await mouseMoveCoalescer.cancel()
                            await controlSocket.close()
                            return
                        }

                        KVMLog.glkvm.info("GLKVM direct H.264 pipeline started")

                        // Streaming is live — the frame loop is now terminal (no retry mid-stream).
                        do {
                            try decoder.decode(firstFrame)
                            while let frame = try await frameIterator.next() {
                                try Task.checkCancellation()
                                try decoder.decode(frame)
                            }
                            await MainActor.run {
                                guard let self, self.generation == myGeneration else { return }
                                self.finishDisconnected()
                            }
                        } catch {
                            let isCancellation = isCancellationError(error)
                            await MainActor.run {
                                guard let self, self.generation == myGeneration else { return }
                                if isCancellation {
                                    self.clearResources(cancelTask: false)
                                } else {
                                    self.finishWithError(error)
                                }
                            }
                        }
                        return
                    } catch {
                        // Pre-handoff failure: tear down this attempt's sockets. The client holds the
                        // auth token and is reused across attempts, so it is deliberately left open.
                        localMediaSocket?.cancel()
                        if let coalescer = localMouseMoveCoalescer {
                            await coalescer.cancel()
                        }
                        if let socket = localControlSocket {
                            await socket.close()
                        }
                        if isCancellationError(error) {
                            await MainActor.run {
                                guard let self, self.generation == myGeneration else { return }
                                self.clearResources(cancelTask: false)
                            }
                            return
                        }
                        if attempt >= Self.maxConnectAttempts {
                            await MainActor.run {
                                guard let self, self.generation == myGeneration else { return }
                                self.finishWithError(error)
                            }
                            return
                        }
                        KVMLog.glkvm.info("GLKVM connect attempt \(attempt, privacy: .public) failed: \(error.localizedDescription, privacy: .public) — retrying")
                    }
                }
            } catch {
                let isCancellation = isCancellationError(error)
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
