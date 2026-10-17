# PrettySwiftQR

Beautiful QR codes for SwiftUI: show them, scan them, and let them move like liquid mercury.

- **Any payload.** Short text becomes one code; long text becomes an animated sequence that any
  [UR](https://github.com/BlockchainCommons/Research/blob/master/papers/bcr-2020-005-ur.md)
  reader can scan.
- **Rounded, styleable modules** with adjustable corners, colours and finder eyes.
- **Liquid transitions.** Codes gather out of drops, pull apart, and can flow into a checkmark
  and back. At rest the code is always crisp and scannable.
- **One scanner** for static and animated codes, with exact progress and a single `reset()`.

No dependencies. iOS 17+ and macOS 14+ (macOS: display only), Swift 6.

## Install

```swift
.package(url: "https://github.com/zeugmaster/PrettySwiftQR", from: "0.1.0")
```

## Show a code

```swift
import PrettySwiftQR

QRCodeView(auto: token)        // static if short, animated if long
    .qrStyle(.rounded(0.45))   // 0 = square modules … 0.5 = fully round
    .qrColors(foreground: .black, background: .white)
    .frame(width: 260)
```

## Transitions

Codes appear and disappear as liquid by default. To flow into a checkmark, for example once a
payment arrives:

```swift
QRCodeView(.text(invoice))
    .qrMorph(isPaid ? .checkmark : nil)
```

Tune the liquid, or pick another effect:

```swift
.qrReveal(.liquid(QRLiquidStyle(tension: 0.26, stagger: 0.55, dropsPerSide: 7), duration: 1.2))
.qrReveal(.grow)   // modules grow from their centres
.qrReveal(.none)   // plain cross-fade
```

## Scan a code

```swift
QRScannerView { result in
    switch result {
    case .text(let string): handle(string)
    case .ur(let ur): handle(ur.utf8String ?? "")
    }
}
```

## Learn more

- [Guide](Docs/Guide.md): payload kinds, every style option, durations and custom morph shapes,
  scanner configuration, using the core without UI, and migrating from URUI.
- `Example/`: an iOS app to play with every option
  (`cd Example && xcodegen generate && open PrettySwiftQRExample.xcodeproj`).
- `Prototypes/LiquidLab`: the browser prototype the liquid transitions were designed in.

## License

MIT. Vendored parts keep their licenses: URKit (BSD-2-Clause Plus Patent) and
swift-qrcode-generator / Project Nayuki (MIT). See `LICENSES/`.
