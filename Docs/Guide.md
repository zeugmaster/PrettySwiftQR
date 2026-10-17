# PrettySwiftQR guide

Everything the README leaves out. Start with the [README](../README.md) for the basics.

## Payloads

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

## Styling

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

## Transitions

`QRCodeView` appears when inserted and disappears when removed; changing the payload runs both
at once. The default reveal is liquid: the code behaves like mercury. To disappear it melts
into drops that are pulled apart toward invisible magnets, merge with whatever arrived there
and sink; neighbouring drops stay joined by threads that stretch, snap and recoil. Appearing
is the same film backwards. The code can also flow into a shape and back:

```swift
QRCodeView(.text(invoice))
    .qrMorph(isPaid ? .checkmark : nil)          // flows into a tick, and back when nil
```

Drops land along the target's stroke in proportion to their mass, so the shape is complete
only when the last drop has arrived. An animated code holds its frame while morphed and plays
on once it is back.

### Your own shapes

A target is a stroke of constant width along a polyline, with round ends and corners:

```swift
extension QRMorphTarget {
    static let chevron = QRMorphTarget(
        points: [QRPoint(0.40, 0.25), QRPoint(0.65, 0.50), QRPoint(0.40, 0.75)],
        lineWidth: 0.156)
    static let dash = QRMorphTarget(points: [QRPoint(0.25, 0.5), QRPoint(0.75, 0.5)], lineWidth: 0.12)
}

QRCodeView(.text(invoice))
    .qrMorph(status == .paid ? .checkmark : status == .waiting ? .dash : nil)
```

- Points are in unit coordinates of the symbol: (0, 0) is the top-left module corner, (1, 1)
  the bottom-right, y points down. Keep them within about 0.1…0.9; the quiet zone is outside.
- Two to eight points; for a closed outline repeat the first point at the end.
- `lineWidth` is a fraction of the symbol's side (0.02…0.5); `.checkmark` uses 0.156.
- Switching from one shape to another flows back into the code first, then into the new one.
- One connected stroke per target: shapes in several parts (✕, "!") are not supported yet.

### Durations

```swift
let reveal = QRReveal.liquid(.default, duration: 0.9)   // appearing and payload swaps (default 1.2 s)

ZStack { if isShown { QRCodeView(payload) } }
    .qrReveal(reveal)
    .animation(reveal.animation, value: isShown)          // disappearing: removal uses your animation
    .qrMorph(isPaid ? .checkmark : nil, duration: 1.2)    // morph and way back (default 1.6 s)
```

Removal is animated by whatever animation the state change carries, so use `reveal.animation`
(linear): every drop eases on its own, and an extra ease on top reads as separate phases.
`stagger` does not change the total time, only how much of it each drop spends moving.

### Parameters

The liquid has three parameters:

```swift
QRCodeView(.auto(token))
    .qrReveal(.liquid(QRLiquidStyle(
        tension: 0.26,      // how far apart two bodies still join through a neck, in modules (0…0.6)
        stagger: 0.55,      // how far the drops' timing is spread (0.1…0.9)
        dropsPerSide: 7     // how many drops the code is cut into per side (4…12)
    ), duration: 1.2))
    .qrMorph(.checkmark, duration: 1.6)
```

### How it is drawn

The liquid is drawn with a Metal shader that is compiled at runtime the first time a code
loads (about 0.1 s, off the main thread), so consumers need no Metal toolchain. It runs only
while a transition is in flight and starts and ends on the resting outline, so handing over to
the vector `QRCodeShape` at rest is invisible. Where Metal is unavailable the growing reveal
runs instead. Other reveals:

```swift
    .qrReveal(.grow)    // every module grows from its centre
    .qrReveal(QRReveal(order: .fromCenter, stagger: 0.55, overshoot: 0.12, duration: 0.7))
    .qrReveal(.none)    // plain cross-fade
```

The liquid was designed in a browser prototype, kept in `Prototypes/LiquidLab` together with
the tools that check the Swift port against it frame by frame.

### Custom layouts

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

## Export

```swift
let image = try QRCodeImageRenderer.image(for: .text(url), style: style, pixelSize: 1024)
let svg = try QRCodeImageRenderer.svg(for: .text(url))
```

## Scanning

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

## Inspecting transitions

Launched with `-liquidDemo`, the display tab loops every liquid effect on its own (appear,
morph and back, disappear, payload swaps, an animated code morphing), for screen recordings.

The example's UI test (`PrettySwiftQRExampleUITests`) toggles the code and swaps payloads
while taking screenshots every ~65 ms, so the reveal can be inspected frame by frame. Set
`TEST_RUNNER_REVEAL_CAPTURE_DIR=/some/dir` with `xcodebuild test` to get the PNGs on disk.
