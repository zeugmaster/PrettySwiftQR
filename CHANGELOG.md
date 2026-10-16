# Changelog

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
