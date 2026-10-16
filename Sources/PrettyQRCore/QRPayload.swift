//
//  QRPayload.swift
//  PrettySwiftQR
//

import Foundation

/// What to put into a QR code. Static payloads produce one code; animated
/// payloads are fountain-coded as multi-part URs (BCR-2020-005) and cycle forever.
public enum QRPayload: Hashable, Sendable {
    /// One static code. Numeric, alphanumeric or byte mode is chosen automatically.
    case text(String)
    /// One static code in byte mode.
    case data(Data)
    /// `bytes` wrapped as `ur:bytes` and fountain-coded into parts of at most
    /// `maxFragmentLength` bytes. Small payloads collapse to a single static part.
    case animated(Data, maxFragmentLength: Int = QRPayload.defaultMaxFragmentLength)
    /// Any UR, fountain-coded if it does not fit a single part.
    case ur(UR, maxFragmentLength: Int = QRPayload.defaultMaxFragmentLength)

    public static let defaultMaxFragmentLength = 200
    public static let defaultStaticLimit = 600

    /// Animated `ur:bytes` carrying the UTF-8 encoding of `text`.
    public static func animated(text: String, maxFragmentLength: Int = defaultMaxFragmentLength) -> QRPayload {
        .animated(Data(text.utf8), maxFragmentLength: maxFragmentLength)
    }

    /// Static up to `staticLimit` UTF-8 bytes, animated above. This is the
    /// policy macadamia used; it keeps short codes scannable by any reader.
    public static func auto(_ text: String, staticLimit: Int = defaultStaticLimit, maxFragmentLength: Int = defaultMaxFragmentLength) -> QRPayload {
        text.utf8.count > staticLimit ? .animated(text: text, maxFragmentLength: maxFragmentLength) : .text(text)
    }

    public static func auto(_ data: Data, staticLimit: Int = defaultStaticLimit, maxFragmentLength: Int = defaultMaxFragmentLength) -> QRPayload {
        data.count > staticLimit ? .animated(data, maxFragmentLength: maxFragmentLength) : .data(data)
    }

    /// `true` when this payload is encoded as a UR (possibly single-part).
    public var isUR: Bool {
        switch self {
        case .text, .data: return false
        case .animated, .ur: return true
        }
    }

    /// The UR for `.animated` and `.ur`; nil for static text/data.
    public var ur: UR? {
        switch self {
        case .text, .data: return nil
        case .animated(let data, _): return UR(bytes: data)
        case .ur(let ur, _): return ur
        }
    }

    public var maxFragmentLength: Int? {
        switch self {
        case .text, .data: return nil
        case .animated(_, let max), .ur(_, let max): return max
        }
    }

    public var isEmpty: Bool {
        switch self {
        case .text(let s): return s.isEmpty
        case .data(let d): return d.isEmpty
        case .animated(let d, _): return d.isEmpty
        case .ur: return false
        }
    }
}
