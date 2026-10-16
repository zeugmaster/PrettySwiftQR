//
//  MiniCBOR.swift
//  PrettySwiftQR
//
//  A deliberately tiny CBOR (RFC 8949) codec. It covers exactly what the UR
//  and fountain-code formats need: unsigned integers, byte strings, text
//  strings, definite-length array headers, and a well-formedness walk used to
//  validate arbitrary UR bodies without interpreting them.
//

import Foundation

public enum MiniCBOR {
    public enum Error: Swift.Error, Equatable, Sendable {
        case truncated
        case unexpectedType
        case malformed
        case trailingBytes
    }

    // MARK: Writer

    public struct Writer: Sendable {
        public private(set) var data = Data()

        public init() {}

        /// Writes a header using the shortest (deterministic) integer encoding.
        public mutating func writeHeader(major: UInt8, value: UInt64) {
            let majorBits = major << 5
            switch value {
            case 0..<24:
                data.append(majorBits | UInt8(value))
            case 24...UInt64(UInt8.max):
                data.append(majorBits | 24)
                data.append(UInt8(value))
            case UInt64(UInt8.max) + 1...UInt64(UInt16.max):
                data.append(majorBits | 25)
                data.append(contentsOf: withUnsafeBytes(of: UInt16(value).bigEndian) { Array($0) })
            case UInt64(UInt16.max) + 1...UInt64(UInt32.max):
                data.append(majorBits | 26)
                data.append(contentsOf: withUnsafeBytes(of: UInt32(value).bigEndian) { Array($0) })
            default:
                data.append(majorBits | 27)
                data.append(contentsOf: withUnsafeBytes(of: value.bigEndian) { Array($0) })
            }
        }

        public mutating func writeUnsigned(_ value: UInt64) {
            writeHeader(major: 0, value: value)
        }

        public mutating func writeBytes(_ bytes: Data) {
            writeHeader(major: 2, value: UInt64(bytes.count))
            data.append(bytes)
        }

        public mutating func writeText(_ text: String) {
            let utf8 = Data(text.utf8)
            writeHeader(major: 3, value: UInt64(utf8.count))
            data.append(utf8)
        }

        public mutating func writeArrayHeader(count: Int) {
            writeHeader(major: 4, value: UInt64(count))
        }
    }

    // MARK: Reader

    public struct Reader {
        private let bytes: [UInt8]
        private(set) var index = 0

        public init(_ data: Data) {
            bytes = Array(data)
        }

        public var isAtEnd: Bool { index >= bytes.count }

        private mutating func readByte() throws -> UInt8 {
            guard index < bytes.count else { throw Error.truncated }
            defer { index += 1 }
            return bytes[index]
        }

        private mutating func readBigEndian(byteCount: Int) throws -> UInt64 {
            guard index + byteCount <= bytes.count else { throw Error.truncated }
            var value: UInt64 = 0
            for _ in 0..<byteCount {
                value = (value << 8) | UInt64(bytes[index])
                index += 1
            }
            return value
        }

        /// Reads an initial byte and its argument. `value` is nil for indefinite length.
        mutating func readHeader() throws -> (major: UInt8, additional: UInt8, value: UInt64?) {
            let initial = try readByte()
            let major = initial >> 5
            let additional = initial & 0x1f
            switch additional {
            case 0..<24: return (major, additional, UInt64(additional))
            case 24: return (major, additional, try readBigEndian(byteCount: 1))
            case 25: return (major, additional, try readBigEndian(byteCount: 2))
            case 26: return (major, additional, try readBigEndian(byteCount: 4))
            case 27: return (major, additional, try readBigEndian(byteCount: 8))
            case 31: return (major, additional, nil)
            default: throw Error.malformed
            }
        }

        public mutating func readUnsigned() throws -> UInt64 {
            let header = try readHeader()
            guard header.major == 0, let value = header.value else { throw Error.unexpectedType }
            return value
        }

