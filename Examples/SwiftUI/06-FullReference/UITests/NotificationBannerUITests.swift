// Copyright PolyAI Limited

import XCTest

/// End-to-end check for the in-app new-message notification banner
/// (Components/NewMessageNotifier.swift) — driven against the live dev backend.
///
/// Confirms the foreground banner: with the app open, send a message,
/// and when the agent replies a local notification banner is presented by
/// SpringBoard. A screenshot of the banner is saved to the test artifacts.
///
/// 06-FullReference uses a connect screen — tap the fresh-start button first.
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

    /// Reboot/resume dedupe: notify for a reply, then relaunch and resume the
    /// same conversation. The SDK replays history (re-emitting `.agentMessage`),
    /// but the persisted `messageId` store must suppress any second banner.
    func test_resume_doesNotReNotifyAlreadyShownMessages() {
        // Launch 1 (fresh, from setUp): get at least one banner so its messageId
        // is persisted to the notified store.
        connect()
        grantNotificationsIfAsked(springboard)
        sleep(5)
        send("hello there")
        var sawFirst = false
        let firstDeadline = Date().addingTimeInterval(90)
        while Date() < firstDeadline {
            if bannerVisible(springboard) { sawFirst = true; break }
            usleep(300_000)
        }
        XCTAssertTrue(sawFirst, "precondition: launch 1 notified for the reply")

        // Relaunch WITHOUT -uiTestFreshStart → resume the same session.
        app.terminate()
        app.launchArguments = app.launchArguments.filter { $0 != "-uiTestFreshStart" }
        app.launch()
        grantNotificationsIfAsked(springboard)   // already granted — no-op
        resume()

        // The replayed greeting + reply are already in the persisted store, so
        // no banner should appear during the resume window.
        var sawDuplicate = false
        let watch = Date().addingTimeInterval(20)
        while Date() < watch {
            if bannerVisible(springboard) {
                attach(XCUIScreen.main.screenshot(), name: "UNEXPECTED-resume-banner")
                sawDuplicate = true
                break
            }
            usleep(300_000)
        }
        attach(XCUIScreen.main.screenshot(), name: "resume-no-banner")
        XCTAssertFalse(sawDuplicate, "resume must not re-notify already-shown messages")
    }

    // MARK: - Per-example flow

    /// Tap the resume button specifically (06's connect screen shows "Resume
    /// Chat" + "Start New Chat" when a session is resumable — don't start fresh).
    private func resume() {
        let resumeBtn = app.buttons["Resume Chat"]
        XCTAssertTrue(resumeBtn.waitForExistence(timeout: 10), "Resume Chat offered after relaunch")
        resumeBtn.tap()
        XCTAssertTrue(app.textFields["composer"].waitForExistence(timeout: 30),
                      "composer present after resume")
    }

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
        composer.typeText(text + "\n")   // SwiftUI composer submits on return
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
