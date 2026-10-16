# PrettySwiftQR — Project Plan

A single Swift package that displays and scans static and animated (fountain-coded UR) QR codes in SwiftUI,
replacing the `zeugmaster/URUI` fork and its five transitive dependencies.

Date: 2026-10-15. Status: phases 0–8 implemented (see CHANGELOG.md); phase 9 (macadamia migration) pending.

---

## 1. Goals (from the brief)

1. One package, one dependency tree. No URUI → URKit → DCBOR → Tags/Float16/NumberKit/SortedCollections chain.
2. Ergonomic payload API: the caller hands over a string or bytes and says "static", "animated", or "decide for me".
3. Reader supports static and animated codes with a single, robust `reset()`/restart story.
4. Foreground and background colours are settable.
5. Rounded modules in the style of `mblode/beautiful-qr-code`, with adjustable radii (module, inner/concave corner, finder eyes).
6. Appear/disappear content transitions ("liquid" reveal: each module grows from its centre), never between animation frames.
7. Accurate percentage for animated scans.

Non-goals for v1: logos in the centre, macOS camera scanning, non-`bytes` UR types beyond raw pass-through, CocoaPods.

---

## 2. What exists today (verified)

### 2.1 The fork
`zeugmaster/URUI` = upstream `BlockchainCommons/URUI` (head `c1b0ac2`) plus three commits:
`simple restart`, `minimal video session reset`, `async videosession start and stop`.
12 source files, roughly 600 lines, zero tests. Local clone: `~/Developer/cashu/URUI`.

Dependency chain pinned by the fork (and by macadamia):

| Package | Version | Why it is there |
|---|---|---|
| URKit | 15.0.0 (macadamia: 15.1.0) | fountain codes, bytewords, UR strings |
| BCSwiftDCBOR | 2.0.2 | CBOR value type used by URKit |
| BCSwiftTags | 0.2.3 | DCBOR dependency |
| BCSwiftFloat16 | 2.0.0 | DCBOR dependency |
| swift-numberkit | 2.6.0 | DCBOR dependency |
| SwiftSortedCollections | 0.1.0 | DCBOR dependency |

How deep is the CBOR coupling inside URKit? Shallow. It is used for exactly three things:
- the fountain part header, a fixed 5-element array `[seqNum, seqLen, messageLen, checksum, bytes(data)]`;
- `UR.cbor` storage, which the encoder only reads as raw bytes (`cborData`) and the decoder only checks "parses as CBOR";
- `UREncodable`/`URDecodable` protocols that macadamia does not use.

A roughly 80-line minimal CBOR codec (unsigned ints, byte strings, fixed-length arrays) replaces all of it.

### 2.2 How macadamia uses it (`macadamia/Misc/QRView.swift`, `QRScanner.swift`)
- Display: strings up to 600 characters go to a CoreImage static code; longer strings are wrapped as a `bytes` UR
  via `strData.cbor` and shown with `URDisplayState` at 10 fps, `maxFragmentLen: 200`.
- Scan: wires `URCodesPublisher` + `URVideoSession` + `URScanState` by hand, draws its own circular progress,
  and has an `onResult -> .valid | .retryAfter(delay)` hook that restarts the scanner after a delay.
- `restart()` must call both `scanState.restart()` and `videoSession.resetScanningState()`.
- On `.reject` the app zeroes the displayed percentage even though the decoder keeps its state.

### 2.3 Defects and limitations in the current code that the rewrite must remove
1. Two objects to reset (decoder state and the camera de-dup set); easy to get wrong, and `restart()` does not reset progress.
2. `URCodesPublisher` is `PassthroughSubject<Set<String>, Error>`; after one failure it never emits again.
3. Camera configuration runs synchronously in `URVideoSession.init` on the main actor; failures are only logged and leave the session `nil`.
4. Orientation sync uses `UIApplication.shared.windows.first!.windowScene!` and `videoOrientation`, both deprecated, both force-unwrapped.
5. Frame switching polls a 10 ms Combine timer.
6. Each frame builds a new `CIContext` and renders a bitmap; there is no access to the module matrix, so no styling is possible, and the symbol version (module count) can change between frames.
7. `progress` force-unwraps `expectedFragmentCount!`; `logger` force-unwraps `Bundle.main.bundleIdentifier`.
8. `estimatedPercentComplete` is a guess: `min(0.99, processedParts / (expectedFragments × 1.75))`. It ignores how many fragments were actually recovered and caps at 99 %.
9. Static-vs-animated policy and UR wrapping live in the app, not the library.
10. Nothing is testable without a camera (`isSupported == false` in the simulator, no injection point).

