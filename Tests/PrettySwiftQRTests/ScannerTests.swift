import Testing
import Foundation
@testable import PrettySwiftQR

@MainActor
@Suite struct ScannerTests {
    let message = Data((0..<900).map { UInt8(($0 * 17) & 0xff) })

    func parts(_ count: Int, maxFragmentLen: Int = 100) -> [String] {
        let encoder = UREncoder(UR(bytes: message), maxFragmentLen: maxFragmentLen)
        return (0..<count).map { _ in encoder.nextPart().uppercased() }
    }

    /// Waits until the scanner has processed `count` codes.
    func settle(_ scanner: QRScanner, codes count: Int) async {
        for _ in 0..<200 where scanner.receivedCodeCount < count {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func staticCodeCompletesAndHoldsUntilReset() async throws {
        let source = ManualCodeSource()
        let scanner = QRScanner(source: source)
        var results: [ScanResult] = []
        scanner.onResult = { results.append($0) }
        await scanner.start()
        #expect(scanner.state == .scanning)
        let t0 = ContinuousClock.now
        source.send("hello", timestamp: t0)
        source.send("hello", timestamp: t0 + .milliseconds(100))
        source.send("world", timestamp: t0 + .milliseconds(200))
        await settle(scanner, codes: 3)
        #expect(results == [.text("hello")])
        #expect(scanner.state == .completed(.text("hello")))
        scanner.reset()
        #expect(scanner.state == .scanning)
        // The same code may be scanned again right after a reset.
        source.send("hello", timestamp: t0 + .milliseconds(300))
        await settle(scanner, codes: 4)
        #expect(results == [.text("hello"), .text("hello")])
        await scanner.stop()
        #expect(scanner.state == .idle)
    }

    @Test func rescanIntervalThrottlesRepeats() async throws {
        let source = ManualCodeSource()
        let scanner = QRScanner(configuration: .init(rescanInterval: .seconds(1), holdsResult: false), source: source)
        var results: [ScanResult] = []
        scanner.onResult = { results.append($0) }
        await scanner.start()
        let t0 = ContinuousClock.now
        source.send("a", timestamp: t0)
        source.send("a", timestamp: t0 + .milliseconds(500))
        source.send("a", timestamp: t0 + .milliseconds(1001))
        await settle(scanner, codes: 3)
        #expect(results.count == 2)
        await scanner.stop()
    }

    @Test func animatedScanReportsProgressThenResult() async throws {
        let source = ManualCodeSource()
        let scanner = QRScanner(source: source)
        var results: [ScanResult] = []
        scanner.onResult = { results.append($0) }
        await scanner.start()
        let frames = parts(40)
        var fractions: [Double] = []
        let t0 = ContinuousClock.now
        for (i, frame) in frames.enumerated() {
            source.send(frame, timestamp: t0 + .milliseconds(i * 100))
            await settle(scanner, codes: i + 1)
            if let p = scanner.progress { fractions.append(p.fraction) }
            if case .completed = scanner.state { break }
        }
        #expect(results.count == 1)
        #expect(results.first?.data == message)
        #expect(scanner.progress?.isComplete == true)
        #expect(fractions == fractions.sorted(), "progress never decreases")
        #expect(fractions.last == 1)
        await scanner.stop()
    }

    @Test func staleCollectionResetsWithoutNewCodes() async throws {
        let source = ManualCodeSource()
        var configuration = QRScanner.Configuration()
        configuration.decoder.staleTimeout = .milliseconds(150)
        configuration.staleCheckInterval = .milliseconds(30)
        let scanner = QRScanner(configuration: configuration, source: source)
        var staleCalls = 0
        scanner.onStale = { staleCalls += 1 }
        await scanner.start()
        source.send(parts(2)[0])
        await settle(scanner, codes: 1)
        #expect(scanner.progress?.receivedFragments == 1)
        try await Task.sleep(for: .milliseconds(400))
        #expect(scanner.progress == nil)
        #expect(staleCalls == 1)
        #expect(scanner.state == .scanning)
        await scanner.stop()
    }

    @Test func unavailableSourceIsReported() async {
        let scanner = QRScanner(source: UnavailableCodeSource())
        await scanner.start()
        #expect(scanner.state == .unavailable)
        await scanner.stop()
        #expect(scanner.state == .idle)
    }

    @Test func scriptedSourceDrivesWholePipeline() async throws {
        let payload = QRPayload.animated(message, maxFragmentLength: 80)
        let source = try ScriptedCodeSource(payload: payload, interval: .milliseconds(1), frames: 60)
        let scanner = QRScanner(configuration: .init(rescanInterval: .zero), source: source)
        await scanner.start()
        for _ in 0..<400 {
            if case .completed = scanner.state { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        guard case .completed(let result) = scanner.state else { Issue.record("did not complete: \(scanner.state)"); return }
        #expect(result.data == message)
        await scanner.stop()
    }

    @Test func strayCodeKeepsProgressAndRecordsRejection() async throws {
        let source = ManualCodeSource()
        let scanner = QRScanner(source: source)
        await scanner.start()
        let frames = parts(3)
        source.send(frames[0])
        source.send(frames[1])
        await settle(scanner, codes: 2)
        let before = scanner.progress
        source.send("https://stray")
        await settle(scanner, codes: 3)
        #expect(scanner.progress == before)
        #expect(scanner.lastRejection == .textDuringCollection)
        #expect(scanner.state == .scanning)
        await scanner.stop()
    }
}
