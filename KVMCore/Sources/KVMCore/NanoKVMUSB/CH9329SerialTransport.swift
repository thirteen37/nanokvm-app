#if os(macOS)
import Darwin
import Foundation

public enum CH9329SerialError: Error, LocalizedError {
    case portNotFound(path: String)
    case openFailed(path: String, errno: Int32)
    case configureFailed(errno: Int32)
    case writeFailed(errno: Int32)
    case closed

    public var errorDescription: String? {
        switch self {
        case .portNotFound(let path):
            return "Serial port \(path) is no longer attached. If you moved the NanoKVM USB "
                + "to another USB port, re-select it in Edit Device."
        case .openFailed(let path, let code):
            return "Could not open serial port \(path) (errno=\(code), \(String(cString: strerror(code))))"
        case .configureFailed(let code):
            return "Could not configure serial port (errno=\(code), \(String(cString: strerror(code))))"
        case .writeFailed(let code):
            return "Serial port write failed (errno=\(code), \(String(cString: strerror(code))))"
        case .closed:
            return "Serial port is closed"
        }
    }
}

/// Owns one POSIX file descriptor for the CH9329 USB-CDC serial bridge.
/// All access is serialised through the actor; callers send pre-encoded packets.
public actor CH9329SerialTransport {
    public let devicePath: String
    private var fd: Int32 = -1
    private var onDisconnect: (@Sendable (Error?) -> Void)?

    public init(devicePath: String) {
        self.devicePath = devicePath
    }

    deinit {
        if fd >= 0 {
            Darwin.close(fd)
        }
    }

    public func open() throws {
        guard fd < 0 else { return }

        // Open non-blocking so the call returns even if the carrier-detect (DCD) line
        // would otherwise stall; we restore blocking semantics for write() once configured.
        let opened = Darwin.open(devicePath, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard opened >= 0 else {
            throw CH9329SerialError.openFailed(path: devicePath, errno: errno)
        }

        do {
            try configure(fd: opened)
        } catch {
            Darwin.close(opened)
            throw error
        }

        // Clear O_NONBLOCK so subsequent write()s block until the bytes are queued.
        let flags = fcntl(opened, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(opened, F_SETFL, flags & ~O_NONBLOCK)
        }

        fd = opened
    }

    public func send(_ packet: Data) throws {
        guard fd >= 0 else { throw CH9329SerialError.closed }

        try packet.withUnsafeBytes { raw -> Void in
            guard var base = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let written = Darwin.write(fd, base, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    let code = errno
                    handleWriteFailure(code: code)
                    throw CH9329SerialError.writeFailed(errno: code)
                }
                if written == 0 { break }
                remaining -= written
                base = base.advanced(by: written)
            }
        }
    }

    public func close() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    public func setOnDisconnect(_ handler: (@Sendable (Error?) -> Void)?) {
        onDisconnect = handler
    }

    public var isOpen: Bool { fd >= 0 }

    private func configure(fd: Int32) throws {
        var settings = termios()
        guard tcgetattr(fd, &settings) == 0 else {
            throw CH9329SerialError.configureFailed(errno: errno)
        }

        cfmakeraw(&settings)
        // On Darwin the termios Bxxx speed constants are defined as their literal baud
        // values, so the protocol's baudRate is the single source of truth for the port.
        guard cfsetspeed(&settings, speed_t(CH9329Protocol.baudRate)) == 0 else {
            throw CH9329SerialError.configureFailed(errno: errno)
        }

        // 8N1 + local + read enabled. cfmakeraw already turns off canonical mode,
        // echo, signal generation, etc. — we just nail down the data bits.
        settings.c_cflag &= ~tcflag_t(CSIZE | PARENB | CSTOPB | CRTSCTS)
        settings.c_cflag |= tcflag_t(CS8 | CLOCAL | CREAD)

        // Don't block forever on read; the session does not currently read responses.
        withUnsafeMutablePointer(to: &settings.c_cc) { ccPtr in
            ccPtr.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { bytes in
                bytes[Int(VMIN)] = 0
                bytes[Int(VTIME)] = 0
            }
        }

        guard tcsetattr(fd, TCSANOW, &settings) == 0 else {
            throw CH9329SerialError.configureFailed(errno: errno)
        }

        _ = tcflush(fd, TCIOFLUSH)
    }

    private func handleWriteFailure(code: Int32) {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
        if let onDisconnect {
            onDisconnect(CH9329SerialError.writeFailed(errno: code))
        }
    }
}
#endif
