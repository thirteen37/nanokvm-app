# CLAUDE.md

Native Swift/SwiftUI client for hardware KVM-over-IP devices. It originated as a **NanoKVM** client and is now branded as **KVM Console**, with shared backend abstractions for NanoKVM and GLKVM devices. Two app targets — macOS (`KVMConsole`) and iPadOS (`KVMConsoleiPad`) — share a local Swift package `KVMCore` for networking, session, video decode, HID reports, persistence, and the cross-platform SwiftUI views. Both apps ship under bundle ID `io.lyx.KVMConsole`.

## Build / test

`project.yml` is the source of truth. After any source-tree or settings change, regenerate the Xcode project — never hand-edit `KVMConsole.xcodeproj`.

```sh
# Regenerate the Xcode project
xcodegen generate

# macOS unit tests (no code signing)
xcodebuild test \
  -project KVMConsole.xcodeproj \
  -scheme KVMConsole \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY= DEVELOPMENT_TEAM=

# iPadOS unit tests (simulator)
xcodebuild test \
  -project KVMConsole.xcodeproj \
  -scheme KVMConsoleiPad \
  -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY= DEVELOPMENT_TEAM=

# Package-only tests (no Xcode project needed)
swift test --package-path KVMCore

# Local signed macOS build (skip notarization)
NOTARIZE=0 Scripts/build-developer-id.sh
```

Release pipeline is documented in `DeveloperRelease.md`. One published GitHub Release triggers `release.yml`, which builds both platforms off the same tag and a shared timestamp build number: the macOS app via Developer ID signing + notarization, and the iPadOS app via App Store Connect upload to TestFlight (cloud-signed with an App Store Connect API key). Marketing version and build number have a single source of truth in `project.yml` (`settings.base` → `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`), referenced by both targets' Info.plist. CI workflows live in `.github/workflows/` — `test.yml` (macOS + iPadOS), `build-developer-id.yml`, `release.yml`.

## Toolchain

- Swift 6.0, `SWIFT_STRICT_CONCURRENCY: complete`
- macOS 15 / iPadOS 26 deployment target
- iPadOS app: `TARGETED_DEVICE_FAMILY=2` (iPad only — no iPhone, no Catalyst)
- macOS app: hardened runtime, app sandbox, `network.client` entitlement
- No external Swift packages — only Apple frameworks (SwiftUI, AppKit/UIKit, AVFoundation, VideoToolbox, CoreMedia, CoreVideo, Security)

## Layout

`KVMCore/` — local Swift package, depended on by both app targets.
`Sources/KVMCore/`
- `Models/` — `Device`, `SavedDevicesStore`
- `Networking/` — `NanoKVMClient` (REST, JWT), `GLKVMClient` (PiKVM-style REST), `ControlSocket` / `GLKVMControlSocket`, `H264StreamSocket`, `NanoKVMPasswordEncryptor`
- `Session/` — `KVMSession`, `NanoKVMSession`, `GLKVMSession`, and `KVMSessionFactory`
- `Video/` — `H264Decoder` (VideoToolbox), `H264AnnexBParser`, `SampleBufferDisplay` (shared `AVSampleBufferDisplayLayer` config)
- `Input/` — `HIDKeyboardReport`, `HIDMouseReport`, `HIDModifierBit`, `MouseScrollAccumulator`, `MouseCoordinateMapper`, `TripleEscapeDetector`
- `Persistence/` — `KeychainPasswordStore`
- `UI/` — `ConnectionManagerView`, `DeviceEditorView`, `ViewerViewModel`, `ViewerZoomState` (pinch/pan state shared by both viewers), `MinimapView` (overlay shown while zoomed) — pure SwiftUI, used by both apps

`KVMConsole/` — macOS app target.
- `App/KVMConsoleApp.swift` — two-window SwiftUI entry (Connections + Viewer `WindowGroup`)
- `UI/` — `ViewerView`, `ViewerHostView`, `WindowAccessor`
- `Input/` — `KeyboardCaptureView` (NSView responder chain), `FullscreenKeyCapture` (NSEvent local monitor), `HIDKeymap` (Mac virtual keycode → HID usage)
- `Video/VideoRenderView.swift` — `NSViewRepresentable` wrapper over `SampleBufferDisplay`
- `Resources/` — `Info.plist`, `KVMConsole.entitlements`
- `Assets.xcassets/AppIcon`

`KVMConsoleiPad/` — iPadOS app target.
- `App/KVMConsoleiPadApp.swift` — single `WindowGroup` with a `NavigationStack`; the Connection list pushes the Viewer (one connection at a time, no multi-scene)
- `UI/` — `ViewerView`, `ViewerHostView`, `ModifierKeyBar` (Ctrl/Alt/Cmd/Shift/Win on-screen bar, tap = momentary, long-press = lock)
- `Input/` — `KeyboardCaptureView` (`UIPress`/`UIKey`), `PointerCaptureView` (`UIHover`/`UIPan`/`UITap`)
- `Video/VideoRenderView.swift` — `UIViewRepresentable` wrapper over `SampleBufferDisplay`
- `Resources/` — `Info.plist`, `KVMConsole.entitlements`
- `Assets.xcassets/AppIcon`

`KVMConsoleTests/` — XCTest for Mac-only code (`HIDKeymap`, `KeychainPasswordStore`).
`KVMConsoleiPadTests/` — XCTest for iPad-only code (UIKey-to-HID, modifier-bar state).
`KVMCore/Tests/KVMCoreTests/` — cross-platform tests (parsers, networking, HID reports, etc.).

## Conventions

- Networking, session, and socket types are `actor`s. View models are `@MainActor`.
- NanoKVM API responses follow NanoKVM's `{code, msg, data}` envelope — see `NanoKVMClient`; GLKVM uses PiKVM-shaped REST and WebSocket messages.
- Passwords are stored per-device in the Keychain via `KeychainPasswordStore`, never in the saved-devices JSON.
- macOS fullscreen exit is triple-Escape (`FullscreenKeyCapture`). iPad has no fullscreen capture mode.
- iPad supports a single active KVM connection at a time (single-scene NavigationStack); macOS allows multiple viewer windows side-by-side.
