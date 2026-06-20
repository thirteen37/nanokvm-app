import CoreGraphics
@preconcurrency import CoreMedia
@preconcurrency import CoreVideo
import Foundation

@MainActor
public final class NanoKVMSession: KVMSession {
    public var onStateChange: ((KVMSessionState) -> Void)?
    public var onVideoSize: ((CGSize?) -> Void)?
    public var onFlush: (() -> Void)?
    public var onHostStatusChange: ((KVMHostStatus?) -> Void)?

    public private(set) var state: KVMSessionState = .disconnected {
        didSet {
            onStateChange?(state)
        }
    }

    private var client: NanoKVMClient?
    private var videoSocket: H264StreamSocket?
    private var controlSocket: ControlSocket?
    private var mouseMoveCoalescer: MouseMoveCoalescer?
    private var decoder: H264Decoder?
    private var streamTask: Task<Void, Never>?
    private var generation: Int = 0
    private let passwordStore: PasswordStore
    private let renderCoordinator: SampleBufferRenderCoordinator

    /// The device's video streamer restarts when `selectH264()` switches it out of its current
    /// format; the stream we open immediately after can catch that restart and throw. Retry the
    /// post-login setup a bounded number of times before surfacing an error.
    private static let maxConnectAttempts = 3
    private static let connectRetryBackoff: Duration = .milliseconds(750)
    /// Bounds each attempt's `.connecting` state: if the opened stream accepts the socket but never
    /// delivers a frame (a stalled streamer), the attempt fails and retries rather than hanging.
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

    public var powerControl: KVMPowerControl? { nil }

    public var hostStatus: KVMHostStatus? { nil }

    public func connect(_ configuration: KVMSessionConfiguration) {
        disconnect(updateState: false)
        generation &+= 1
        let myGeneration = generation
        state = .connecting

        let client = NanoKVMClient(device: configuration.device)
        let decoder = H264Decoder { [renderCoordinator] sampleBuffer in
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
                try Task.checkCancellation()
                try? self?.passwordStore.savePassword(configuration.password, for: configuration.passwordAccount)

                guard let token = await client.token else {
                    throw NanoKVMError.missingToken
                }

                var attempt = 0
                while true {
                    if attempt > 0 {
                        // Task.sleep throws on cancel, routing to the outer catch's cancellation path.
                        try await Task.sleep(for: Self.connectRetryBackoff)
                    }
                    try Task.checkCancellation()
                    attempt += 1

                    var localControlSocket: ControlSocket?
                    var localVideoSocket: H264StreamSocket?
                    var handedOff = false
                    do {
                        try await client.selectH264()
                        try Task.checkCancellation()

                        let controlSocket = ControlSocket(device: configuration.device, token: token)
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

                        let videoSocket = H264StreamSocket(device: configuration.device, token: token)
                        var frameIterator = try videoSocket
                            .frames(firstFrameTimeout: Self.connectFirstFrameTimeout)
                            .makeAsyncIterator()
                        localVideoSocket = videoSocket

                        // Await the first frame *before* handing off to .streaming. selectH264()
                        // restarts the device's streamer, so the freshly-opened stream fails on its
                        // first receive() — and because frames()/connect() only resume() and return,
                        // that failure can surface nowhere else. Pulling it inside the attempt is what
                        // lets the bounded retry actually absorb the restart race; it also defers
                        // "Streaming" until real video is flowing. A stalled streamer trips the
                        // socket's first-frame timeout, which throws here and routes into the retry.
                        guard let firstFrame = try await frameIterator.next() else {
                            // nil with no thrown error means the stream finished without a frame.
                            // Distinguish a genuine zero-frame close (retryable) from cancellation.
                            try Task.checkCancellation()
                            throw H264StreamError.streamEndedBeforeFirstFrame
                        }
                        try Task.checkCancellation()

                        // The retry loop doesn't otherwise observe control-socket failures, so a drop
                        // during this connecting window would be missed (onDisconnect only acts once
                        // streaming). Catch it here so a dead control socket retries instead of handing
                        // off to live video with silently broken keyboard/mouse.
                        guard await controlSocket.isOpen else {
                            throw ControlSocketError.disconnectedBeforeStreaming
                        }

                        handedOff = await MainActor.run { () -> Bool in
                            guard let self, self.generation == myGeneration, self.state == .connecting else { return false }
                            self.controlSocket = controlSocket
                            self.mouseMoveCoalescer = mouseMoveCoalescer
                            self.videoSocket = videoSocket
                            self.state = .streaming
                            return true
                        }

                        guard handedOff else {
                            // Superseded by a newer connect/disconnect — orderly teardown, no retry.
                            videoSocket.cancel()
                            await controlSocket.close()
                            return
                        }

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
                        // Pre-handoff failure: tear down this attempt's sockets.
                        localVideoSocket?.cancel()
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
                        KVMLog.nanokvm.info("NanoKVM connect attempt \(attempt, privacy: .public) failed: \(error.localizedDescription, privacy: .public) — retrying")
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
        clearResources(cancelTask: false)
        state = .error(error.localizedDescription)
        onFlush?()
    }

    private func clearResources(cancelTask: Bool) {
        if cancelTask {
            streamTask?.cancel()
        }
        streamTask = nil
        videoSocket?.cancel()
        videoSocket = nil

        let controlSocket = controlSocket
        self.controlSocket = nil
        let mouseMoveCoalescer = mouseMoveCoalescer
        self.mouseMoveCoalescer = nil
        Task {
            await mouseMoveCoalescer?.cancel()
            await controlSocket?.close()
        }

        decoder?.invalidate()
        decoder = nil
        client = nil
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
