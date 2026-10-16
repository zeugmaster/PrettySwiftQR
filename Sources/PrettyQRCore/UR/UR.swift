//
//  UR.swift
//
//  Copyright © 2020 by Blockchain Commons, LLC
//  Licensed under the "BSD-2-Clause Plus Patent License"
//
//  Vendored into PrettySwiftQR. `cbor` is stored as raw bytes instead of a
//  decoded CBOR value; the string format (BCR-2020-005) is unchanged.
//

import Foundation

public enum URError: LocalizedError, Sendable {
    case invalidType
    case unexpectedType
    case invalidCBOR

    public var errorDescription: String? {
        switch self {
        case .invalidType:
            return "Invalid UR type."
        case .unexpectedType:
            return "Unexpected UR type."
        case .invalidCBOR:
            return "Invalid CBOR."
        }
    }
}

/// A Uniform Resource: a type tag plus a CBOR-encoded body.
public struct UR: Equatable, Hashable, Sendable, CustomStringConvertible {
    public static let bytesType = "bytes"

    public let type: String
    /// The body as raw CBOR bytes (exactly one well-formed data item).
    public let cbor: Data

    public init(type: String, cbor: Data) throws {
        guard type.isURType else { throw URError.invalidType }
        guard MiniCBOR.isWellFormed(cbor) else { throw URError.invalidCBOR }
        self.type = type
        self.cbor = cbor
    }

    /// A `ur:bytes` whose body is `bytes` wrapped in a CBOR byte string.
    public init(bytes: Data) {
        self.type = Self.bytesType
        self.cbor = MiniCBOR.encodeBytes(bytes)
    }

    /// A `ur:bytes` carrying the UTF-8 encoding of `text`.
    public init(utf8 text: String) {
        self.init(bytes: Data(text.utf8))
    }

    public init(urString: String) throws {
        self = try URDecoder.decode(urString)
    }

    /// The payload when the body is a single CBOR byte string (as in `ur:bytes`).
    public var bytes: Data? {
        MiniCBOR.decodeBytes(cbor)
    }

    /// The payload as UTF-8 text when the body is a byte string or a text string.
    public var utf8String: String? {
        if let bytes { return String(data: bytes, encoding: .utf8) }
        return MiniCBOR.decodeText(cbor)
    }
}

public extension UR {
    var string: String {
        UREncoder.encode(self)
    }

    /// The single-part string uppercased so QR encoders can use alphanumeric mode.
    var qrString: String {
        string.uppercased()
    }

    var qrData: Data {
        Data(qrString.utf8)
    }

    var description: String {
        string
    }

    func checkType(_ type: String) throws {
        guard self.type == type else {
            throw URError.unexpectedType
        }
    }

    func checkTypes(_ types: [String]) throws {
        guard types.contains(self.type) else {
            throw URError.unexpectedType
        }
    }
}
