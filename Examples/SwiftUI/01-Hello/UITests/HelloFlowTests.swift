// Copyright PolyAI Limited

import XCTest

/// End-to-end XCUITest (separate target; not in app sources or the customer
/// README), driven against the live dev backend (WebbyChat).
///
/// 01-Hello is the smallest possible chat — its README is just
/// initialize + send + render — so this test stays minimal:
///   connect (auto) → greeting → send → user bubble → agent reply.
final class HelloSwiftUIFlowTests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-uiTestFreshStart"]
        app.launch()
        connectFresh()
    }

    // MARK: - Test

    /// The whole 01-Hello surface: greeting renders, a sent message shows as a
    /// user bubble, and the agent replies.
    func test_send_and_reply() {
        XCTAssertTrue(labelExists(containing: "Webchat", timeout: 25)
                      || labelExists(containing: "Welcome", timeout: 1),
                      "greeting renders after connect")

        let before = labelSnapshot()
        send("hello from xcuitest")
        XCTAssertTrue(labelExists(containing: "hello from xcuitest", timeout: 15),
                      "user message renders")
        XCTAssertTrue(waitForNewReply(before: before), "agent reply appears")
    }

    // MARK: - Flow helpers

    /// 01-Hello auto-connects (no connect screen) — just wait for the composer.
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
            if now.contains(where: {
                !$0.isEmpty && !before.contains($0)
                    && !$0.localizedCaseInsensitiveContains("hello from xcuitest")
            }) { return true }
            usleep(500_000)
        }
        return false
    }
}
