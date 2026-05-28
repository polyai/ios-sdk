// Copyright PolyAI Limited

import XCTest

/// End-to-end XCUITests for the resilience UIKit app, driven against the live
/// live backend. 04's headline features (offline banner, loading
/// skeleton, terminal error screen) need network control that XCUITest cannot
/// drive, so those are covered by unit tests; here we assert the chat works
/// end-to-end on top of all the resilience scaffolding: greeting + send/reply.
///
/// Mirrors `Examples/SwiftUI/04-Resilience` coverage adapted to UIKit
/// (auto-connect, a UITableView transcript, the "composer" text field).
final class ResilienceUIKitFlowTests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-uiTestFreshStart"]
        app.launch()
        connectFresh()
    }

    // MARK: - Tests

    /// Greeting renders after the socket opens (skeleton -> chat), proving the
    /// resilience scaffolding doesn't block a normal happy-path connect.
    func test_greeting_renders() {
        XCTAssertTrue(labelExists(containing: "Webchat", timeout: 25)
                      || labelExists(containing: "Welcome", timeout: 1),
                      "greeting renders after connect")
    }

    /// Sending a message renders the user bubble and an agent reply.
    func test_send_and_receiveReply() {
        let before = labelSnapshot()
        send("hello from xcuitest")
        XCTAssertTrue(labelExists(containing: "hello from xcuitest", timeout: 15),
                      "user message renders")
        XCTAssertTrue(waitForNewReply(before: before), "agent reply appears")
    }

    // MARK: - Flow helpers

    /// 04 auto-connects (no connect screen): just wait for the composer.
    private func connectFresh() {
        XCTAssertTrue(app.textFields["composer"].waitForExistence(timeout: 25),
                      "composer present after auto-connect")
    }

    private func send(_ text: String) {
        let composer = app.textFields["composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "composer present")
        composer.tap()
        composer.typeText(text)
        app.buttons["sendButton"].tap()
    }

    // MARK: - Query helpers

    private func labelSnapshot() -> Set<String> {
        Set(app.staticTexts.allElementsBoundByIndex.map { $0.label })
    }

    private func labelExists(containing substring: String, timeout: TimeInterval) -> Bool {
        app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@", substring)).firstMatch
            .waitForExistence(timeout: timeout)
    }

    private func waitForNewReply(before: Set<String>, timeout: TimeInterval = 60) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let now = app.staticTexts.allElementsBoundByIndex.map { $0.label }
            if now.contains(where: { !$0.isEmpty && !before.contains($0) }) { return true }
            usleep(500_000)
        }
        return false
    }
}
