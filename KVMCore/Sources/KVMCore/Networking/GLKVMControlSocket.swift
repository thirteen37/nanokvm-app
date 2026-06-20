import Foundation

public enum GLKVMControlSocketError: Error, LocalizedError, Equatable {
    case invalidURL
    case disconnectedBeforeStreaming

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid GLKVM control socket URL."
        case .disconnectedBeforeStreaming: return "GLKVM control socket disconnected before streaming began."
        }
    }
}

public actor GLKVMControlSocket {
    private let device: Device
    private let authToken: String
    private let session: URLSession
    private let ownedSession: URLSession?
    private var task: URLSessionWebSocketTask?
    private var heartbeatTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var onDisconnect: (@Sendable (Error) -> Void)?
    private var onHostStatusUpdate: (@Sendable (KVMHostStatus) -> Void)?
    private var hostStatus = KVMHostStatus()
    private var lastKeyboardReport = HIDKeyboardReport()
    private var lastMouseButtons: UInt8 = 0

    public init(device: Device, authToken: String, session: URLSession? = nil) {
        self.device = device
        self.authToken = authToken
        if let session {
            self.session = session
            self.ownedSession = nil
        } else if device.allowsInsecureTLS {
            let delegate = InsecureTLSDelegate()
            let owned = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            self.session = owned
            self.ownedSession = owned
        } else {
            self.session = URLSession.shared
            self.ownedSession = nil
        }
    }

    /// `false` once the socket has dropped (its receive loop nils `task` via `close()`), letting the
    /// session detect a control-socket drop during the connecting window before handing off.
    public var isOpen: Bool { task != nil }

    public func setOnDisconnect(_ callback: @escaping @Sendable (Error) -> Void) {
        onDisconnect = callback
    }

    public func setOnHostStatusUpdate(_ callback: @escaping @Sendable (KVMHostStatus) -> Void) {
        onHostStatusUpdate = callback
    }

    public func connect() throws {
        guard task == nil else { return }
        guard let url = controlURL else { throw GLKVMControlSocketError.invalidURL }

        var request = URLRequest(url: url)
        request.setValue("auth_token=\(authToken)", forHTTPHeaderField: "Cookie")
        KVMLog.glkvm.info("Opening GLKVM control WebSocket: \(url.absoluteString, privacy: .public)")

        let webSocketTask = session.webSocketTask(with: request)
        webSocketTask.priority = URLSessionTask.highPriority
        task = webSocketTask
        webSocketTask.resume()

        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                await self?.sendPing()
            }
        }

        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    public func sendKeyboardReport(_ report: HIDKeyboardReport) async {
        guard let task else { return }
        for event in Self.keyboardEvents(from: lastKeyboardReport, to: report) {
            try? await task.send(.data(Self.encodeBinary(event)))
        }
        lastKeyboardReport = report
    }

    public func sendMouseAbsoluteReport(_ report: HIDMouseAbsoluteReport) async {
        guard let task else { return }
        let move = GLKVMOutboundEvent.mouseMove(
            x: Self.pikvmCoordinate(from: report.x),
            y: Self.pikvmCoordinate(from: report.y)
        )
        try? await task.send(.data(Self.encodeBinary(move)))

        for event in Self.mouseButtonEvents(from: lastMouseButtons, to: report.buttons) {
            try? await task.send(.data(Self.encodeBinary(event)))
        }
        lastMouseButtons = report.buttons

        if report.wheel != 0 {
            try? await task.send(.data(Self.encodeBinary(.mouseWheel(x: 0, y: Int(report.wheel)))))
        }
    }

    public func close() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        ownedSession?.invalidateAndCancel()
    }

    public nonisolated static func keyboardEvents(
        from oldReport: HIDKeyboardReport,
        to newReport: HIDKeyboardReport
    ) -> [GLKVMOutboundEvent] {
        var events: [GLKVMOutboundEvent] = []

        for bit in HIDModifierBit.allCases {
            let wasPressed = oldReport.modifier & bit.rawValue != 0
            let isPressed = newReport.modifier & bit.rawValue != 0
            guard wasPressed != isPressed else { continue }
            events.append(.key(code: HIDUsageToDOMCode.modifierCode(for: bit), isPressed: isPressed))
        }

        let oldKeys = Set(oldReport.keycodes.filter { $0 != 0 })
        let newKeys = Set(newReport.keycodes.filter { $0 != 0 })
        for usage in oldKeys.subtracting(newKeys).sorted() {
            if let code = HIDUsageToDOMCode.lookup(usage: usage) {
                events.append(.key(code: code, isPressed: false))
            }
        }
        for usage in newKeys.subtracting(oldKeys).sorted() {
            if let code = HIDUsageToDOMCode.lookup(usage: usage) {
                events.append(.key(code: code, isPressed: true))
            }
        }
        return events
    }

    public nonisolated static func mouseButtonEvents(from oldButtons: UInt8, to newButtons: UInt8) -> [GLKVMOutboundEvent] {
        (0..<5).compactMap { index in
            let mask = UInt8(1 << index)
            let wasPressed = oldButtons & mask != 0
            let isPressed = newButtons & mask != 0
            guard wasPressed != isPressed else { return nil }
            guard let button = Self.mouseButtonName(for: index) else { return nil }
            return .mouseButton(button: button, isPressed: isPressed)
        }
    }

    public nonisolated static func mouseButtonName(for index: Int) -> String? {
        switch index {
        case 0: return "left"
        case 1: return "right"
        case 2: return "middle"
        case 3: return "up"
        case 4: return "down"
        default: return nil
        }
    }

    public nonisolated static func pikvmCoordinate(from value: UInt16) -> Int {
        let clamped = max(1, min(32_768, Int(value)))
        let normalized = Double(clamped - 1) / 32_767.0
        return Int((normalized * 65_535.0).rounded()) - 32_768
    }

    public nonisolated static func encode(_ event: GLKVMOutboundEvent) -> Data {
        (try? JSONEncoder().encode(event)) ?? Data()
    }

    public nonisolated static func encodeString(_ event: GLKVMOutboundEvent) -> String {
        String(data: encode(event), encoding: .utf8) ?? "{}"
    }

    public nonisolated static func encodeBinary(_ event: GLKVMOutboundEvent) -> Data {
        switch event {
        case .key(let code, let isPressed):
            var payload = Data([0x01, isPressed ? 0x01 : 0x00])
            payload.append(Data(code.utf8))
            return payload
        case .mouseButton(let button, let isPressed):
            var payload = Data([0x02, isPressed ? 0x01 : 0x00])
            payload.append(Data(button.utf8))
            return payload
        case .mouseMove(let x, let y):
            return Data([
                0x03,
                UInt8((x >> 8) & 0xff),
                UInt8(x & 0xff),
                UInt8((y >> 8) & 0xff),
                UInt8(y & 0xff),
            ])
        case .mouseWheel(let x, let y):
            return Data([
                0x05,
                0x00,
                UInt8(bitPattern: Int8(clamping: x)),
                UInt8(bitPattern: Int8(clamping: y)),
            ])
        case .ping:
            return encode(event)
        }
    }

    private func sendPing() async {
        guard let task else { return }
        try? await task.send(.string(Self.encodeString(.ping)))
    }

    private func receiveLoop() async {
        guard let task else { return }
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                handleInboundMessage(message)
            } catch {
                KVMLog.glkvm.error("GLKVM control WebSocket closed: \(error.localizedDescription, privacy: .public)")
                let wasCancelled = Task.isCancelled
                let callback = onDisconnect
                close()
                if !wasCancelled {
                    callback?(error)
                }
                return
            }
        }
    }

    private func handleInboundMessage(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let text):
            data = Data(text.utf8)
        case .data(let payload):
            data = payload
        @unknown default:
            return
        }

        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let eventType = object["event_type"] as? String,
            eventType != "pong"
        else { return }

        let event = object["event"] as? [String: Any]

        if eventType == "streamer", let event {
            KVMLog.glkvm.info("GLKVM streamer state: \(Self.streamerStateDescription(event), privacy: .public)")
            if let signal = Self.parseStreamerHDMISignal(event), hostStatus.hdmiSignal != signal {
                hostStatus.hdmiSignal = signal
                onHostStatusUpdate?(hostStatus)
            }
        } else if eventType == "hid", let event {
            KVMLog.glkvm.info("GLKVM HID state: \(Self.hidStateDescription(event), privacy: .public)")
        } else if eventType == "atx", let event {
            if let power = Self.parseATXPower(event), hostStatus.atxPower != power {
                hostStatus.atxPower = power
                onHostStatusUpdate?(hostStatus)
            }
        }
    }

    public nonisolated static func parseATXPower(_ event: [String: Any]) -> ATXPowerState? {
        // GLKVM (Comet) exposes the host power state as a top-level string field
        // `event.power` with values "on" / "off". The nested `leds.power` boolean is the
        // physical LED indicator state, which is *not* the same as host power (e.g.,
        // leds.power=false while the host is powered on).
        if let raw = event["power"] as? String {
            switch raw.lowercased() {
            case "on": return .on
            case "off": return .off
            default: return nil
            }
        }
        return nil
    }

    public nonisolated static func parseStreamerHDMISignal(_ event: [String: Any]) -> Bool? {
        // Live telemetry nests under `event.streamer.hdmi.signal`. The initial event after
        // subscription has `streamer: null` (capability snapshot) and is correctly ignored.
        let streamer = event["streamer"] as? [String: Any]
        let hdmi = streamer?["hdmi"] as? [String: Any]
        return hdmi?["signal"] as? Bool
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

    private nonisolated static func streamerStateDescription(_ event: [String: Any]) -> String {
        // The capability/config event has `streamer: null` with `params` at the top level.
        // The runtime telemetry event nests everything under `event.streamer`.
        let streamer = event["streamer"] as? [String: Any]
        let source = streamer?["source"] as? [String: Any]
        let hdmi = streamer?["hdmi"] as? [String: Any]
        let params = (streamer?["h264"] as? [String: Any]) ?? (event["params"] as? [String: Any])
        let resolution = source?["resolution"] as? [String: Any]
        let width = valueDescription(resolution?["width"])
        let height = valueDescription(resolution?["height"])

        return [
            "sourceOnline=\(valueDescription(source?["online"]))",
            "hdmiSignal=\(valueDescription(hdmi?["signal"]))",
            "resolution=\(width)x\(height)",
            "h264Bitrate=\(valueDescription(params?["bitrate"] ?? params?["h264_bitrate"]))",
            "h264Gop=\(valueDescription(params?["gop"] ?? params?["h264_gop"]))",
        ].joined(separator: " ")
    }

    private nonisolated static func hidStateDescription(_ event: [String: Any]) -> String {
        let mouse = event["mouse"] as? [String: Any]
        let keyboard = event["keyboard"] as? [String: Any]
        return [
            "mouseOnline=\(valueDescription(mouse?["online"]))",
            "keyboardOnline=\(valueDescription(keyboard?["online"]))",
        ].joined(separator: " ")
    }

    private nonisolated static func valueDescription(_ value: Any?) -> String {
        guard let value else { return "-" }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        }
        return String(describing: value)
    }
}

