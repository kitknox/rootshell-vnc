# rootshellVNC

`rootshellVNC` is a native Swift VNC client for Apple platforms. It combines an
RFB protocol implementation, secure transports, Apple Screen Sharing support,
hardware-accelerated rendering, and a reusable SwiftUI remote-desktop UI.

This is the VNC package used by [rootshell](https://github.com/kitknox/rootshell),
the terminal app for iPhone, iPad, visionOS, and macOS. rootshell embeds this
package to provide remote graphical desktop access alongside its terminal and
SSH workflows. The rootshell repository remains the place for app-level
information and support; this repository contains the VNC implementation and a
small standalone viewer used to develop it.

## Features

### VNC and RFB

- RFB 3.3, 3.7, and 3.8 protocol negotiation, plus Apple's RFB extensions
- Raw, CopyRect, Zlib, ZRLE, Tight, Apple Adaptive DCT, and Apple HEVC display
  paths, selected according to the configured quality mode and server support
- Standard cursor, desktop-size, and extended-desktop-size extensions
- Extended clipboard with UTF-8 text, RTF, HTML, and images, falling back to
  plain text on servers without it
- Configurable pixel format, encoding preference, and frame-request rate
- One display, combined physical displays, or two client-sized virtual displays
  on capable Apple servers

### Apple Screen Sharing

- High Performance mode with low-latency HEVC video over UDP
- Standard adaptive and lossless Full Quality modes over TCP
- Remote system audio with synchronized audio/video playback
- Match Client sizing and live display reconfiguration
- Apple precise scrolling and native gesture events, with portable RFB fallbacks
- Shared and manual clipboard transfers that keep images and rich text
- Remote curtain control and Apple login-window detection with an explicit
  user-confirmed password-send flow

### Security and transport

- Classic VNC authentication
- Apple Remote Desktop authentication, including Apple DH and Mac/SRP flows
- VeNCrypt 0.2 with X.509 TLS and host-supplied certificate validation for
  trust-on-first-use policies
- Configurable security policy, including an encryption-required mode
- Direct TCP connections or a host-provided `RFBConnection`, allowing the
  package to run through an SSH direct-tcpip channel, tssh tunnel, or another
  application-owned transport
- Encrypted Apple control and media channels, including SRTP/SRTCP support

### Native client experience

- `VNCSession`, an observable high-level API for connection lifecycle, display
  state, input, clipboard, resizing, reconnection, and statistics
- Reusable `ConnectionView` and `RemoteDesktopView` SwiftUI components
- `RemoteScreenView`, which gives another protocol's video the same input,
  zoom, and HUD as `RemoteDesktopView`, with optional physical-key forwarding
- Touch, mouse, trackpad, and Apple Pencil input for pointer movement, clicking,
  dragging, scrolling, hover, and gestures
- Software and hardware keyboard capture with host-reserved shortcut routing
- Zooming, panning, viewport controls, fullscreen integration, and keyboard-aware
  layout
- Automatic reconnection with bounded exponential backoff and jitter
- Protocol tracing, structured debug logging, connection diagnostics, and live
  session statistics

## Package structure

The Swift package manifest, sources, and tests live at the repository root.

| Product | Responsibility |
| --- | --- |
| `rootshellVNC` | Public session API, SwiftUI views, input, clipboard, and diagnostics |
| `RFBProtocol` | RFB types, messages, state machine, and framebuffer encoding decoders |
| `RFBTransport` | TCP/UDP I/O, authentication, encryption, tunneling hooks, and Apple media negotiation |
| `RFBRendering` | Framebuffer composition, cursor rendering, VideoToolbox HEVC decoding, and remote audio |

[`Examples/rootshell-vnc`](Examples/rootshell-vnc) contains a lightweight
standalone viewer and integration harness. Its Xcode project uses the repository
root as a local package, so changes to the library are immediately available to
the viewer.

## Requirements

- Swift 6
- iOS 18 or later for the package
- macOS 15 or later for the package

The standalone viewer currently has an iOS and iPadOS 26.2 deployment target
and also supports Mac Catalyst. It therefore requires an Xcode installation
with the corresponding platform SDK, even though the reusable package supports
the older OS versions above.

The package uses system frameworks including SwiftUI, Network, VideoToolbox,
Core Media, and AVFoundation. Its external Swift dependencies are BigInt,
SwiftNIO, SwiftNIO SSL, and SwiftNIO Transport Services.

## Add the package to an app

In Xcode, choose **File → Add Package Dependencies** and enter:

```text
https://github.com/kitknox/rootshell-vnc.git
```

Add the `rootshellVNC` product to the application target. The DCT decoder uses
normal Debug and Release build settings starting in `0.1.3`, so that version and
later support semantic-version requirements. Tags through `0.1.2` still contain
the old unsafe build flags.

```swift
dependencies: [
    .package(
        url: "https://github.com/kitknox/rootshell-vnc.git",
        from: "0.1.3"
    ),
],
targets: [
    .target(
        name: "MyApp",
        dependencies: [
            .product(name: "rootshellVNC", package: "rootshell-vnc"),
        ]
    ),
]
```

For local development, clone the repository and add its root as a local Swift
package in Xcode:

1. Choose **File → Add Package Dependencies**.
2. Choose **Add Local…**.
3. Select the `rootshell-vnc` repository root.
4. Add the `rootshellVNC` product to the application target.

A neighboring Swift package can use the same checkout by path:

```swift
dependencies: [
    .package(path: "../rootshell-vnc"),
],
targets: [
    .target(
        name: "MyApp",
        dependencies: [
            .product(name: "rootshellVNC", package: "rootshell-vnc"),
        ]
    ),
]
```

## Quick start

For a complete connection form and remote-desktop flow, create a session and
pass it to `ConnectionView`:

```swift
import SwiftUI
import rootshellVNC

@MainActor
struct VNCClientView: View {
    @State private var session = VNCSession()

    var body: some View {
        ConnectionView(session: session)
    }
}
```

For an app-owned connection flow, configure and connect the session directly,
then present `RemoteDesktopView`:

```swift
var configuration = VNCConfiguration(
    videoQualityMode: .adaptive,
    displaySizingMode: .matchClient
)
configuration.securityPolicy = .automatic

let session = VNCSession(configuration: configuration)

try await session.connect(
    credentials: VNCCredentials(
        host: "mac.example.com",
        password: "password",
        username: "username"
    )
)
```

```swift
RemoteDesktopView(session: session)
```

Use `.standard` for a reliable compressed TCP path on constrained, tunneled, or
UDP-hostile networks, and `.fullQuality` for lossless framebuffer updates on a
fast network. High Performance `.adaptive` mode requires direct UDP reachability
and is automatically unavailable when a custom transport provider is installed.

## Developing

Open `Examples/rootshell-vnc/rootshell-vnc.xcodeproj` to run the standalone
viewer, or build and test the package from the repository root:

```sh
swift test
```

Both rendering targets use the normal configuration defaults, without unsafe
optimization flags. The Adaptive DCT decoder borrows buffers once per rectangle,
reuses coefficient storage, and uses DC and constant-chroma kernel shortcuts.
Release builds are still faster than unoptimized Debug builds.

Run the deterministic offline Retina workloads in both configurations:

```sh
VNC_DCT_BENCHMARK=1 swift test --filter AppleDCTPerformanceTests
VNC_DCT_BENCHMARK=1 swift test -c release --filter AppleDCTPerformanceTests
```

The benchmark reports median decode time after warm-up, excluding stream
construction. `draw=false` suppresses DCT pixel generation; the existing
solid/palette/copy commands still render. Pixel fixtures, truncated streams,
cache wraparound, resize, and quantization changes run without the environment
flag. Kernel golden checks exercise native and portable scalar implementations
at both `-O0` and `-O3`, including extreme coefficients:

```sh
Tools/Diagnostics/check_apple_dct_kernel.sh --sanitize
swift test --sanitize=address --filter 'AppleDCTPerformanceTests|AppleAdaptiveDCTDecoderTests'
```

The test suites cover protocol parsing and state transitions, authentication and
crypto, TCP/UDP transport behavior, Apple media negotiation and resiliency,
frame ordering and decoding, clipboard synchronization, viewport behavior, and
reconnection.

### Standard-mode network benchmark

The opt-in live benchmark runs Standard adaptive DCT through a deterministic,
unprivileged loopback conditioner. It covers baseline, good WAN, typical WAN,
and adverse WAN profiles while reporting update cadence, bandwidth, decoder
time, DCT base/refinement mix, and simulated recovery events. Packet loss is
modeled as a TCP head-of-line retransmission stall, so the conditioner never
discards or corrupts bytes in the RFB stream.

Every transport run also evaluates 0, 8, 16, 25, 33, and 50 ms presentation
holds against the same DCT event stream. The `TRADEOFF` records report the
client delay, fully refined frame rate, and refined rectangle-area percentage
for each candidate.

```sh
export VNC_TEST_HOST=192.0.2.10
export VNC_TEST_USERNAME=test-user
export VNC_TEST_PASSWORD='test-password'
Tools/Diagnostics/run_standard_network_matrix.sh
```

Set `VNC_NETWORK_SCENARIOS=baseline,typical-wan` to select profiles,
`VNC_PROBE_SECONDS=20` for longer samples, or `VNC_NETWORK_MATRIX_OUT` to choose
the result directory. Each profile also measures the app-level image publication
cadence; set `VNC_PROBE_INCLUDE_PRESENTATION=0` for a transport-only run. The
`VNC_PROBE_PRESENTATION_HOLDS=8,16,25` setting runs app-level A/B samples for
multiple holds; use `default` in that list to exercise the production policy
without an override. `VNC_PROBE_INCLUDE_TRANSPORT=0` skips the transport probe
when only app-level presentation comparisons are needed. The script keeps
credentials in the environment and does not write them to source or result
files.

## Related project

- [rootshell](https://github.com/kitknox/rootshell) — the free,
  Metal-accelerated terminal app that uses this package
- [rootshell.com](https://www.rootshell.com) — downloads, screenshots, release
  notes, and documentation for the rootshell app

## Cursor artwork

Remote cursor images come from the connected server. The client preserves their
shapes and hotspots; it does not bundle extracted macOS cursor artwork. An original
vector arrow is the fallback before a trackpad session receives its first cursor.

The original arrow and text-caret paths live in
`Sources/rootshellVNC/Views/TrackpadCursorArtwork.swift` and are covered by the
repository's MIT license. The app renders the vectors at the display's pixel density.

## License

rootshellVNC is available under the [MIT License](LICENSE).
