// Copyright PolyAI Limited

import XCTest

/// Dedicated XCUITest (separate target; not in app sources or the customer
/// README). Drives the example's path against the live dev backend:
/// connect → greeting → send → user bubble → agent reply.
final class HelloUIKitFlowTests: XCTestCase {
    func test_connect_send_receiveReply() {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestFreshStart"]
        app.launch()

        // 01-Hello auto-connects (no connect screen).
        // Greeting (best-effort) confirms connect.
        _ = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "Webchat")).firstMatch.waitForExistence(timeout: 20)

        let composer = app.textFields["composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 25), "composer present after connect")
        let before = Set(app.staticTexts.allElementsBoundByIndex.map { $0.label })

        composer.tap()
        composer.typeText("hello from xcuitest")
        let send = app.buttons["sendButton"]
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: send)
        waitForExpectations(timeout: 15)
        send.tap()

        // sending → confirmed: the user bubble renders.
        let userMsg = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "hello from xcuitest")).firstMatch
        XCTAssertTrue(userMsg.waitForExistence(timeout: 15), "user message renders")

        // agent reply: a NEW non-user label appears (robust to suggestion pills).
        XCTAssertTrue(waitForReply(app, before: before), "agent reply appears")
    }

    private func waitForReply(_ app: XCUIApplication, before: Set<String>, timeout: TimeInterval = 35) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for label in app.staticTexts.allElementsBoundByIndex.map({ $0.label }) {
                if !label.isEmpty, !before.contains(label),
                   !label.localizedCaseInsensitiveContains("hello from xcuitest") {
                    return true
                }
            }
            usleep(400_000)
        }
        return false
    }
}
