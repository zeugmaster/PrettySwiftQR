# Changelog

## Unreleased

- Liquid transitions, now the default reveal (`QRReveal.liquid`): the code behaves like mercury.
  It melts into drops that pull apart toward invisible magnets and sink, gathers back the same
  way, and with `.qrMorph(_:)` flows into a shape such as `.checkmark` and back. Drops are joined
  by threads that stretch, snap and recoil; a target is built from landed mass.
- `QRLiquidStyle` exposes the tuned parameters: `tension`, `stagger`, `dropsPerSide`.
- Drawn by a Metal shader compiled at runtime (no Metal toolchain needed by consumers), only
  while a transition runs; at rest and at both ends of every transition the code is the vector
  outline. Falls back to the growing reveal where Metal is unavailable.
- The previous effect remains as `QRReveal.grow`. `QRCodeShape` defaults to it.
- `Prototypes/LiquidLab`: the browser prototype the liquid was designed in, with tools to compare
  the Swift port against it frame by frame.

## 0.1.0 — 2026-10-15

Initial release.

- Zero-dependency package: URKit's fountain codes, bytewords and UR strings vendored with a
  minimal CBOR codec; Nayuki/fwcd QR encoder vendored for module-level access.
- `QRPayload` with `.text`, `.data`, `.animated`, `.ur` and the `.auto` size policy.
- `QRCodeView` with fixed-version animated playback, lifecycle-aware pausing, placeholder and
  error states, external `QRFrameDriver` for fragment feedback.
- `QRStyle` colours, quiet zone, module/inner/finder radii; contour-traced rounded outline
  ported from beautiful-qr-code; PNG and SVG export.
- Liquid reveal transition driven by a single animatable scalar; frames never animate.
- `QRScanner` + `QRScannerView` + `CameraCodeSource` with one `reset()`, rescan throttling,
  stale timeout, torch and camera switching; `ScriptedCodeSource`/`ManualCodeSource` for tests.
- Exact scan progress (`ScanProgress`), `ScanProgressRing` and `FragmentBar` widgets.
- 91 tests including URKit's vectors, URKit 15.1 interop fixtures and Vision decode of rendered codes.
