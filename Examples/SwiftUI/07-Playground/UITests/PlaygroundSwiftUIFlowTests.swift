// Copyright PolyAI Limited

import XCTest

/// End-to-end XCUITest (separate target; not in app sources or the customer
/// README), driven against the live dev backend (WebbyChat).
///
/// 07-Playground is the developer toolbox (settings, diagnostics, logs) on top
/// of 06-FullReference. Its connect screen exposes a "Dev Settings" gear, so the
/// dev panel can be driven there while the app is fully idle (no agent activity).
/// The conversation itself is NOT exercised here: 07's always-on developer
/// overlays (the diagnostics recorder re-renders on every event; the optional
/// DebugStrip adds a 1 Hz clock) keep SwiftUI non-idle whenever the agent is
/// active, so XCUITest can't snapshot mid-conversation. 07's chat surface is
/// identical to 06-FullReference (whose UITest drives greeting / suggestion /
/// link / carousel / start-new), and the message state machine is covered by
/// ChatSessionTests.
final class PlaygroundSwiftUIFlowTests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-uiTestFreshStart"]
        app.launch()
    }

    // MARK: - Tests

    /// Tapping Start Chat establishes a live session (the composer appears only
    /// after the WebSocket connects). Queried pre-greeting while idle.
    func test_connects_to_live_backend() {
        startChat()
        XCTAssertTrue(app.textFields["composer"].waitForExistence(timeout: 25),
                      "composer present after connecting to the live backend")
    }

    /// The developer panel: tapping the Dev Settings gear on the connect screen
    /// opens the dev toolbox and Done dismisses it back to the connect screen.
    /// Driven on the connect screen because that's idle (07's in-chat diagnostics
    /// overlay re-renders continuously while the agent streams, which XCUITest
    /// can't snapshot). The "Apply & Start New Session" → new-chat path is
    /// exercised in the UIKit 07 test (idle-stable) and the start-new flow is
    /// covered by 05/06 + ChatSessionTests.
    func test_devSettingsPanel_opensAndCloses() {
        let gear = app.buttons["Dev Settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 15),
                      "Dev Settings gear is available on the connect screen")
        gear.tap()

        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 10),
                      "the dev settings panel opened")
        XCTAssertTrue(app.staticTexts["Dev Settings"].waitForExistence(timeout: 3),
                      "the panel is the Dev Settings toolbox")

        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Start Chat"].waitForExistence(timeout: 10),
                      "dismissing returns to the connect screen")
    }

    // MARK: - Helpers

    private func startChat() {
        let start = app.buttons["Start Chat"]
        if start.waitForExistence(timeout: 8) { start.tap() }
        else if app.buttons["Start New Chat"].waitForExistence(timeout: 3) { app.buttons["Start New Chat"].tap() }
        else if app.buttons["Resume Chat"].waitForExistence(timeout: 3) { app.buttons["Resume Chat"].tap() }
    }
}
