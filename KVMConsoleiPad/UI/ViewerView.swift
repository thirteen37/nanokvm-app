import KVMCore
import SwiftUI

struct ViewerHostView: View {
    let deviceID: Device.ID?
    @EnvironmentObject private var devicesStore: SavedDevicesStore

    var body: some View {
        Group {
            if let deviceID, let device = devicesStore.device(id: deviceID) {
                ViewerView(device: device) { id in
                    devicesStore.markConnected(id)
                }
            } else {
                missingDevice
            }
        }
    }

    private var missingDevice: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
            Text("Device not found")
                .font(.headline)
            Text("This device is no longer in your saved list.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ViewerView: View {
    @StateObject private var model: ViewerViewModel
    @State private var modifierState = ModifierKeyState()
    @State private var showModifierBar = true
    @State private var keyboardFocusToken = 0
    @State private var pendingVirtualKey: VirtualKeyTap?

    init(device: Device, onConnected: ((Device.ID) -> Void)? = nil) {
        _model = StateObject(wrappedValue: ViewerViewModel(device: device, onConnected: onConnected))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            videoArea

            if model.passwordPrompt != nil {
                passwordPromptOverlay
            }

            if showsErrorOverlay {
                errorOverlay
            }

            if showModifierBar, model.passwordPrompt == nil, !showsErrorOverlay {
                ModifierKeyBar(state: $modifierState) { usage, modifier in
                    sendVirtualKey(usage: usage, modifier: modifier)
                }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
        }
        .background(Color.black)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .onDisappear {
            model.disconnect()
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

            PointerCaptureView(
                isEnabled: model.isStreaming && model.isMouseCaptureEnabled,
                isScrollInverted: model.isScrollInverted,
                videoSize: model.videoSize,
                zoom: model.zoom,
                onMouseReport: { report in model.sendMouseReport(report) }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            KeyboardCaptureView(
                isEnabled: model.isStreaming && model.isKeyboardCaptureEnabled,
                keyboardFocusToken: keyboardFocusToken,
                extraModifierByte: modifierState.activeModifierByte,
                pendingVirtualKey: pendingVirtualKey,
                onKeyboardReport: { report in model.sendKeyboardReport(report) },
                onMomentaryModifiersConsumed: { modifierState.consumeMomentary() }
            )
            .frame(width: 1, height: 1)
            .accessibilityHidden(true)

            LocalCursorView(
                isVisible: showsLocalCursor,
                videoSize: model.videoSize,
                zoom: model.zoom
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            MinimapView(zoom: model.zoom) {
                MinimapVideoRenderView(renderCoordinator: model.renderCoordinator)
            }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .allowsHitTesting(false)
        }
    }

    private var showsLocalCursor: Bool {
        model.isStreaming
            && model.isMouseCaptureEnabled
            && (model.device.kvmType == .appleScreenSharing || model.device.kvmType == .vnc)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            VStack(spacing: 0) {
                Text(model.device.name)
                    .font(.headline)
                Text(model.device.host)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        ToolbarItemGroup(placement: .topBarTrailing) {
            Toggle(isOn: $model.isKeyboardCaptureEnabled) {
                Label("Keyboard", systemImage: "keyboard")
            }
            .toggleStyle(.button)
            .labelStyle(.iconOnly)
            .help(model.isKeyboardCaptureEnabled
                  ? "Forwarding keyboard to host — tap to stop"
                  : "Keyboard forwarding off — tap to enable")

            Toggle(isOn: $model.isMouseCaptureEnabled) {
                Label("Mouse", systemImage: "cursorarrow")
            }
            .toggleStyle(.button)
            .labelStyle(.iconOnly)
            .help(model.isMouseCaptureEnabled
                  ? "Forwarding mouse to host — tap to stop"
                  : "Mouse forwarding off — tap to enable")

            Toggle(isOn: $model.isScrollInverted) {
                Label("Invert Scroll", systemImage: "arrow.up.arrow.down")
            }
            .toggleStyle(.button)
            .labelStyle(.iconOnly)
            .help(model.isScrollInverted
                  ? "Scroll direction inverted — tap to use natural direction"
                  : "Natural scroll direction — tap to invert")

            Toggle(isOn: $showModifierBar) {
                Label("Modifiers", systemImage: "command")
            }
            .toggleStyle(.button)
            .labelStyle(.iconOnly)
            .help(showModifierBar ? "Hide modifier-key bar" : "Show modifier-key bar")

            Button {
                keyboardFocusToken += 1
            } label: {
                Label("Show Keyboard", systemImage: "keyboard.chevron.compact.down")
            }
            .labelStyle(.iconOnly)
            .help("Show on-screen keyboard")
        }

        #if compiler(>=6.2)
        ToolbarSpacer(.fixed, placement: .topBarTrailing)
        #endif

        ToolbarItem(placement: .topBarTrailing) {
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

        ToolbarItemGroup(placement: .topBarTrailing) {
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

    private var passwordPromptOverlay: some View {
        VStack(spacing: 12) {
            Text("Enter password for \(model.device.username)@\(model.device.host)")
                .font(.headline)
            SecureField("Password", text: $model.passwordInput)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.go)
                .onSubmit { model.submitPassword() }

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .lineLimit(3)
            }

            HStack {
                Button("Connect") { model.submitPassword() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.passwordInput.isEmpty)
            }
        }
        .padding(20)
        .frame(maxWidth: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var showsErrorOverlay: Bool {
        model.state.errorMessage != nil && model.passwordPrompt == nil
    }

    private var errorOverlay: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.red)
            Text("Connection failed")
                .font(.headline)
            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
            }
            Button {
                model.reconnect()
            } label: {
                Label("Reconnect", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(maxWidth: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private func sendVirtualKey(usage: UInt8, modifier: UInt8) {
        pendingVirtualKey = VirtualKeyTap(id: UUID(), usage: usage, transientModifier: modifier)
    }
}
