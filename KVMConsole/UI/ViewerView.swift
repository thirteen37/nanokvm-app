import AppKit
import KVMCore
import OSLog
import SwiftUI

private let viewerLog = Logger(subsystem: "com.kvmconsole.app", category: "Viewer")

struct ViewerHostView: View {
    let deviceID: Device.ID?
    @EnvironmentObject private var devicesStore: SavedDevicesStore

    var body: some View {
        Group {
            if let deviceID, let device = devicesStore.device(id: deviceID) {
                ViewerView(device: device) { id in
                    devicesStore.markConnected(id)
                }
                    .navigationTitle(device.name)
                    .navigationSubtitle(device.host)
            } else {
                missingDevice
            }
        }
        .frame(minWidth: 900, minHeight: 560)
    }

    private var missingDevice: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
            Text("Device not found")
                .font(.headline)
            Text("This device is no longer in your saved list.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ViewerView: View {
    @StateObject private var model: ViewerViewModel
    @State private var window: NSWindow?
    @State private var coordinator: FullscreenKeyCaptureCoordinator?
    @State private var toolbarHideTask: Task<Void, Never>?

    private static let toolbarHideDelayNs: UInt64 = 2_000_000_000

    init(device: Device, onConnected: ((Device.ID) -> Void)? = nil) {
        _model = StateObject(wrappedValue: ViewerViewModel(device: device, onConnected: onConnected))
    }

    var body: some View {
        ZStack(alignment: .top) {
            videoArea

            if model.showFullscreenBanner {
                fullscreenBanner
                    .transition(.opacity)
                    .frame(maxHeight: .infinity, alignment: .top)
            }

            if model.isFullscreen {
                captureStatusBadge
                    .transition(.opacity)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }

            if model.passwordPrompt != nil {
                passwordPromptOverlay
            }
        }
        .background(WindowAccessor { newWindow in
            attachWindow(newWindow)
        })
        .toolbar { toolbarContent }
        .animation(.easeInOut(duration: 0.25), value: model.showFullscreenBanner)
        .animation(.easeInOut(duration: 0.25), value: model.fullscreenKeyCaptureMode)
        .animation(.easeInOut(duration: 0.25), value: model.isKeyboardCaptureEnabled)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { note in
            guard let w = note.object as? NSWindow, w === window else { return }
            handleEnterFullScreen()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
            guard let w = note.object as? NSWindow, w === window else { return }
            handleExitFullScreen()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            guard let w = note.object as? NSWindow, w === window else { return }
            cleanupWindowResources()
        }
    }

    private var videoArea: some View {
        ZStack {
            Color.black

            VideoRenderView(
                renderCoordinator: model.renderCoordinator,
                scale: model.zoom.scale,
                center: model.zoom.center,
                videoSize: model.videoSize
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            KeyboardCaptureView(
                isKeyboardEnabled: model.isStreaming && model.isKeyboardCaptureEnabled && !model.isFullscreen,
                isMouseEnabled: model.isStreaming && model.isMouseCaptureEnabled,
                hidesLocalCursor: hidesLocalCursor,
                isScrollInverted: model.isScrollInverted,
                allowsKeyRepeat: allowsKeyRepeat,
                videoSize: model.videoSize,
                zoom: model.zoom,
                onKeyboardReport: { report in model.sendKeyboardReport(report) },
                onMouseReport: { report in model.sendMouseReport(report) }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            MinimapView(zoom: model.zoom) {
                MinimapVideoRenderView(renderCoordinator: model.renderCoordinator)
            }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .allowsHitTesting(false)
        }
    }

    private var hidesLocalCursor: Bool {
        model.device.kvmType != .appleScreenSharing && model.device.kvmType != .vnc
    }

    private var allowsKeyRepeat: Bool {
        model.device.kvmType == .appleScreenSharing || model.device.kvmType == .vnc
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: $model.isKeyboardCaptureEnabled) {
                Label("Keyboard", systemImage: "keyboard")
            }
            .toggleStyle(.button)
            .labelStyle(.iconOnly)
            .help(model.isKeyboardCaptureEnabled
                  ? "Forwarding keyboard to host — click to stop"
                  : "Keyboard forwarding off — click to enable")

            Toggle(isOn: $model.isMouseCaptureEnabled) {
                Label("Mouse", systemImage: "cursorarrow")
            }
            .toggleStyle(.button)
            .labelStyle(.iconOnly)
            .help(model.isMouseCaptureEnabled
                  ? "Forwarding mouse to host — click to stop"
                  : "Mouse forwarding off — click to enable")

            Toggle(isOn: $model.isScrollInverted) {
                Label("Invert Scroll", systemImage: "arrow.up.arrow.down")
            }
            .toggleStyle(.button)
            .labelStyle(.iconOnly)
            .help(model.isScrollInverted
                  ? "Scroll direction inverted — click to use natural direction"
                  : "Natural scroll direction — click to invert")
        }

        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
        #endif

        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: 14) {
                if model.supportsHostStatus {
                    HostStatusIndicators(
                        status: model.hostStatus,
                        isActive: model.state == .streaming
                    )
                }

                HStack(spacing: 4) {
                    Image(systemName: connectionSymbol)
                        .foregroundStyle(statusColor)
                    Text(model.state.displayText)
                        .font(.callout)
                }
            }
            .padding(.horizontal, 12)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if model.supportsPowerControl {
                Menu {
                    Button("On") { model.powerOn() }
                    Button("Off") { model.powerOff() }
                    Button("Force Off") { model.forceOff() }
                    Divider()
                    Button("Reset") { model.resetPower() }
                    Button("Long Press Power") { model.longPressPower() }
                } label: {
                    Label("Power", systemImage: "power")
                }
                .disabled(model.powerControl == nil)
                .help("ATX power")
            }

            Button {
                if model.isStreaming {
                    model.disconnect()
                } else {
                    model.reconnect()
                }
            } label: {
                Label(
                    model.isStreaming ? "Disconnect" : "Reconnect",
                    systemImage: model.isStreaming ? "xmark.circle" : "arrow.clockwise"
                )
                .padding(.horizontal, 6)
            }
            .labelStyle(.titleAndIcon)
            .controlSize(.small)
            .help(model.isStreaming
                  ? "Disconnect from \(model.device.host)"
                  : "Reconnect to \(model.device.host)")
        }
    }

    private var fullscreenBanner: some View {
        Text(fullscreenBannerText)
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .padding(.top, 60)
    }

    private var captureStatusBadge: some View {
        Button {
            if effectiveFullscreenKeyCaptureMode == .limited {
                openAccessibilitySettings()
            }
        } label: {
            Label(captureStatusLabel, systemImage: captureStatusSymbol)
                .font(.caption.weight(.semibold))
                .labelStyle(.titleAndIcon)
                .foregroundStyle(captureStatusForeground)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(captureStatusBorder, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .disabled(effectiveFullscreenKeyCaptureMode != .limited)
        .help(captureStatusHelp)
        .padding(.top, 64)
        .padding(.trailing, 16)
    }

    private var fullscreenBannerText: String {
        switch effectiveFullscreenKeyCaptureMode {
        case .allKeys:
            return "Capturing all keys - triple-Esc to release"
        case .limited:
            return "Limited capture - Cmd+Space and system shortcuts won't reach the remote. Enable Accessibility in System Settings."
        case .off:
            return "Keyboard capture off"
        }
    }

    private var effectiveFullscreenKeyCaptureMode: FullscreenKeyCaptureMode {
        model.isKeyboardCaptureEnabled ? model.fullscreenKeyCaptureMode : .off
    }

    private var captureStatusLabel: String {
        switch effectiveFullscreenKeyCaptureMode {
        case .allKeys: return "All keys"
        case .limited: return "Limited keys"
        case .off: return "Capture off"
        }
    }

    private var captureStatusSymbol: String {
        switch effectiveFullscreenKeyCaptureMode {
        case .allKeys: return "keyboard.badge.ellipsis"
        case .limited: return "exclamationmark.triangle.fill"
        case .off: return "keyboard.badge.eye"
        }
    }

    private var captureStatusForeground: Color {
        switch effectiveFullscreenKeyCaptureMode {
        case .allKeys: return .green
        case .limited: return .orange
        case .off: return .secondary
        }
    }

    private var captureStatusBorder: Color {
        switch effectiveFullscreenKeyCaptureMode {
        case .allKeys: return .green.opacity(0.55)
        case .limited: return .orange.opacity(0.7)
        case .off: return .secondary.opacity(0.45)
        }
    }

    private var captureStatusHelp: String {
        switch effectiveFullscreenKeyCaptureMode {
        case .allKeys:
            return "All fullscreen keys are forwarded to the host"
        case .limited:
            return "Open Accessibility settings to allow all-key capture"
        case .off:
            return "Keyboard forwarding is off"
        }
    }

    private var passwordPromptOverlay: some View {
        VStack(spacing: 12) {
            Text("Enter password for \(model.device.username)@\(model.device.host)")
                .font(.headline)
            SecureField("Password", text: $model.passwordInput)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit { model.submitPassword() }

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .lineLimit(3)
            }

            HStack {
                Button("Connect") { model.submitPassword() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.passwordInput.isEmpty)
            }
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: 360)
    }

    private var statusColor: Color {
        switch model.state {
        case .streaming: return .green
        case .error: return .red
        case .connecting: return .orange
        case .disconnected: return .secondary
        }
    }

    private var connectionSymbol: String {
        switch model.state {
        case .streaming: return "antenna.radiowaves.left.and.right"
        case .connecting: return "antenna.radiowaves.left.and.right"
        case .disconnected: return "antenna.radiowaves.left.and.right.slash"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private func attachWindow(_ newWindow: NSWindow?) {
        window = newWindow
        guard let newWindow else {
            model.toggleFullscreen = nil
            return
        }
        newWindow.collectionBehavior.insert(.fullScreenPrimary)
        model.toggleFullscreen = { [weak newWindow] in
            newWindow?.toggleFullScreen(nil)
        }
    }

    private func handleEnterFullScreen() {
        guard let window else { return }
        window.toolbar?.isVisible = false
        model.isFullscreen = true
        let coord = FullscreenKeyCaptureCoordinator(
            isCapturing: { [model] in model.isKeyboardCaptureEnabled },
            allowsKeyRepeat: allowsKeyRepeat,
            onKeyboardReport: { [model] report in model.sendKeyboardReport(report) },
            onTripleEscape: { [model] in model.handleTripleEscape() },
            onTopEdgeHover: { revealToolbar() },
            onTopEdgeLeft: { scheduleToolbarHide() },
            onCaptureModeChange: { [model] mode in model.setFullscreenKeyCaptureMode(mode) }
        )
        coord.start(window: window)
        coordinator = coord
        model.presentFullscreenBanner()
    }

    private func handleExitFullScreen() {
        coordinator?.stop()
        coordinator = nil
        toolbarHideTask?.cancel()
        toolbarHideTask = nil
        window?.toolbar?.isVisible = true
        model.isFullscreen = false
        model.clearFullscreenBanner()
    }

    private func revealToolbar() {
        toolbarHideTask?.cancel()
        toolbarHideTask = nil
        window?.toolbar?.isVisible = true
    }

    private func scheduleToolbarHide() {
        guard window?.toolbar?.isVisible == true else { return }
        toolbarHideTask?.cancel()
        toolbarHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.toolbarHideDelayNs)
            guard !Task.isCancelled else { return }
            window?.toolbar?.isVisible = false
        }
    }

    private func cleanupWindowResources() {
        viewerLog.info("Viewer window closing; cleaning up window resources")
        coordinator?.stop()
        coordinator = nil
        toolbarHideTask?.cancel()
        toolbarHideTask = nil
        model.clearFullscreenBanner()
        model.disconnect()
    }

    private func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
