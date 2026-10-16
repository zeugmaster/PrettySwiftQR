import XCTest

/// Captures the appear/disappear reveal of the display demo frame by frame.
///
/// The screenshots are attached to the test result. Set the environment
/// variable `REVEAL_CAPTURE_DIR` on the test runner (`TEST_RUNNER_REVEAL_CAPTURE_DIR`
/// with `xcodebuild`) to also write them as PNG files on the host.
final class RevealCaptureUITests: XCTestCase {
    @MainActor
    func testToggleCapturesRevealFrames() throws {
        let app = XCUIApplication()
        app.launch()

        let toggle = app.switches["Show code"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "Show code toggle not found")
        sleep(2) // initial encode + reveal settle
        capture(name: "steady", frames: 1)

        flip(toggle, expecting: "0")
        capture(name: "hide", frames: 14)
        sleep(1)

        flip(toggle, expecting: "1")
        capture(name: "show", frames: 14)
        sleep(1)

        // Payload swap (static → animated): the old code dissolves while the new one grows.
        let animatedMode = app.buttons["Animated"].firstMatch
        XCTAssertTrue(animatedMode.waitForExistence(timeout: 5), "Mode picker not found")
        animatedMode.tap()
        capture(name: "swap", frames: 14)
    }

    /// Taps the switch, gives its value a moment to change, and falls back to
    /// tapping the knob directly if the row did not toggle. (A predicate
    /// expectation polls too slowly for this and would toggle twice.)
    @MainActor
    private func flip(_ toggle: XCUIElement, expecting value: String) {
        if toggle.switches.count > 0 {
            toggle.switches.firstMatch.tap()
        } else {
            toggle.tap()
        }
        for _ in 0..<10 where (toggle.value as? String) != value {
            usleep(100_000)
        }
        if (toggle.value as? String) != value {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        }
    }

    @MainActor
    private func capture(name: String, frames: Int) {
        let directory = ProcessInfo.processInfo.environment["REVEAL_CAPTURE_DIR"].map { URL(fileURLWithPath: $0) }
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let start = Date()
        for index in 0..<frames {
            let shot = XCUIScreen.main.screenshot()
            let elapsed = Int(Date().timeIntervalSince(start) * 1000)
            let label = String(format: "%@-%02d-%04dms", name, index, elapsed)
            let attachment = XCTAttachment(screenshot: shot)
            attachment.name = label
            attachment.lifetime = .keepAlways
            add(attachment)
            if let directory {
                try? shot.pngRepresentation.write(to: directory.appendingPathComponent(label + ".png"))
            }
        }
    }
}
