#if os(macOS)
@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
@preconcurrency import CoreVideo
import Foundation

public enum UVCCaptureError: Error, LocalizedError {
    case cameraAccessDenied
    case deviceNotFound(uniqueID: String)
    case cannotAddInput
    case cannotAddOutput
    case sessionRuntimeError(Error)

    public var errorDescription: String? {
        switch self {
        case .cameraAccessDenied:
            return "Camera access is denied. Grant KVM Console camera access in System Settings → Privacy & Security → Camera, then reconnect."
        case .deviceNotFound(let id):
            return "Could not find USB video capture device (uniqueID=\(id)). It may have been "
                + "unplugged, or more than one identical capture stick is attached — "
                + "re-select it in Edit Device."
        case .cannotAddInput:
            return "AVCaptureSession refused the USB video device as an input."
        case .cannotAddOutput:
            return "AVCaptureSession refused the sample-buffer output."
        case .sessionRuntimeError(let error):
            return "Video capture failed: \(error.localizedDescription)"
        }
    }
}

/// Wraps an `AVCaptureSession` to drive a UVC composite (e.g. Sipeed NanoKVM-USB).
/// Sample buffers are forwarded directly into the shared `SampleBufferRenderCoordinator`
/// — UVC frames are already decoded, so there's no H.264 step.
@MainActor
public final class UVCCaptureSource: NSObject {
    public typealias VideoSizeHandler = @MainActor (CGSize?) -> Void
    public typealias ErrorHandler = @MainActor (Error) -> Void

    private nonisolated let renderCoordinator: SampleBufferRenderCoordinator
    private nonisolated let sampleQueue = DispatchQueue(
        label: "io.lyx.KVMConsole.UVCCaptureSource.samples",
        qos: .userInitiated
    )
    private let session = AVCaptureSession()
    private var device: AVCaptureDevice?
    private var input: AVCaptureDeviceInput?
    private var output: AVCaptureVideoDataOutput?
    private var observers: [NSObjectProtocol] = []

    public var onVideoSize: VideoSizeHandler?
    public var onRuntimeError: ErrorHandler?

    public private(set) var videoSize: CGSize?

    /// Ensures the app has camera access before capture begins. Returns `true` if
    /// authorized (prompting the user on first run when status is `.notDetermined`),
    /// `false` if denied or restricted — in which case `startRunning()` would silently
    /// produce no frames and post no runtime error.
    public static func ensureAuthorized() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    public init(renderCoordinator: SampleBufferRenderCoordinator) {
        self.renderCoordinator = renderCoordinator
    }

    public func start(deviceUniqueID: String) async throws {
        guard let device = AVCaptureDevice(uniqueID: deviceUniqueID) else {
            throw UVCCaptureError.deviceNotFound(uniqueID: deviceUniqueID)
        }

        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.setSampleBufferDelegate(self, queue: sampleQueue)

        // Register for runtime errors before startRunning() so a failure during
        // device spin-up isn't missed.
        installObservers()

        // AVCaptureSession configuration and startRunning() are blocking calls that can
        // take hundreds of milliseconds with an external UVC stick. Run them off the main
        // actor (on sampleQueue) so the UI isn't frozen while the device spins up.
        let session = self.session
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                sampleQueue.async {
                    session.beginConfiguration()
                    if session.canSetSessionPreset(.high) {
                        session.sessionPreset = .high
                    }
                    guard session.canAddInput(input) else {
                        session.commitConfiguration()
                        continuation.resume(throwing: UVCCaptureError.cannotAddInput)
                        return
                    }
                    session.addInput(input)
                    guard session.canAddOutput(output) else {
                        session.commitConfiguration()
                        continuation.resume(throwing: UVCCaptureError.cannotAddOutput)
                        return
                    }
                    session.addOutput(output)
                    session.commitConfiguration()
                    session.startRunning()
                    continuation.resume()
                }
            }
        } catch {
            // Nothing was successfully added to the session; just drop the observers.
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
            observers.removeAll()
            throw error
        }

        self.device = device
        self.input = input
        self.output = output
    }

    public func stop() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()

        // Hand the session off and clear our references synchronously so the source is
        // immediately considered stopped, then run the blocking stopRunning()/reconfigure
        // off the main actor (on sampleQueue) — stopRunning() can block for hundreds of ms
        // with an external UVC stick, just like startRunning().
        let session = self.session
        let input = self.input
        let output = self.output
        device = nil
        self.input = nil
        self.output = nil
        videoSize = nil

        sampleQueue.async {
            if session.isRunning {
                session.stopRunning()
            }
            session.beginConfiguration()
            if let input { session.removeInput(input) }
            if let output { session.removeOutput(output) }
            session.commitConfiguration()
        }
    }

    private func installObservers() {
        let runtimeError = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? Error
                ?? NSError(domain: AVFoundationErrorDomain, code: -1)
            MainActor.assumeIsolated {
                self?.onRuntimeError?(UVCCaptureError.sessionRuntimeError(error))
            }
        }
        observers.append(runtimeError)
    }

    fileprivate func updateVideoSize(_ size: CGSize?) {
        guard videoSize != size else { return }
        videoSize = size
        onVideoSize?(size)
    }

    nonisolated fileprivate static func videoSize(from sampleBuffer: CMSampleBuffer) -> CGSize? {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        return CGSize(
            width: CVPixelBufferGetWidth(imageBuffer),
            height: CVPixelBufferGetHeight(imageBuffer)
        )
    }
}

extension UVCCaptureSource: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        renderCoordinator.enqueue(sampleBuffer)

        let size = Self.videoSize(from: sampleBuffer)
        Task { @MainActor [weak self] in
            self?.updateVideoSize(size)
        }
    }
}
#endif
