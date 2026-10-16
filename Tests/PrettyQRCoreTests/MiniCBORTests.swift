import Testing
import Foundation
@testable import PrettyQRCore

@Suite struct MiniCBORTests {
    @Test func integerHeadersAreShortest() {
        func enc(_ v: UInt64) -> [UInt8] { var w = MiniCBOR.Writer(); w.writeUnsigned(v); return Array(w.data) }
        #expect(enc(0) == [0x00])
        #expect(enc(23) == [0x17])
        #expect(enc(24) == [0x18, 0x18])
        #expect(enc(255) == [0x18, 0xff])
        #expect(enc(256) == [0x19, 0x01, 0x00])
        #expect(enc(65535) == [0x19, 0xff, 0xff])
        #expect(enc(65536) == [0x1a, 0x00, 0x01, 0x00, 0x00])
        #expect(enc(UInt64(UInt32.max) + 1) == [0x1b, 0, 0, 0, 1, 0, 0, 0, 0])
    }

    @Test func bytesRoundTrip() {
        let payload = Data((0..<300).map { UInt8($0 & 0xff) })
        let cbor = MiniCBOR.encodeBytes(payload)
        #expect(Array(cbor.prefix(3)) == [0x59, 0x01, 0x2c])
        #expect(MiniCBOR.decodeBytes(cbor) == payload)
        #expect(MiniCBOR.isWellFormed(cbor))
        #expect(MiniCBOR.decodeText(cbor) == nil)
    }

    @Test func textRoundTrip() {
        let cbor = MiniCBOR.encodeText("héllo")
        #expect(MiniCBOR.decodeText(cbor) == "héllo")
        #expect(MiniCBOR.decodeBytes(cbor) == nil)
    }

    @Test func wellFormednessWalk() {
        // [1, "a", h'00', {2: [3]}, 7(5), true, 1.5f16]
        let doc: [UInt8] = [0x87, 0x01, 0x61, 0x61, 0x41, 0x00, 0xa1, 0x02, 0x81, 0x03, 0xc7, 0x05, 0xf5, 0xf9, 0x3e, 0x00]
        #expect(MiniCBOR.isWellFormed(Data(doc)))
        #expect(!MiniCBOR.isWellFormed(Data(doc.dropLast())))        // truncated
        #expect(!MiniCBOR.isWellFormed(Data(doc + [0x00])))           // trailing
        #expect(!MiniCBOR.isWellFormed(Data([0xff])))                 // bare break
        #expect(!MiniCBOR.isWellFormed(Data([0x1c])))                 // reserved additional info
        #expect(MiniCBOR.isWellFormed(Data([0x5f, 0x41, 0x00, 0x41, 0x01, 0xff]))) // indefinite bytes
        #expect(MiniCBOR.isWellFormed(Data([0x9f, 0x01, 0x02, 0xff])))             // indefinite array
        #expect(!MiniCBOR.isWellFormed(Data([0x9f, 0x01, 0x02])))                  // unterminated
        #expect(!MiniCBOR.isWellFormed(Data()))
    }

    @Test func partHeaderMatchesURKitVector() throws {
        let part = FountainEncoder.Part(seqNum: 12, seqLen: 8, messageLen: 100, checksum: 0x12345678, data: Data([1, 5, 3, 3, 5]))
        #expect(part.cbor.hex == "850c0818641a12345678450105030305")
        let decoded = try FountainEncoder.Part(cbor: part.cbor)
        #expect(decoded == part)
        #expect(throws: FountainEncoderError.self) { try FountainEncoder.Part(cbor: part.cbor.dropLast()) }
        #expect(throws: FountainEncoderError.self) { try FountainEncoder.Part(cbor: part.cbor + Data([0])) }
    }

    @Test func urConveniences() throws {
        let ur = UR(utf8: "cashuA…")
        #expect(ur.type == "bytes")
        #expect(ur.utf8String == "cashuA…")
        #expect(ur.bytes == Data("cashuA…".utf8))
        let parsed = try UR(urString: ur.string)
        #expect(parsed == ur)
        #expect(throws: URError.self) { try UR(type: "bytes", cbor: Data([0xff])) }
        #expect(throws: URError.self) { try UR(type: "Bad Type", cbor: Data([0x00])) }
        #expect(ur.qrString == ur.string.uppercased())
    }
}