### 2.4 The rounding reference (`mblode/beautiful-qr-code`, MIT, TypeScript)
`packages/core/src/svg.ts` + `utils.ts`:
- Works on a doubled grid (one module = 2 units). Traces the outline of every connected dark region and emits an SVG
  path of straight runs and quarter-circle arcs at each turn. Convex and concave turns both get arcs; only the sweep
  flag differs. Contours are oriented (outer clockwise, holes reversed) so the nonzero rule works; even-odd gives the same result.
- `radius` is 0...1 in half-module units; `1` means fully round module ends. Below 1 the arc is padded with straight
  segments so corners stay aligned.
- The three finder patterns are removed from the matrix before tracing and drawn separately as three nested rounded
  rectangles: outer ring 7 modules at radius `max(0.5, 3·radius)` units, inner ring 5 modules at `0.7×` that, centre dot
  3 modules at `0.5×` that.
- Uses the `qrcode-generator` npm package for the matrix; no quiet zone tricks, padding is just a viewBox offset.

### 2.5 Toolchain on this machine
Xcode 26.6, Swift 6.2, iPhone 16 simulators. macadamia: iOS 17.5 deployment target, `SWIFT_STRICT_CONCURRENCY = complete`, no Mac Catalyst.

---

## 3. Decisions

| # | Decision | Rationale |
|---|---|---|
| D1 | **Vendor** the needed URKit subset and the Nayuki QR encoder port; ship a package with **zero external dependencies**. | That is the literal goal. The URKit subset is ~1,500 lines under BSD-2-Clause-Patent (notice must be kept). `fwcd/swift-qrcode-generator` v2.0.2 is 1,206 lines, MIT, pure Swift, exposes `size`, `getModule(x:y:)`, `encode(segments:ecl:minVersion:maxVersion:mask:boostECL:)`. Both are stable and small. Fallback if you prefer: keep them as the only two SPM dependencies, API is unchanged either way. |
| D2 | Stay **byte-for-byte compatible with BCR-2020-005** (bc-ur). | Other wallets/readers must keep scanning our animated codes and we theirs. Verified with URKit's own test vectors. |
| D3 | Minimum **iOS 17**; core targets also build for **macOS 14** so `swift test` runs on the Mac host. | macadamia is on 17.5. iOS 17 unlocks `@Observable`, the `Transition` protocol, `AVCaptureDevice.RotationCoordinator`, `videoRotationAngle`, Swift Testing. |
| D4 | **Swift 6 language mode, strict concurrency**, `@Observable @MainActor` models, `AsyncStream` instead of Combine. | Matches macadamia's build settings and removes the dead-publisher bug. |
| D5 | QR frames are rendered as **vector paths from the module matrix**, not bitmaps. | Required for rounding, per-module transitions, and crisp scaling. Also makes rendering testable. |
| D6 | Animated frames use a **fixed symbol version** chosen once per payload. | Module count never changes between frames, so the code never resizes or jitters. Verified feasible: all fountain parts have equal data length, so UR strings differ only in the `seqNum` digits. |
| D7 | Scan progress = **recovered fragments / expected fragments**, exact and monotonic, 1.0 only on completion. Everything else (parts seen, mixed parts pending, last indexes) is exposed alongside. | Removes the 1.75× heuristic and the 99 % cap. |
| D8 | Camera scanning uses `AVCaptureMetadataOutput` (hardware QR detection), iOS only. | Proven path for 10+ fps animated codes. Vision-based scanning for macOS can be added later behind the same `CodeSource` protocol. |

---

## 4. Package layout

