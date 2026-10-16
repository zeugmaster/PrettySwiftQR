import Testing
import Foundation
@testable import PrettyQRCore

@Suite struct ScanDecoderTests {
    let message = Data((0..<1200).map { UInt8(($0 * 13) & 0xff) })
    /// 1200 bytes plus the 3-byte CBOR header split into 13 fragments of ≤100 bytes.
    var seqLen: Int { UREncoder(UR(bytes: message), maxFragmentLen: 100).seqLen }

    func parts(maxFragmentLen: Int = 100, count: Int, firstSeqNum: UInt32 = 0, data: Data? = nil) -> [String] {
        let encoder = UREncoder(UR(bytes: data ?? message), maxFragmentLen: maxFragmentLen, firstSeqNum: firstSeqNum)
        return (0..<count).map { _ in encoder.nextPart().uppercased() }
    }

    @Test func plainTextCompletesImmediately() {
        let decoder = ScanDecoder()
        #expect(decoder.receive("  https://example.com \n") == .completed(.text("https://example.com")))
        #expect(decoder.phase == .completed(.text("https://example.com")))
        #expect(decoder.progress == nil)
        #expect(decoder.receive("other") == .rejected(.alreadyCompleted))
        decoder.reset()
        #expect(decoder.phase == .idle)
        #expect(decoder.receive("other") == .completed(.text("other")))
    }

    @Test func singlePartURCompletes() {
        let ur = UR(utf8: "short token")
        let decoder = ScanDecoder()
        guard case .completed(.ur(let result)) = decoder.receive(ur.qrString) else { Issue.record("expected completion"); return }
        #expect(result == ur)
        #expect(result.utf8String == "short token")
        #expect(decoder.progress == nil)
    }

    @Test func multiPartInOrderHasExactMonotonicProgress() {
        let decoder = ScanDecoder()
        let frames = parts(count: seqLen)
        var fractions: [Double] = []
        var lastOutcome: ScanDecoder.Outcome?
        for frame in frames {
            let outcome = decoder.receive(frame)
            lastOutcome = outcome
            if case .progressed(let p) = outcome {
                fractions.append(p.fraction)
                #expect(p.expectedFragments == seqLen)
                #expect(p.receivedFragments == fractions.count)
                #expect(!p.isComplete)
            }
            if case .completed = outcome { break }
        }
        #expect(fractions == (1..<seqLen).map { Double($0) / Double(seqLen) })
        guard case .completed(.ur(let ur))? = lastOutcome else { Issue.record("expected completion, got \(String(describing: lastOutcome))"); return }
        #expect(ur.bytes == message)
        #expect(decoder.progress?.isComplete == true)
        #expect(decoder.progress?.fraction == 1)
        #expect(decoder.progress?.receivedFragments == seqLen)
    }

    @Test func shuffledAndDuplicatedPartsStillComplete() {
        let decoder = ScanDecoder()
        var frames = parts(count: 60, firstSeqNum: 7)
        var generator = SeededGenerator(seed: 42)
        frames.shuffle(using: &generator)
        frames = frames.flatMap { [$0, $0] } // every frame delivered twice
        var previous = 0.0
        var duplicates = 0
        var completed = false
        for frame in frames {
            switch decoder.receive(frame) {
            case .progressed(let p):
                #expect(p.fraction >= previous, "progress must never decrease")
                previous = p.fraction
            case .duplicate:
                duplicates += 1
            case .completed(let result):
                completed = true
                #expect(result.data == message)
            case .rejected(.alreadyCompleted):
                #expect(completed)
            case let other:
                Issue.record("unexpected outcome \(other)")
            }
            if completed { break }
        }
        #expect(completed)
        #expect(duplicates > 0)
    }

    @Test func strayCodesDoNotDisturbCollection() {
        let decoder = ScanDecoder()
        let frames = parts(count: seqLen)
        _ = decoder.receive(frames[0])
        _ = decoder.receive(frames[1])
        let before = decoder.progress
        #expect(decoder.receive("https://stray.example") == .rejected(.textDuringCollection))
        let other = parts(count: 3, data: Data(repeating: 9, count: 500))
        #expect(decoder.receive(other[0]) == .rejected(.foreignPart))
        #expect(decoder.receive("ur:bytes/garbage") == .rejected(.foreignPart))
        #expect(decoder.receive("UR:CRYPTO-SEED/1-2/LPADAO") == .rejected(.foreignPart))
        #expect(decoder.progress == before)
        #expect(decoder.phase == .collecting(urType: "bytes"))
    }

