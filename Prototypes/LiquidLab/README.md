# Liquid Lab

The browser prototype the liquid transitions were designed in, snapshotted on 2026-10-17 at the
state that was signed off ("lab v6"). `liquid-qr-lab.html` is self-contained: open it in a
browser (WebGL2) to run appear, disappear and the morph into a checkmark on three real symbols,
with the same three parameters the library exposes (`QRLiquidStyle`), plus the module and inner
corner radii.

| File | What it is |
|---|---|
| `template.html` | The source: page, GLSL field shader, JS simulation. The data placeholder is `/*DATA*/null`. |
| `matrices.json` | The symbols it runs on (URL v2, invoice v5, six frames of an animated UR v11). |
| `build.py` | `python3 build.py template.html matrices.json liquid-qr-lab.html` |
| `liquid-qr-lab.html` | The built page. |
| `tools/exporter` | Regenerates `matrices.json` from the library: `swift run --package-path tools/exporter exporter matrices.json` |
| `tools/shots.sh` | Headless-Chrome helpers: zoomed frame strips (`seqz.js`), an artifact probe (`probe.js`) that flags blurred clusters and pixels that jump within a progress step of 0.0002, and a rest hand-off check (`endcheck.js`). |

## How the Swift port maps to it

| Lab | Library |
|---|---|
| `buildModel` | `Sources/PrettySwiftQR/Liquid/QRLiquidModel.swift` |
| `dropState`, `simulate` | `QRLiquidSimulation.swift` |
| `FIELD_FS` (GLSL) | `QRLiquidShader.swift` (Metal, compiled at runtime) |
| `Renderer` | `QRLiquidRenderer.swift`, `QRLiquidView.swift` |
| tension, stagger, drops slider | `QRLiquidStyle(tension:stagger:dropsPerSide:)` |
| Appear / Disappear (mode 4) | `QRReveal.liquid` on insertion, removal and payload swaps |
| Morph to ✓ / back (mode 3) | `.qrMorph(.checkmark)` / `.qrMorph(nil)` |

The port reproduces the lab's frames to within one 8-bit step at every sampled progress. To
check that again, render the lab's invoice symbol from the tests and compare:

```sh
LIQUID_DUMP=/tmp/liquid swift test --filter dumpFramesForTheLab   # writes lab-pull-*.png, lab-flow-*.png
```

and the same progress values in the lab with `tools/shots.sh` (`strip … seqz "4,medium,0.5,0.5,600,0,0,1,600,…"`).

Two things the port does better than this snapshot, found while porting and kept in the library:
pixels that only the untouched resting field covers are antialiased exactly (with 2×2 samples on
edges) rather than from an estimated gradient, so the first and last frame of a transition match
the vector outline at any corner radius; and thread stubs, tips and satellites let go of the field
smoothly as they shrink instead of being dropped below a size, which removed a rare one-frame pop.
`swift test` covers both (`everyTransitionStartsAsTheVectorOutline`, `noFrameJumps`);
`LIQUID_SWEEP=1 swift test --filter denseSweep` runs a denser jump sweep.