```
PrettySwiftQR/
├── Package.swift                 swift-tools-version 6.0, one package, two library products
├── Sources/
│   ├── PrettyQRCore/             platform-neutral, no UIKit/SwiftUI
│   │   ├── Fountain/             vendored: FountainEncoder/Decoder, FragmentChooser, Xoshiro256, RandomSampler, CRC32
│   │   ├── UR/                   vendored+trimmed: Bytewords, UR, UREncoder, URDecoder, MiniCBOR
│   │   ├── QR/                   vendored: Nayuki port (QRCode, QRSegment, ECC, Version, Mask, BitBuffer)
│   │   ├── QRMatrix.swift        immutable bit matrix + finder/quiet-zone metadata, Hashable
│   │   ├── QRPayload.swift       the user-facing payload enum
│   │   ├── FrameSource.swift     static (one frame) or animated (fountain) frame generator with fixed version
│   │   ├── ScanDecoder.swift     camera-agnostic classifier: text vs single-part UR vs multi-part UR
│   │   └── ScanProgress.swift
│   └── PrettySwiftQR/            SwiftUI + AVFoundation; re-exports PrettyQRCore
│       ├── Style/                QRStyle, colours, radii
│       ├── Render/               QRPathBuilder (contour tracing), QRCodeShape, QRRevealModifier, QRLiquidTransition
│       ├── Display/              QRCodeView, AnimatedFrameDriver
│       ├── Scan/                 QRScanner (@Observable), CameraCodeSource, CameraPreview, QRScannerView
│       └── Widgets/              ScanProgressRing, FragmentBar (optional helpers)
├── Tests/
│   ├── PrettyQRCoreTests/        Swift Testing; URKit vectors ported; fountain round-trips; progress maths; version policy
│   └── PrettySwiftQRTests/       path builder, radius clamping, reveal maths, Vision round-trip decode of rendered codes
├── Example/                      small iOS app: show any payload, scan it with a second device, tweak style live
├── LICENSES/                     BSD-2-Clause-Patent (Blockchain Commons), MIT (Nayuki/fwcd), our own MIT
└── README.md, PLAN.md, CHANGELOG.md
```

Two products so a non-UI consumer (CLI, server, tests) can take `PrettyQRCore` alone. Scanner files are wrapped in
`#if os(iOS)`; display and rendering compile on macOS as well.

---

## 5. Public API (target shape)

### 5.1 Payloads
```swift
public enum QRPayload: Hashable, Sendable {
    case text(String)                                   // one static code, best QR mode chosen automatically
    case data(Data)                                     // one static code, byte mode
    case animated(Data, urType: String = "bytes",
                  maxFragmentLength: Int = 200)         // fountain-coded UR, cycles forever

    /// macadamia's current rule, moved into the library: static up to `staticLimit` characters, animated above.
    public static func auto(_ text: String, staticLimit: Int = 600, maxFragmentLength: Int = 200) -> QRPayload
    public static func auto(_ data: Data, ...) -> QRPayload
}
```
Static payloads that exceed QR capacity (2,953 bytes in byte mode at level L) do not crash; `QRCodeView` shows an
error placeholder and `FrameSource` throws `QRPayloadError.tooLarge(bytes:limit:)`.

### 5.2 Display
```swift
QRCodeView(.auto(tokenString))
    .qrStyle(QRStyle(
        foreground: .black, background: .white,
        moduleRadius: 0.5,          // 0...0.5 module units, convex corners
        innerRadius: 0.5,           // concave fillets between touching modules, 0 disables
        finderRadius: .init(outer: 1.5, inner: 1.0, center: 0.75),   // module units
        quietZone: 2,               // modules
        errorCorrection: .automatic // L for animated, M for static
    ))
    .qrFrameRate(10)                // animated only
    .qrReveal(.liquid(stagger: .fromCenter, duration: 0.6))   // or .none, .fade
```
`QRCodeView` is identity-stable across frames; changing the payload runs the disappear transition then the appear
transition (configurable to cross-fade or cut). The view pauses animation when off-screen or when the scene is in
the background and resumes from the first part on reappear. A `QRCodeShape` is also public for custom compositions,
and `QRCodeImageRenderer` exports a `CGImage`/`Image` at a requested pixel size for sharing.

