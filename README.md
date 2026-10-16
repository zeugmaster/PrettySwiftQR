# PrettySwiftQR

Static and animated QR codes for SwiftUI, in one dependency-free Swift package.

- **Display** any payload: short strings become one code, long ones become an animated
  fountain-coded sequence (`ur:bytes`, [BCR-2020-005](https://github.com/BlockchainCommons/Research/blob/master/papers/bcr-2020-005-ur.md)).
- **Scan** both kinds with one object and one `reset()`, with exact progress for animated codes.
- **Style** colours, rounded modules and finder eyes with adjustable radii, in the spirit of
  [beautiful-qr-code](https://github.com/mblode/beautiful-qr-code).
- **Reveal** codes with a liquid transition: every module grows from its centre into place.
  Frames of an animated code never animate.

Requires iOS 17 or macOS 14 (display only on macOS), Swift 6. Scanning uses the camera on iOS.

## Install

```swift
.package(url: "https://github.com/zeugmaster/PrettySwiftQR", from: "0.1.0")
```

Products: `PrettySwiftQR` (SwiftUI views + scanner, re-exports the core) and `PrettyQRCore`
(encoding, fountain codes, geometry; no UI, builds anywhere).

## Display

```swift
import PrettySwiftQR

QRCodeView(auto: token)                     // static ≤ 600 bytes, animated above
    .qrStyle(.rounded(0.45))                // module radius 0…0.5, finder radii derived
    .qrColors(foreground: .black, background: .white)
    .qrFrameRate(10)                        // animated codes only
    .frame(width: 260)
```

Payloads are explicit values:

```swift
QRCodeView(.text("https://example.com"))                  // one static code
QRCodeView(.data(bytes))                                  // static, byte mode
QRCodeView(.animated(bytes, maxFragmentLength: 200))      // fountain-coded ur:bytes
QRCodeView(.ur(someUR))                                   // any UR
QRCodeView(.auto(string, staticLimit: 600))               // decide by size
```

Animated sequences use one fixed symbol version chosen up front, so the module grid never
jumps between frames. Uppercased UR text fits QR alphanumeric mode, which makes frames
noticeably smaller than CoreImage's byte-mode output for the same data.

### Styling

```swift
view.qrStyle(QRStyle(
    foreground: .black, background: .white,
    radii: QROutlineRadii(
        module: 0.5,        // convex corners, 0 square … 0.5 fully round (module units)
        inner: 0.5,         // concave fillets where modules touch; 0 for classic dots
        finderOuter: 1.5,   // 7×7 eye
        finderInner: 1.05,  // 5×5 light ring
        finderCenter: 0.75  // 3×3 centre
    ),
    quietZone: 2))
```

`QROutlineRadii.derived(module:)` reproduces beautiful-qr-code's finder proportions from a
single module radius. All radii clamp to their geometric maximum. Rounded output at every
radius is verified to decode with Vision in the test suite.

### Transitions

`QRCodeView` reveals itself when inserted and dissolves when removed; changing the payload
runs the same effect. Configure or disable it with `.qrReveal(_:)`:

```swift
QRCodeView(.auto(token))
    .qrReveal(QRReveal(order: .fromCenter, stagger: 0.55, overshoot: 0.12, duration: 0.7))
    .qrReveal(.none)   // plain cross-fade instead
```

For your own layouts, `QRCodeShape` is an animatable `Shape` (only `reveal` interpolates), so
`withAnimation { reveal = 1 }` grows the modules into place; that is how `QRCodeView` swaps
payloads and reveals itself when inserted. `.transition(.qrReveal)` animates the `qrReveal`
environment value when a view is inserted or removed. Read it with `@Environment(\.qrReveal)`
in a small view that builds the shape, and apply the transition to a container holding that
view, as `QRCodeView` does for its removal:

```swift
if isShown {
    ZStack { MySymbol(matrix: matrix) }   // MySymbol reads @Environment(\.qrReveal)
        .transition(.qrReveal)
}
```

Applying the transition to the reading view itself makes SwiftUI jump the value without
animating, and reading it above the transition sees only the static value. The shape must
already exist when the container is inserted; one added a moment later (after a state change
or a load) sees the identity value and pops in, so grow it with `withAnimation` instead.

### Export

```swift
let image = try QRCodeImageRenderer.image(for: .text(url), style: style, pixelSize: 1024)
let svg = try QRCodeImageRenderer.svg(for: .text(url))
```

## Scan

```swift
QRScannerView { result in
    switch result {
    case .text(let string): handle(string)
    case .ur(let ur): handle(ur.utf8String ?? "")   // ur:bytes → text
    }
}
```

For full control own the scanner:

```swift
@State private var scanner = QRScanner(configuration: .init(
    decoder: .init(acceptsText: true, acceptsUR: true, staleTimeout: .seconds(8)),
    rescanInterval: .seconds(1)))

QRScannerView(scanner: scanner) { scanner in
    VStack {
        FragmentBar(progress: scanner.progress)
        ScanProgressRing(progress: scanner.progress, state: scanner.state) { scanner.reset() }
    }
}
.onChange(of: scanner.state) { _, state in
    if case .completed(let result) = state { /* … */ }
}
```

- `scanner.state`: `.idle`, `.starting`, `.unauthorized`, `.unavailable`, `.scanning`,
  `.completed(result)`, `.failed(error)`.
- `scanner.progress`: exact `receivedFragments / expectedFragments`, plus parts seen, mixed parts
  pending and the fragments in the last frame. 100 % exactly when the message is complete.
- `scanner.reset()` clears everything in one call. `scanner.resume(after:)` waits, then resets.
- Stray codes never disturb a collection in progress; `staleTimeout` abandons one that stalls.
- The same static code is delivered again after `rescanInterval`, or immediately after `reset()`.

Scanning without a camera: `QRScanner(source: ScriptedCodeSource(payload: payload))` replays
the frames `QRCodeView` would show; `ManualCodeSource` lets you push strings by hand. The
camera is `CameraCodeSource`; it configures and starts off the main thread, handles rotation,
and exposes torch and camera switching.

## Core without UI

```swift
import PrettyQRCore

let encoder = try QRFrameEncoder(payload: .animated(data))
let matrix = try encoder.nextFrame()          // QRMatrix: modules, version, finders
let svg = QROutline.svg(matrix)               // styled outline as SVG

let decoder = ScanDecoder()
for code in scannedStrings { if case .completed(let r) = decoder.receive(code) { … } }
```

The UR implementation is vendored from URKit with its CBOR dependency replaced by an 80-line
codec; the test suite includes URKit's own vectors and fixtures generated by URKit 15.1, so
output stays byte-compatible with other BCR-2020-005 readers and writers.

## Migrating from URUI

| URUI | PrettySwiftQR |
|---|---|
| `URDisplayState(ur:maxFragmentLen:)` + `URQRCode(data:)` + `run()`/`stop()` | `QRCodeView(.animated(data, maxFragmentLength:))`; playback follows view lifecycle |
| CoreImage static code | `QRCodeView(.text(string))` |
| App-side 600-character rule | `QRCodeView(.auto(string))` |
| `URCodesPublisher` + `URVideoSession` + `URScanState` | `QRScanner` (+ `QRScannerView`) |
| `URScanResult.ur / .other / .progress / .reject / .failure` | `ScanResult.ur / .text`, `scanner.progress`, `scanner.lastRejection`, `.failed` state |
| `scanState.restart()` **and** `videoSession.resetScanningState()` | `scanner.reset()` |
| `estimatedPercentComplete` (heuristic, caps at 99 %) | `progress.fraction` (exact) |
| `URFragmentBar` / `URProgressBar` | `FragmentBar` / `ScanProgressRing` |
| `UR(type: "bytes", cbor: data.cbor)` | `UR(bytes: data)`, `ur.bytes`, `ur.utf8String` |

## Example app

`Example/` contains an iOS app with live style controls, transition demos, camera scanning and
a scripted scan for the simulator. The project is generated, not checked in:

```sh
cd Example && xcodegen generate && open PrettySwiftQRExample.xcodeproj
```

The example's UI test (`PrettySwiftQRExampleUITests`) toggles the code and swaps payloads
while taking screenshots every ~65 ms, so the reveal can be inspected frame by frame. Set
`TEST_RUNNER_REVEAL_CAPTURE_DIR=/some/dir` with `xcodebuild test` to get the PNGs on disk.

## Licenses

MIT for this package. Vendored code keeps its own license: URKit (Blockchain Commons,
BSD-2-Clause Plus Patent) under `Sources/PrettyQRCore/Fountain` and `UR`, and
swift-qrcode-generator / Project Nayuki (MIT) under `Sources/PrettyQRCore/QR`. See `LICENSES/`.
