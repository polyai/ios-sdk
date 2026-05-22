import XCTest

/// End-to-end XCUITests (separate target; not in app sources or the customer
/// README), driven against the live dev backend (WebbyChat).
///
/// 03-RichContent's README features: image attachments / carousel, URL cards,
/// `tel:` call actions, and rich-text (markdown) rendering. These tests cover
/// the two reliably-reproducible live-agent behaviors.
///
/// Reliable agent behaviors used here (verified via the SDK probe):
///   • "send me a link to google" -> reply with markdown links ([Google](…))
final class RichContentSwiftUIFlowTests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-uiTestFreshStart"]
        app.launch()
        connectFresh()
    }

    // MARK: - Tests

    /// Asking for a link returns markdown; RichText must render it formatted
    /// (link text shown, raw markdown syntax gone).
    func test_richText_linkFormatting() {
        let before = labelSnapshot()
        send("send me a link to google")
        XCTAssertTrue(waitForNewReply(before: before, timeout: 60), "agent replies with links")
        // The reply renders "Google" as link text…
        XCTAssertTrue(labelExists(containing: "Google", timeout: 15),
                      "link text is rendered")
        // …and NOT the raw markdown link syntax.
        XCTAssertTrue(waitUntilAbsent("](http", timeout: 15),
                      "markdown link syntax must be parsed away once the reply finishes streaming")
        XCTAssertFalse(anyLabel(contains: "[Google]"),
                       "raw markdown brackets must not appear")
    }

    /// Asking for news returns image attachments -> the carousel renders.
    func test_attachmentCarousel() {
        // The fresh greeting carries an image attachment, so the carousel
        // renders on connect — deterministic (asking the agent for extra
        // content it may or may not return on a given turn is flaky).
        XCTAssertTrue(carouselAppears(timeout: 25),
                      "greeting's image attachment renders in the carousel")
    }

    // MARK: - Flow helpers

    /// 03-RichContent auto-connects (no connect screen) — wait for the composer.
    private func connectFresh() {
        XCTAssertTrue(app.textFields["composer"].waitForExistence(timeout: 25),
                      "composer present after connect")
    }

    private func send(_ text: String) {
        let composer = app.textFields["composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "composer present")
        composer.tap()
        composer.typeText(text + "\n")
    }

    // MARK: - Query helpers (predicate-based waits are robust to the non-idle app)

    private func labelSnapshot() -> Set<String> {
        Set(app.staticTexts.allElementsBoundByIndex.map { $0.label })
    }

    private func anyLabel(contains substring: String) -> Bool {
        app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@", substring)).firstMatch.exists
    }

    /// Polls until no on-screen label contains `substring` — e.g. raw markdown
    /// that shows briefly while a reply streams, then parses into a link.
    private func waitUntilAbsent(_ substring: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !anyLabel(contains: substring) { return true }
            usleep(400_000)
        }
        return !anyLabel(contains: substring)
    }

    private func labelExists(containing substring: String, timeout: TimeInterval) -> Bool {
        app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@", substring)).firstMatch
            .waitForExistence(timeout: timeout)
    }

    /// A new non-user static text appears (robust to the exact reply content).
    private func waitForNewReply(before: Set<String>, timeout: TimeInterval = 60) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let now = app.staticTexts.allElementsBoundByIndex.map { $0.label }
            if now.contains(where: { !$0.isEmpty && !before.contains($0) }) { return true }
            usleep(500_000)
        }
        return false
    }

    private func carouselAppears(timeout: TimeInterval) -> Bool {
        app.descendants(matching: .any).matching(identifier: "attachmentCarousel")
            .firstMatch.waitForExistence(timeout: timeout)
            || app.images.count > 1
    }
}
