import Foundation

public enum ControlSocketError: Error, LocalizedError, Equatable {
    case invalidURL
    case disconnectedBeforeStreaming

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid control socket URL."
        case .disconnectedBeforeStreaming: return "Control socket disconnected before streaming began."
        }
    }
}

public actor ControlSocket {
    private let device: Device
    private let token: String
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var heartbeatTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var onDisconnect: (@Sendable (Error) -> Void)?

    public init(device: Device, token: String, session: URLSession = .shared) {
        self.device = device
        self.token = token
        self.session = session
    }

    /// `false` once the socket has dropped (its receive loop nils `task` via `close()`), letting the
    /// session detect a control-socket drop during the connecting window before handing off.
    public var isOpen: Bool { task != nil }

    public func setOnDisconnect(_ callback: @escaping @Sendable (Error) -> Void) {
        onDisconnect = callback
    }

    public func connect() throws {
        guard task == nil else { return }
        guard let url = controlURL else { throw ControlSocketError.invalidURL }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("nano-kvm-token=\(token)", forHTTPHeaderField: "Cookie")

        let webSocketTask = session.webSocketTask(with: request)
        webSocketTask.priority = URLSessionTask.highPriority
        task = webSocketTask
        webSocketTask.resume()

        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                await self?.sendHeartbeat()
            }
        }

        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    public func sendKeyboardReport(_ report: HIDKeyboardReport) async {
        guard let task else { return }
        try? await task.send(.data(report.nanoKVMMessageData))
    }

    public func sendMouseAbsoluteReport(_ report: HIDMouseAbsoluteReport) async {
        guard let task else { return }
        try? await task.send(.data(report.nanoKVMMessageData))
    }

    public func close() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private func sendHeartbeat() async {
        guard let task else { return }
        try? await task.send(.data(Data([0x00])))
    }

    private func receiveLoop() async {
        guard let task else { return }
        while !Task.isCancelled {
            do {
                _ = try await task.receive()
            } catch {
                let callback = onDisconnect
                close()
                if !Task.isCancelled {
                    callback?(error)
                }
                return
            }
        }
    }

    private var controlURL: URL? {
        var components = URLComponents()
        components.scheme = device.webSocketScheme
        components.host = device.host
        let isDefaultPort = (device.scheme == .http && device.port == 80) || (device.scheme == .https && device.port == 443)
        if !isDefaultPort {
            components.port = device.port
        }
        components.path = "/api/ws"
        return components.url
    }
}