### 5.3 Scanning
```swift
@Observable @MainActor
public final class QRScanner {
    public enum State: Equatable { case idle, requestingAccess, unauthorized, unavailable, scanning, completed(ScanResult), failed(ScanError) }
    public private(set) var state: State
    public private(set) var progress: ScanProgress?     // nil until a multi-part UR is seen
    public var configuration: Configuration             // accepts: [.text, .ur], rescanInterval, staleTimeout, camera position, torch

    public init(configuration: Configuration = .init(), source: any CodeSource = CameraCodeSource())
    public func start() async      // requests access, configures session off-main, begins delivery
    public func stop()
    public func reset()            // ONE call: decoder, de-dup table, progress, state → .scanning if running
    public func resume(after delay: Duration) async   // macadamia's `.retryAfter`
}

public struct QRScannerView: View {
    public init(scanner: QRScanner)                    // full control
    public init(onResult: @escaping (ScanResult) -> Void)   // convenience: owns a scanner, start/stop on appear/disappear
}

public enum ScanResult: Equatable, Sendable {
    case text(String)
    case ur(URPayload)        // type + raw CBOR; `.bytes` and `.text` conveniences for ur:bytes
}

public struct ScanProgress: Equatable, Sendable {
    public let expectedFragments: Int
    public let receivedFragments: Int          // unique source fragments recovered
    public let processedParts: Int             // parts accepted by the decoder (duplicates excluded)
    public let pendingMixedParts: Int          // mixed parts held but not yet reducible
    public let lastFragmentIndexes: Set<Int>   // for the fragment bar
    public var fraction: Double { Double(receivedFragments) / Double(expectedFragments) }
    public var isComplete: Bool
}
```
`CodeSource` is a protocol with one requirement, `func codes() -> AsyncStream<ScannedCode>`; the camera implements
it, tests and previews use `ArrayCodeSource`/`ScriptedCodeSource`.

---

## 6. Design details per feature

### 6.1 Core codec (vendored URKit subset)
- Copy `Fountain/*`, `Bytewords.swift`, `UR/UR.swift`, `UR/UREncoder.swift`, `UR/URDecoder.swift`, CRC32 from `Utils.swift`.
- Replace `CBOR` with `MiniCBOR`: `encodeUnsigned`, `encodeBytes`, `encodeArrayHeader`, and a decoder for the fixed
  part header plus "one byte string" (for `ur:bytes`). `UR.cbor` becomes `Data`. Unknown UR types are passed through
  as raw CBOR bytes; the caller may decode them with any CBOR library.
- Keep Blockchain Commons' license header in every copied file, add `LICENSES/` and a NOTICE paragraph in README.
- Tests: port `FountainCodesTests` (17 tests), `BytewordsTests` (2), `URTests` (3) verbatim; add a fixture file with
  UR strings generated by real URKit 15.1 for three payload sizes so compatibility is pinned without a dev dependency.

### 6.2 QR matrix encoding (vendored Nayuki port)
- `QRMatrix` wraps the encoder output: `size`, `isDark(x,y)`, `isFinder(x,y)`, `version`.
- `FrameSource.animated` computes the worst-case part string once (largest `seqNum` digit count the session will
  reach, say up to 9999 parts) and fixes `minVersion = maxVersion` for every frame. UR text uppercased is entirely in
  the alphanumeric set (A–Z, 0–9, `:`, `/`, `-`), so `QRSegment.makeSegments` picks alphanumeric mode: ~45 % more
  capacity than byte mode and visibly smaller frames than CoreImage produces today.
- Default error correction: L for animated (capacity matters), M for static; both overridable.
- Tests: version policy is stable across 500 generated parts; alphanumeric mode is chosen for UR text; capacity
  overflow throws; decodability round-trip (rasterise matrix → `VNDetectBarcodesRequest` → equals input) on macOS.

### 6.3 Rounded rendering (`QRPathBuilder`)
- Port the contour-tracing algorithm from `svg.ts` to Swift producing a `Path`. Work on the doubled grid like the
  original; convert `moves` to `addLine`/`addArc(tangent1End:tangent2End:radius:)`. Fill with the default nonzero rule so overlapping modules of a running reveal union.
- Split the single `radius` into `moduleRadius` (convex) and `innerRadius` (concave); both clamp to `0...0.5` module.
  `innerRadius = 0` reproduces the look of most "rounded dots" renderers; equal radii reproduce beautiful-qr-code.
- Finder eyes: drawn separately exactly as the reference (7/5/3 module nested rounded rects, middle ring reversed so it is a hole under nonzero), with the three
  radii exposed. Finder cells are excluded from tracing.
- Quiet zone is part of the path's coordinate space so the background colour covers it.
- Cache: `[QRMatrix.hash + style.hash → Path]`, small LRU (animated codes revisit the first `seqLen` parts constantly).
- Tests: path element counts for a 1-module and 2×2 fixture at radius 0 and 0.5; radii clamp; finder exclusion;
  Vision decode of rendered codes at radius 0, 0.25, 0.5 with inner fillets on and off, versions 2, 10 and 20.

