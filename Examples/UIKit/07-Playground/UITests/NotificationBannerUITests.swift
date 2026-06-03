// Copyright PolyAI Limited

import XCTest

/// End-to-end check for the in-app new-message notification banner
/// (Components/NewMessageNotifier.swift) — driven against the live dev backend.
///
/// Confirms the foreground banner: with the app open, send a message,
/// and when the agent replies a local notification banner is presented by
/// SpringBoard. A screenshot of the banner is saved to the test artifacts.
///
/// 07-Playground uses a connect screen — tap the fresh-start button first.
final class NotificationBannerUITests: XCTestCase {

    private var app: XCUIApplication!
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments += ["-uiTestFreshStart"]
        app.launch()
    }

    func test_newMessageBanner_appearsWhileForeground() {
        connect()
        grantNotificationsIfAsked(springboard)   // dialog appears after connecting
        sleep(5)   // let the greeting's banner present + auto-dismiss

        attach(app.screenshot(), name: "1-before-send")
        send("hello there")

        var sawBanner = false
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            if bannerVisible(springboard) {
                attach(XCUIScreen.main.screenshot(), name: "2-BANNER")
                sawBanner = true
                break
            }
            usleep(300_000)
        }
        attach(XCUIScreen.main.screenshot(), name: "3-after")

        XCTAssertTrue(sawBanner, "foreground notification banner presented for the agent reply")
    }

    // MARK: - Per-example flow

    private func connect() {
        let start = app.buttons["Start Chat"]
        if start.waitForExistence(timeout: 8) { start.tap() }
        else if app.buttons["Start New Chat"].waitForExistence(timeout: 3) { app.buttons["Start New Chat"].tap() }
        else if app.buttons["Resume Chat"].waitForExistence(timeout: 3) { app.buttons["Resume Chat"].tap() }
        XCTAssertTrue(app.textFields["composer"].waitForExistence(timeout: 30),
                      "composer present after connect")
    }

    private func send(_ text: String) {
        let composer = app.textFields["composer"]
        composer.tap()
        _ = app.keyboards.element.waitForExistence(timeout: 5)  // avoid the no-focus typeText flake
        composer.typeText(text)
        app.buttons["sendButton"].tap()
    }

    // MARK: - Shared banner helpers

    private func attach(_ shot: XCUIScreenshot, name: String) {
        let a = XCTAttachment(screenshot: shot)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}

func grantNotificationsIfAsked(_ springboard: XCUIApplication) {
    let allow = springboard.buttons["Allow"]
    if allow.waitForExistence(timeout: 10) { allow.tap() }
}

/// A presented banner lives in SpringBoard, not the app. The notifier titles
/// every alert "New message" (the agent has no display name on dev), so that
/// label is the reliable signal.
func bannerVisible(_ springboard: XCUIApplication) -> Bool {
    springboard.staticTexts
        .containing(NSPredicate(format: "label CONTAINS[c] %@", "New message"))
        .firstMatch.exists
}