    @Test func malformedURWhenIdleIsRejectedWithoutState() {
        let decoder = ScanDecoder()
        #expect(decoder.receive("ur:bytes/notbytewords!") == .rejected(.malformed))
        #expect(decoder.phase == .idle)
        #expect(decoder.progress == nil)
    }

    @Test func resetMidwayStartsOver() {
        let decoder = ScanDecoder()
        let frames = parts(count: seqLen)
        for frame in frames.prefix(5) { _ = decoder.receive(frame) }
        #expect(decoder.progress?.receivedFragments == 5)
        decoder.reset()
        #expect(decoder.progress == nil)
        #expect(decoder.phase == .idle)
        for frame in frames { if case .completed = decoder.receive(frame) { break } }
        #expect(decoder.progress?.isComplete == true)
    }

    @Test func staleTimeoutResetsCollection() {
        let decoder = ScanDecoder(configuration: .init(staleTimeout: .seconds(2)))
        let frames = parts(count: seqLen)
        let t0 = ContinuousClock.now
        _ = decoder.receive(frames[0], now: t0)
        _ = decoder.receive(frames[1], now: t0 + .seconds(1))
        #expect(decoder.progress?.receivedFragments == 2)
        #expect(!decoder.expireIfStale(now: t0 + .seconds(2)))
        #expect(decoder.expireIfStale(now: t0 + .seconds(3) + .milliseconds(1)))
        #expect(decoder.phase == .idle)
        // A late frame after expiry is reported as timedOut and starts a fresh collection.
        _ = decoder.receive(frames[2], now: t0 + .seconds(10))
        #expect(decoder.progress?.receivedFragments == 1)
        #expect(decoder.receive(frames[3], now: t0 + .seconds(20)) == .timedOut)
        #expect(decoder.progress?.receivedFragments == 1)
        #expect(decoder.progress?.lastFragmentIndexes == [3])
    }

    @Test func textOnlyConfigurationTreatsURAsText() {
        let decoder = ScanDecoder(configuration: .init(acceptsUR: false))
        let frame = parts(count: 1)[0]
        #expect(decoder.receive(frame) == .completed(.text(frame)))
    }

    @Test func urOnlyConfigurationRejectsText() {
        let decoder = ScanDecoder(configuration: .init(acceptsText: false))
        #expect(decoder.receive("hello") == .rejected(.notAccepted))
        #expect(decoder.phase == .idle)
    }

    @Test func fragmentStatesReflectLastFrame() {
        let decoder = ScanDecoder()
        let frames = parts(count: seqLen)
        _ = decoder.receive(frames[0])
        guard case .progressed(let p) = decoder.receive(frames[4]) else { Issue.record("expected progress"); return }
        let states = p.fragmentStates
        #expect(states.count == seqLen)
        #expect(states[0] == .received)
        #expect(states[4] == .justReceived)
        #expect(states[1] == .missing)
    }

    @Test func checksumFailureIsReported() {
        // Corrupt one simple part's data while keeping the header consistent.
        let decoder = ScanDecoder()
        let encoder = UREncoder(UR(bytes: message), maxFragmentLen: 100)
        var corrupted = false
        var outcome: ScanDecoder.Outcome?
        for _ in 0..<encoder.seqLen {
            var part = encoder.nextPart()
            if !corrupted {
                // Rebuild the part with flipped data bytes.
                let components = part.split(separator: "/").map(String.init)
                let cbor = try! Bytewords.decode(components[2], style: .minimal)
                let original = try! FountainEncoder.Part(cbor: cbor)
                let bad = FountainEncoder.Part(seqNum: original.seqNum, seqLen: original.seqLen, messageLen: original.messageLen, checksum: original.checksum, data: Data(original.data.map { $0 ^ 0xff }))
                part = "ur:bytes/\(components[1])/\(Bytewords.encode(bad.cbor, style: .minimal))"
                corrupted = true
            }
            outcome = decoder.receive(part)
        }
        #expect(outcome == .failed(.invalidChecksum))
        #expect(decoder.phase == .failed(.invalidChecksum))
        #expect(decoder.receive("x") == .rejected(.alreadyCompleted))
        decoder.reset()
        #expect(decoder.phase == .idle)
    }
}

struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}
