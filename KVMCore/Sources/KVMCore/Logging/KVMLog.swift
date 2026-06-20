import OSLog

enum KVMLog {
    static let nanokvm = Logger(subsystem: "com.kvmconsole.app", category: "NanoKVM")
    static let glkvm = Logger(subsystem: "com.kvmconsole.app", category: "GLKVM")
    static let rfb = Logger(subsystem: "com.kvmconsole.app", category: "RFB")
    static let video = Logger(subsystem: "com.kvmconsole.app", category: "Video")
}
