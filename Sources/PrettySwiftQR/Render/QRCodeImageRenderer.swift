//
//  QRCodeImageRenderer.swift
//  PrettySwiftQR
//

import SwiftUI
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import PrettyQRCore

/// Renders styled QR codes to bitmaps, for sharing or saving.
public enum QRCodeImageRenderer {
    /// Resolves SwiftUI colours and rasterises `matrix` at `pixelSize` × `pixelSize`.
    @MainActor
    public static func cgImage(matrix: QRMatrix, style: QRStyle = .default, pixelSize: Int = 1024, environment: EnvironmentValues = EnvironmentValues()) -> CGImage? {
        let fg = style.foreground.resolve(in: environment)
        let bg = style.background.resolve(in: environment)
        return cgImage(matrix: matrix, radii: style.radii, quietZone: style.quietZone, pixelSize: pixelSize,
                       foreground: CGColor(srgbRed: CGFloat(fg.linearRed).srgb, green: CGFloat(fg.linearGreen).srgb, blue: CGFloat(fg.linearBlue).srgb, alpha: CGFloat(fg.opacity)),
                       background: CGColor(srgbRed: CGFloat(bg.linearRed).srgb, green: CGFloat(bg.linearGreen).srgb, blue: CGFloat(bg.linearBlue).srgb, alpha: CGFloat(bg.opacity)))
    }

    /// Rasterises with explicit CoreGraphics colours. Usable from any thread.
    public static func cgImage(matrix: QRMatrix, radii: QROutlineRadii = .round, quietZone: Double = 2, pixelSize: Int = 1024, foreground: CGColor, background: CGColor?) -> CGImage? {
        guard pixelSize > 0 else { return nil }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: pixelSize, height: pixelSize, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Flip to y-down so module coordinates map directly.
        context.translateBy(x: 0, y: CGFloat(pixelSize))
        context.scaleBy(x: 1, y: -1)
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        if let background {
            context.setFillColor(background)
            context.fill(CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
        }
        let extent = Double(matrix.size) + 2 * quietZone
        let scale = CGFloat(pixelSize) / extent
        let origin = CGPoint(x: quietZone * scale, y: quietZone * scale)
        let commands = QROutline.trace(matrix, radii: radii) + QROutline.finders(matrix, radii: radii)
        context.addPath(Path(qrCommands: commands, scale: scale, origin: origin).cgPath)
        context.setFillColor(foreground)
        context.fillPath(using: .winding)
        return context.makeImage()
    }

    /// PNG data for `image`.
    public static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Encodes `payload` (static only) and renders it. Returns nil for animated payloads.
    @MainActor
    public static func image(for payload: QRPayload, style: QRStyle = .default, pixelSize: Int = 1024) throws -> Image? {
        let encoder = try QRFrameEncoder(payload: payload, errorCorrection: style.errorCorrection)
        guard let matrix = encoder.staticFrame, let cg = cgImage(matrix: matrix, style: style, pixelSize: pixelSize) else { return nil }
        return Image(decorative: cg, scale: 1)
    }

    /// An SVG document for `payload` (static only).
    public static func svg(for payload: QRPayload, radii: QROutlineRadii = .round, quietZone: Double = 2, foreground: String = "#000000", background: String? = "#FFFFFF", errorCorrection: QRErrorCorrection? = nil) throws -> String? {
        let encoder = try QRFrameEncoder(payload: payload, errorCorrection: errorCorrection)
        guard let matrix = encoder.staticFrame else { return nil }
        return QROutline.svg(matrix, radii: radii, quietZone: quietZone, foreground: foreground, background: background)
    }
}

private extension CGFloat {
    /// Linear sRGB component → gamma-encoded sRGB.
    var srgb: CGFloat {
        let c = Swift.min(Swift.max(self, 0), 1)
        return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
    }
}