public enum GLKVMOutboundEvent: Encodable, Equatable, Sendable {
    case key(code: String, isPressed: Bool)
    case mouseMove(x: Int, y: Int)
    case mouseButton(button: String, isPressed: Bool)
    case mouseWheel(x: Int, y: Int)
    case ping

    private enum CodingKeys: String, CodingKey {
        case eventType = "event_type"
        case event
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .key(let code, let isPressed):
            try container.encode("key", forKey: .eventType)
            try container.encode(KeyEvent(key: code, state: isPressed), forKey: .event)
        case .mouseMove(let x, let y):
            try container.encode("mouse_move", forKey: .eventType)
            try container.encode(MouseMoveEvent(to: MouseMoveEvent.Point(x: x, y: y)), forKey: .event)
        case .mouseButton(let button, let isPressed):
            try container.encode("mouse_button", forKey: .eventType)
            try container.encode(MouseButtonEvent(button: button, state: isPressed), forKey: .event)
        case .mouseWheel(let x, let y):
            try container.encode("mouse_wheel", forKey: .eventType)
            try container.encode(MouseWheelEvent(delta: MouseWheelEvent.Point(x: x, y: y)), forKey: .event)
        case .ping:
            try container.encode("ping", forKey: .eventType)
            try container.encode(EmptyEvent(), forKey: .event)
        }
    }

    private struct EmptyEvent: Encodable {}
    private struct KeyEvent: Encodable { let key: String; let state: Bool }
    private struct MouseButtonEvent: Encodable { let button: String; let state: Bool }
    private struct MouseWheelEvent: Encodable {
        struct Point: Encodable { let x: Int; let y: Int }
        let delta: Point
    }
    private struct MouseMoveEvent: Encodable {
        struct Point: Encodable { let x: Int; let y: Int }
        let to: Point
    }
}