        public mutating func readBytes() throws -> Data {
            let header = try readHeader()
            guard header.major == 2, let length = header.value else { throw Error.unexpectedType }
            guard length <= UInt64(bytes.count - index) else { throw Error.truncated }
            let start = index
            index += Int(length)
            return Data(bytes[start..<index])
        }

        public mutating func readText() throws -> String {
            let header = try readHeader()
            guard header.major == 3, let length = header.value else { throw Error.unexpectedType }
            guard length <= UInt64(bytes.count - index) else { throw Error.truncated }
            let start = index
            index += Int(length)
            guard let string = String(bytes: bytes[start..<index], encoding: .utf8) else { throw Error.malformed }
            return string
        }

        public mutating func readArrayHeader() throws -> Int {
            let header = try readHeader()
            guard header.major == 4, let count = header.value, count <= UInt64(Int.max) else { throw Error.unexpectedType }
            return Int(count)
        }

        /// Skips one complete data item, validating structure but not semantics.
        mutating func skipItem(depth: Int = 0) throws {
            guard depth < 64 else { throw Error.malformed }
            let header = try readHeader()
            switch header.major {
            case 0, 1:
                guard header.value != nil else { throw Error.malformed }
            case 2, 3:
                if let length = header.value {
                    guard length <= UInt64(bytes.count - index) else { throw Error.truncated }
                    index += Int(length)
                } else {
                    // Indefinite string: chunks of the same major type until break.
                    while true {
                        guard index < bytes.count else { throw Error.truncated }
                        if bytes[index] == 0xff { index += 1; break }
                        let chunk = try readHeader()
                        guard chunk.major == header.major, let length = chunk.value else { throw Error.malformed }
                        guard length <= UInt64(bytes.count - index) else { throw Error.truncated }
                        index += Int(length)
                    }
                }
            case 4, 5:
                let itemsPerEntry: UInt64 = header.major == 5 ? 2 : 1
                if let count = header.value {
                    let (total, overflow) = count.multipliedReportingOverflow(by: itemsPerEntry)
                    guard !overflow, total <= UInt64(bytes.count - index) else { throw Error.truncated }
                    for _ in 0..<total { try skipItem(depth: depth + 1) }
                } else {
                    while true {
                        guard index < bytes.count else { throw Error.truncated }
                        if bytes[index] == 0xff { index += 1; break }
                        for _ in 0..<itemsPerEntry { try skipItem(depth: depth + 1) }
                    }
                }
            case 6:
                guard header.value != nil else { throw Error.malformed }
                try skipItem(depth: depth + 1)
            default: // 7
                switch header.additional {
                case 0..<24, 24, 25, 26, 27:
                    break
                default:
                    throw Error.malformed // bare break or reserved
                }
            }
        }
    }

    // MARK: Convenience

    /// `true` when `data` is exactly one well-formed CBOR data item.
    public static func isWellFormed(_ data: Data) -> Bool {
        var reader = Reader(data)
        guard (try? reader.skipItem()) != nil else { return false }
        return reader.isAtEnd
    }

    public static func encodeBytes(_ bytes: Data) -> Data {
        var writer = Writer()
        writer.writeBytes(bytes)
        return writer.data
    }

    public static func encodeText(_ text: String) -> Data {
        var writer = Writer()
        writer.writeText(text)
        return writer.data
    }

    /// Decodes a single CBOR byte string, or returns nil if `cbor` is anything else.
    public static func decodeBytes(_ cbor: Data) -> Data? {
        var reader = Reader(cbor)
        guard let bytes = try? reader.readBytes(), reader.isAtEnd else { return nil }
        return bytes
    }

    /// Decodes a single CBOR text string, or returns nil if `cbor` is anything else.
    public static func decodeText(_ cbor: Data) -> String? {
        var reader = Reader(cbor)
        guard let text = try? reader.readText(), reader.isAtEnd else { return nil }
        return text
    }
}