### 6.4 Static and animated display
- `AnimatedFrameDriver`: an actor-isolated `Task` loop using `ContinuousClock.sleep` at the configured frame rate;
  publishes `currentMatrix`. No timer polling. Stops when the view disappears or `scenePhase != .active`.
- Frame updates are applied inside `withTransaction(Transaction(animation: nil))`; the matrix is not part of any
  `animatableData`, so SwiftUI cannot interpolate it even if the parent animates.
- Frame rate default 10 fps, `maxFragmentLength` default 200, mirroring macadamia's proven settings.
- Display-side progress: `seqNum`, `seqLen`, `lastFragmentIndexes` exposed for an optional `FragmentBar`.

### 6.5 Liquid reveal transition
- `QRCodeShape: Shape` with `animatableData = reveal` (0...1), `matrix` and `style` non-animatable.
  - `reveal == 1`: the merged contour path (6.3).
  - `reveal < 1`: each dark non-finder module drawn as its own rounded square scaled by
    `s = clamp((reveal − delay(module)) / span, 0, 1)` about its centre; `delay` grows with normalised distance from
    the symbol centre (ripple). Finder eyes scale as three whole units. Concave fillets are drawn as separate small
    pieces with opacity `reveal^3` so nothing pops when cells touch.
- `QRRevealModifier: ViewModifier, Animatable` injects `reveal` via the environment; `QRLiquidTransition: Transition`
  (iOS 17) applies it with `0` for `.willAppear`/`.didDisappear` and `1` for `.identity`. Also exposed as
  `AnyTransition.qrLiquid` for callers who prefer the older API.
- Disappear runs the ripple inward (reverse stagger) so removal reads as the mirror of insertion.
- Guarantee "not between frames": the transition is keyed to view identity, and `QRCodeView` keeps a stable identity
  for the lifetime of a payload. Payload change is the only identity change.
- Implementation note (2026-10-16): `QRCodeView` drives insertion and payload swaps itself (each symbol starts at
  `reveal` 0 and grows under `withAnimation`); only removal uses the transition. A symbol inserted after the
  transition's environment jump has nothing to interpolate and pops in (observed on iOS 26), and `.id`-keyed swaps
  with the transition were unreliable.
- Budget: version-20 code (97×97) must build its per-cell path under 2 ms on an iPhone 12-class device so the
  reveal stays at 60 fps; measured in the example app's debug overlay.

### 6.6 Scanner
- `CameraCodeSource` owns `AVCaptureSession`, configures it on a private serial queue, `startRunning` off-main,
  requests access with `AVCaptureDevice.requestAccess(for: .video)`, uses `RotationCoordinator` for preview rotation,
  and yields `ScannedCode(value:, bounds:, timestamp:)` into an `AsyncStream`. Unavailable camera (simulator, no device)
  becomes `.unavailable`, never a silent `nil`.
- `CameraPreview` is a `UIViewRepresentable` whose `UIView.layerClass` is `AVCaptureVideoPreviewLayer`, so layout is
  automatic and the legacy window-scene lookup disappears.
- De-dup and re-scan policy, replacing `lastFound`: per code value, deliver on first sight and again only after
  `rescanInterval` (default 1 s). Duplicate UR parts are cheap and the decoder discards them anyway.
- `ScanDecoder` state machine (pure, in Core, fully unit-tested):
  - `.empty` → non-UR code → `.text` result; single-part UR → `.ur` result; multi-part → `.collecting(decoder)`.
  - `.collecting` → matching part → progress update; stray text or a UR with a different type/checksum/seqLen →
    `rejected` event (observable for debugging) but **progress untouched**; if `staleTimeout` elapses with no accepted
    part → automatic `reset()` and a `timedOut` event.
  - completion → `.completed`; further codes are ignored until `reset()` or `resume(after:)`.
- Lifecycle: `QRScannerView` starts on appear, stops on disappear and on `scenePhase == .background`, resumes on
  `.active`. `reset()` is idempotent and safe from any state.
- Tests drive the whole pipeline with `ScriptedCodeSource`: in-order, shuffled, duplicated, interleaved with stray
  text, interleaved with a second UR, restart mid-way, stale timeout, static code re-scan after `reset()`.

### 6.7 Accurate progress
- `ScanProgress.fraction = receivedFragments / expectedFragments`, computed from the decoder after every accepted
  part. It is exact (number of source fragments known), monotonic, and equals 1.0 exactly when the decoder completes.
