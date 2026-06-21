# KVM Console for macOS and iPadOS

A native SwiftUI client for hardware KVM-over-IP devices and RFB/VNC hosts. It started as a client for [Sipeed NanoKVM](https://github.com/sipeed/NanoKVM), and now also supports PiKVM-shaped GLKVM devices such as the GL.iNet Comet GL-RM1, macOS Apple Screen Sharing, and generic VNC servers.

I started this after using NanoKVM to drive my spare Mac in the closet for AI-agent workflows. The goal is a KVM client that feels closer to sitting at the machine: shortcuts arrive at the remote host, pointer and scroll input behave predictably, and the video path stays low-latency.

## Features

- Manage multiple KVM devices, each with its own URL, port, device type, and credentials
- Per-device passwords stored securely in the Apple Keychain
- Native NanoKVM H.264 streaming with hardware-accelerated VideoToolbox decode
- GLKVM device profiles and control path for PiKVM-style keyboard, mouse, clipboard, and ATX power controls
- Apple Screen Sharing support over RFB with macOS account/password authentication
- Generic VNC support over RFB with standard VNC password authentication
- Lower-latency native video and input path than driving the KVM through a browser
- Full keyboard capture, including shortcuts such as Cmd-W that browsers normally intercept
- More reliable scrolling and absolute-positioning mouse input over HID WebSocket or RFB input events
- iPadOS support with better hardware keyboard, modifier-key, pointer, and scrolling behavior
- Pinch-to-zoom on the remote video with a bottom-right minimap; pinching also pans (the grabbed video point follows the fingers), and the viewport follows the remote cursor toward the edges when zoomed in
- Local cursor overlay for RFB sessions when the remote server does not include a cursor in the framebuffer
- Direct latest-frame rendering for RFB sessions to reduce visible keyboard and mouse echo latency
- macOS fullscreen viewer with triple-Escape to exit
- Connection heartbeat with automatic state surfacing in the UI

## Supported connection types

- NanoKVM (Lite): IP-based NanoKVM with native H.264 video and HID control
- NanoKVM USB (macOS only): Sipeed USB capture stick — UVC video plus CH9329 serial keyboard/mouse over USB
- GL.iNet Comet: GLKVM/WebRTC video, keyboard/mouse input, clipboard, and ATX power controls
- Apple Screen Sharing: macOS built-in Screen Sharing on port 5900 using a macOS account and password
- VNC: standard RFB/VNC password authentication for compatible VNC servers

## Requirements

- macOS 15 (Sequoia) or later for the Mac app
- iPadOS 26 or later for the iPad app
- A supported KVM device or RFB/VNC host reachable over the network

## Install

For macOS, download `KVMConsole-<tag>.dmg` from the latest [GitHub Release](../../releases), open it, and drag `KVM Console` into the `Applications` folder.

## Build from source

The Xcode project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
brew install xcodegen
xcodegen generate
open KVMConsole.xcodeproj
```

To run the unit tests from the command line without signing:

```sh
xcodebuild test \
  -project KVMConsole.xcodeproj \
  -scheme KVMConsole \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY= DEVELOPMENT_TEAM=
```

To run the iPadOS unit tests in Simulator:

```sh
xcodebuild test \
  -project KVMConsole.xcodeproj \
  -scheme KVMConsoleiPad \
  -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)'
```

To produce a locally signed build (no notarization):

```sh
NOTARIZE=0 Scripts/build-developer-id.sh
```

The app is mostly built on Apple frameworks (SwiftUI, AppKit/UIKit, AVFoundation, VideoToolbox, CoreMedia, CoreVideo, Security, Network). GLKVM WebRTC support uses the `stasel/WebRTC` Swift package. RFB/VNC support is implemented in Swift over plain TCP with Apple Diffie-Hellman and standard VNC authentication, ZRLE/Raw/CopyRect decoding, and a direct latest-frame render path for decoded framebuffers.

## Project layout

```
KVMCore/     Shared Swift package for networking, sessions, RFB/VNC, video, input, UI, and persistence
KVMConsole/
  App/           macOS SwiftUI entry point
  UI/            macOS viewer windows
  Input/         macOS keyboard capture
  Video/         macOS video render view
  Resources/     macOS Info.plist, entitlements
KVMConsoleiPad/
  App/           iPadOS SwiftUI entry point
  UI/            iPad viewer and modifier-key controls
  Input/         iPad keyboard and pointer capture
  Video/         iPad video render view
  Resources/     iPadOS Info.plist, entitlements
KVMConsoleTests/    macOS XCTest unit tests
KVMConsoleiPadTests/  iPadOS XCTest unit tests
Scripts/         Signed/notarized macOS build pipeline
```

## Releasing

See [`DeveloperRelease.md`](DeveloperRelease.md) for the Developer ID signing and notarization workflow used by the GitHub Actions release pipeline.

## License

KVM Console for macOS and iPadOS is released under the [MIT License](LICENSE).
