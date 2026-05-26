// Copyright PolyAI Limited

import XCTest

/// End-to-end XCUITests for the standard UIKit app, driven against the live dev
/// backend (WebbyChat). 02 introduces the "80% app" surface, so this covers the
/// features its README describes: greeting + suggestion pills (typing throttle,
/// delivery dots) and the End -> Start New Conversation flow.
///
/// Mirrors `Examples/SwiftUI/02-Standard` coverage adapted to UIKit
/// (auto-connect, a UITableView transcript, a separate suggestions row of
/// UIButton pills, the "End" nav button, and the "Start New Conversation"
/// ended-footer button).
final class StandardUIKitFlowTests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-uiTestFreshStart"]
        app.launch()
        connectFresh()
    }

    // MARK: - Tests

    /// Greeting renders, suggestion pills are present, and tapping one sends it
    /// and produces a reply (delivery + suggestions in one path).
    func test_greeting_and_suggestionTap() {
        XCTAssertTrue(labelExists(containing: "Webchat", timeout: 25)
                      || labelExists(containing: "Welcome", timeout: 1),
                      "greeting renders after connect")
        guard let suggestion = firstSuggestionLabel(timeout: 20) else {
            return XCTFail("greeting should surface suggestion pills")
        }
        let before = labelSnapshot()
        tapSuggestion(suggestion)
        XCTAssertTrue(labelExists(containing: suggestion, timeout: 12),
                      "tapped suggestion is sent as a user message")
        XCTAssertTrue(waitForNewReply(before: before), "agent replies to the suggestion")
    }

    /// Typing into the composer and sending renders the user bubble and a reply.
    func test_send_and_receiveReply() {
        let before = labelSnapshot()
        send("hello from xcuitest")
        XCTAssertTrue(labelExists(containing: "hello from xcuitest", timeout: 15),
                      "user message renders")
        XCTAssertTrue(waitForNewReply(before: before), "agent reply appears")
    }

    /// End flips to the ended footer; Start New Conversation resets it.
    func test_endChat_and_startNew() {
        let before = labelSnapshot()
        send("hello")
        XCTAssertTrue(waitForNewReply(before: before), "agent replies")

        let endButton = app.buttons["End"]
        XCTAssertTrue(endButton.waitForExistence(timeout: 8), "End button present")
        endButton.tap()

        let startNew = app.buttons["Start New Conversation"]
        XCTAssertTrue(startNew.waitForExistence(timeout: 10),
                      "ended footer with Start New Conversation appears")
        startNew.tap()

        XCTAssertNotNil(firstSuggestionLabel(timeout: 25),
                        "start-new surfaces a fresh greeting with suggestions")
    }

    /// A multi-turn conversation: each user message gets its own agent reply.
    /// Snapshots *after* the user bubble renders so the wait detects the agent's
    /// reply specifically (not the user echo).
    func test_multiTurnConversation() {
        // Distinct prompts whose replies are plain text (so each reply registers
        // as new, queryable static text in both frameworks). Link/carousel
        // replies render in non-staticText views — covered by their own tests.
        let turns = ["what services do you offer?",
                     "how do i get started?",
                     "who are your typical customers?"]
        for (i, text) in turns.enumerated() {
            let before = labelSnapshot()
            send(text)
            XCTAssertTrue(labelExists(containing: text, timeout: 15),
                          "turn \(i + 1): user message renders")
            XCTAssertTrue(waitForReply(notContaining: text, since: before, timeout: 90),
                          "turn \(i + 1): agent replies")
        }
    }

    /// Waits for a new on-screen text not in `before` and not the user's own
    /// message — i.e. the agent's reply. Baseline is taken *before* sending so a
    /// fast reply isn't accidentally folded into it (which a snapshot taken after
    /// the user bubble can do, since element enumeration isn't instant).
    private func waitForReply(notContaining userText: String, since before: Set<String>, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let now = app.staticTexts.allElementsBoundByIndex.map { $0.label }
            if now.contains(where: { !$0.isEmpty && !before.contains($0) && !$0.contains(userText) }) {
                return true
            }
            usleep(500_000)
        }
        return false
    }

    // MARK: - Flow helpers

    /// 02 auto-connects (no connect screen): just wait for the composer.
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

    private var suggestionPills: XCUIElementQuery {
        app.buttons.matching(identifier: "suggestionPill")
    }

    private func firstSuggestionLabel(timeout: TimeInterval) -> String? {
        guard suggestionPills.firstMatch.waitForExistence(timeout: timeout) else { return nil }
        let label = suggestionPills.firstMatch.label
        let prefix = "Suggested reply: "
        return label.hasPrefix(prefix) ? String(label.dropFirst(prefix.count)) : label
    }

    private func tapSuggestion(_ text: String) {
        let byLabel = app.buttons["Suggested reply: \(text)"]
        if byLabel.exists { byLabel.tap() } else { suggestionPills.firstMatch.tap() }
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