- `processedParts` and `pendingMixedParts` are exposed for richer UI (for example, "12 of 20 fragments, 3 mixed parts
  waiting"). `lastFragmentIndexes` drives the fragment bar.
- Tests: fraction never decreases; a rejected code does not change it; shuffled input reaches 1.0 at the same
  `receivedFragments == expectedFragments` moment the result appears; display-side `seqLen` equals scan-side
  `expectedFragments` for the same payload.

---

## 7. Phases and acceptance criteria

| Phase | Deliverable | Done when |
|---|---|---|
| 0. Scaffold | Package manifest, targets, licenses, CI script (`swift test` on macOS, `xcodebuild test` on iPhone simulator), README skeleton | Empty targets build in Swift 6 strict mode on both platforms |
| 1. Core codec | Vendored fountain/bytewords/UR with MiniCBOR | All 22 ported URKit tests pass; fixture URs from URKit 15.1 decode; our output decodes in URKit (checked once with a throwaway script, recorded in fixtures) |
| 2. Matrix | Vendored Nayuki port, `QRMatrix`, `FrameSource` with fixed-version policy | Vision round-trip passes for static and 100 animated frames; version constant across frames |
| 3. Rendering | `QRStyle`, `QRPathBuilder`, `QRCodeShape`, static `QRCodeView`, image export | Vision decodes styled output at all tested radii; previews for light/dark and custom colours |
| 4. Animated display | `AnimatedFrameDriver`, animated `QRCodeView`, pause/resume, payload switching | Device test: a second phone running the old macadamia scanner reads it; no resize between frames |
| 5. Transitions | Reveal shape mode, modifier, `Transition`, stagger options | Reveal at 60 fps on version 20; frame changes verifiably never animate (test that `reveal` stays 1 across 50 frame updates) |
| 6. Scanner | `QRScanner`, `CameraCodeSource`, preview, `QRScannerView`, scripted source | Scripted pipeline tests pass; device test: static re-scan after reset, animated scan completes, stale timeout resets |
| 7. Progress UI | `ScanProgress`, `ScanProgressRing`, `FragmentBar` | Progress tests in 6.7 pass; ring reaches 100 % exactly on completion |
| 8. Example + docs | Example app, README with migration guide from URUI, DocC comments on public API | A new consumer can integrate display and scan from the README alone |
| 9. Migration | Replace `QRView`/`QRScanner` in macadamia with the package | macadamia builds with URUI/URKit removed from `Package.resolved`; the six old pins are gone |

Phases 1–3 and 6 (core, matrix, rendering, scan decoder) are independent and can run in parallel; 4 needs 2, 5 needs
3, 7 needs 6.

---

## 8. Risks and mitigations

- **Scannability of heavy rounding.** Fully round modules at radius 0.5 with inner fillets are known to scan, but
  tiny modules on low-end cameras could suffer. Mitigation: default radius 0.4, Vision round-trip tests at every
  radius, and a documented recommendation for animated codes (radius ≤ 0.4, quiet zone 2).
- **Alphanumeric mode changes frame appearance** versus CoreImage output other wallets are used to. Pure capacity win,
  no protocol change; the decoded string is identical.
- **Per-cell path cost during the reveal** on large symbols. Mitigation: pre-build cell centres once per matrix,
  reuse `Path` for the cell shape with a transform, measure in phase 5.
- **`AVCaptureMetadataOutput` frame drop under load** when the preview is large. Mitigation: `sessionPreset = .hd1280x720`,
  metadata queue at `.userInteractive`, no per-frame allocation in the delegate.
- **License hygiene.** Vendored code keeps its headers; the package license file lists all three licenses.

---

## 9. Open questions (assumptions made in this plan)

1. Zero external dependencies via vendoring (D1) versus depending on the two small packages. Plan assumes vendoring.
2. iOS 17 minimum (D3). If older devices matter, transitions fall back to `AnyTransition.modifier` and the scanner
   loses `RotationCoordinator`; the rest is unaffected.
3. Package and module names: `PrettySwiftQR` (umbrella) and `PrettyQRCore`. Rename is trivial before phase 0.
4. Whether `QRCodeView` should default to the liquid reveal or to no transition. Plan assumes liquid on by default.
5. Logo overlay support is out of scope for v1; the style struct leaves room for it.
