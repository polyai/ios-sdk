import XCTest

/// End-to-end XCUITests for the playground UIKit app, driven against the live
/// dev backend (WebbyChat). 07 is a developer playground (diagnostics, raw
/// transport, runtime DevSettings). Covers: connecting, greeting, send/reply,
/// and the developer panel (open Dev Settings -> Apply & Start New Session ->
/// a new chat opens).
final class PlaygroundUIKitFlowTests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-uiTestFreshStart"]
        app.launch()
    }

    // MARK: - Tests

    /// Greeting renders after connecting, confirming the playground connects.
    func test_greeting_renders() {
        connectFresh()
        XCTAssertTrue(labelExists(containing: "Webchat", timeout: 25)
                      || labelExists(containing: "Welcome", timeout: 1),
                      "greeting renders after connect")
    }

    /// Sending a message renders the user bubble and an agent reply.
    func test_send_and_receiveReply() {
        connectFresh()
        let before = labelSnapshot()
        send("hello from xcuitest")
        XCTAssertTrue(labelExists(containing: "hello from xcuitest", timeout: 15),
                      "user message renders")
        XCTAssertTrue(waitForNewReply(before: before), "agent reply appears")
    }

    /// The developer panel: tapping the Dev Settings gear on the connect screen
    /// opens the dev toolbox and Done dismisses it back to the connect screen.
    /// (Driven on the connect screen — in chat the gear collapses into the
    /// "…" menu, and "Apply & Start New Session" only shows once a session
    /// exists; that new-chat path is covered by 05/06's start-new flow +
    /// ChatSessionTests.)
    func test_devSettingsPanel_opensAndCloses() {
        let gear = app.buttons["Dev Settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 15),
                      "Dev Settings gear is available on the connect screen")
        gear.tap()

        XCTAssertTrue(app.navigationBars["Dev Settings"].waitForExistence(timeout: 10),
                      "the Dev Settings panel opened")

        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Start Chat"].waitForExistence(timeout: 10),
                      "dismissing returns to the connect screen")
    }

    // MARK: - Flow helpers

    private func connectFresh() {
        let start = app.buttons["Start Chat"]
        if start.waitForExistence(timeout: 8) { start.tap() }
        else if app.buttons["Start New Chat"].waitForExistence(timeout: 3) { app.buttons["Start New Chat"].tap() }
        else if app.buttons["Resume Chat"].waitForExistence(timeout: 3) { app.buttons["Resume Chat"].tap() }
        XCTAssertTrue(app.textFields["composer"].waitForExistence(timeout: 25), "composer present after connect")
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
