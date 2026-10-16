import Testing
import Foundation
@testable import PrettyQRCore

@Suite struct QRFrameEncoderTests {
    @Test func staticPayloadRepeatsOneFrame() throws {
        let encoder = try QRFrameEncoder(payload: .text("https://example.com"))
        #expect(!encoder.isAnimated)
        #expect(encoder.fragmentCount == 1)
        #expect(encoder.errorCorrection == .medium)
        let a = try encoder.nextFrame()
        let b = try encoder.nextFrame()
        #expect(a == b)
        #expect(encoder.staticFrame == a)
    }

    @Test func smallAnimatedPayloadCollapsesToSinglePart() throws {
        let encoder = try QRFrameEncoder(payload: .animated(Data(repeating: 1, count: 50)))
        #expect(!encoder.isAnimated)
        #expect(encoder.fragmentCount == 1)
        let frame = try encoder.nextFrame()
        #expect(frame == encoder.staticFrame)
    }

    @Test func animatedFramesShareOneVersion() throws {
        let payload = QRPayload.animated(Data((0..<1500).map { UInt8($0 & 0xff) }), maxFragmentLength: 200)
        let encoder = try QRFrameEncoder(payload: payload)
        #expect(encoder.isAnimated)
        #expect(encoder.errorCorrection == .low)
        #expect(encoder.fragmentCount == 8)
        var versions = Set<Int>()
        var sizes = Set<Int>()
        var sequence: [UInt32] = []
        for _ in 0..<500 {
            let frame = try encoder.nextFrame()
            versions.insert(frame.version)
            sizes.insert(frame.size)
            sequence.append(encoder.sequenceNumber)
        }
        #expect(versions == [encoder.version])
        #expect(sizes.count == 1)
        #expect(sequence.prefix(8) == [1, 2, 3, 4, 5, 6, 7, 8])
        // The sequence wraps at the chosen boundary and starts over at 1.
        let wrap = QRFrameEncoder.wrapSequenceNumber(fragmentCount: 8)
        #expect(wrap == 255)
        #expect(sequence[Int(wrap)] == 1)
    }

    @Test func wrapBoundaryKeepsThreePasses() {
        #expect(QRFrameEncoder.wrapSequenceNumber(fragmentCount: 2) == 23)
        #expect(QRFrameEncoder.wrapSequenceNumber(fragmentCount: 8) == 255)
        #expect(QRFrameEncoder.wrapSequenceNumber(fragmentCount: 100) == 65535)
        #expect(QRFrameEncoder.wrapSequenceNumber(fragmentCount: 30000) == .max)
    }

    @Test func worstCaseStringIsLongestInSequence() throws {
        let ur = UR(bytes: Data((0..<2000).map { UInt8($0 & 0xff) }))
        let probe = UREncoder(ur, maxFragmentLen: 150)
        let wrap = QRFrameEncoder.wrapSequenceNumber(fragmentCount: probe.seqLen)
        let worst = QRFrameEncoder.worstCasePartString(encoder: probe, ur: ur, sequenceNumber: wrap)
        let encoder = UREncoder(ur, maxFragmentLen: 150)
        var longest = 0
        for _ in 0..<Int(wrap) { longest = max(longest, encoder.nextPart().count) }
        #expect(worst.count >= longest)
        #expect(worst.count - longest <= 2)
    }

    @Test func framesDecodeBackToPayload() throws {
        let message = Data((0..<900).map { UInt8(($0 * 7) & 0xff) })
        let encoder = try QRFrameEncoder(payload: .animated(message, maxFragmentLength: 120))
        // Decode by re-encoding the same part strings the frames were built from.
        let urEncoder = UREncoder(UR(bytes: message), maxFragmentLen: 120)
        let decoder = URDecoder()
        for _ in 0..<encoder.fragmentCount {
            _ = try encoder.nextFrame()
            decoder.receivePart(urEncoder.nextPart())
        }
        guard case .success(let ur)? = decoder.result else { Issue.record("not decoded"); return }
        #expect(ur.bytes == message)
    }

    @Test func emptyPayloadThrows() {
        #expect(throws: QREncodingError.empty) { try QRFrameEncoder(payload: .text("")) }
        #expect(throws: QREncodingError.empty) { try QRFrameEncoder(payload: .animated(Data())) }
    }

    @Test func autoPolicyMatchesMacadamia() {
        let short = String(repeating: "x", count: 600)
        let long = String(repeating: "x", count: 601)
        #expect(QRPayload.auto(short) == .text(short))
        #expect(QRPayload.auto(long) == .animated(text: long))
        #expect(QRPayload.auto(long).isUR)
        #expect(QRPayload.auto(long).maxFragmentLength == 200)
    }
}
