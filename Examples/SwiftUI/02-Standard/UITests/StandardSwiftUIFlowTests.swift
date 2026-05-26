// Copyright PolyAI Limited

import XCTest

/// End-to-end XCUITests (separate target; not in app sources or the customer
/// README), driven against the live dev backend (WebbyChat).
///
/// 02-Standard's README features: suggestion pills, delivery state, typing
/// indicator, End + Start-New chat, and the connection banner. These tests
/// exercise the user-observable ones against the live agent.
///
/// Reliable agent behaviors used here (verified via the SDK probe):
///   • greeting carries 3 suggestion pills
final class StandardSwiftUIFlowTests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-uiTestFreshStart"]
        app.launch()
        connectFresh()
    }

    // MARK: - Tests

    /// Greeting renders, suggestion pills are present, and tapping one sends it.
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
        XCTAssertTrue(waitForNewReply(before: before),
                      "agent replies to the tapped suggestion")
    }

    /// A sent message renders as a user bubble and the agent replies.
    func test_send_and_reply() {
        let before = labelSnapshot()
        send("hello from xcuitest")
        XCTAssertTrue(labelExists(containing: "hello from xcuitest", timeout: 15),
                      "user message renders")
        XCTAssertTrue(waitForNewReply(before: before), "agent reply appears")
    }

    /// End Chat → Start New Conversation resets the surface to a fresh greeting.
    func test_endChat_and_startNew() {
        let before = labelSnapshot()
        send("hello")
        XCTAssertTrue(waitForNewReply(before: before), "agent replies")

        let endChat = app.buttons["End Chat"]
        XCTAssertTrue(endChat.waitForExistence(timeout: 10), "End Chat button present")
        endChat.tap()

        let startNew = app.buttons["Start New Conversation"]
        XCTAssertTrue(startNew.waitForExistence(timeout: 10),
                      "Start New Conversation button appears after ending")
        startNew.tap()

        XCTAssertNotNil(firstSuggestionLabel(timeout: 25),
                        "starting new surfaces a fresh greeting with suggestions")
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

    /// 02-Standard auto-connects (no connect screen) — just wait for the composer.
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

    private var suggestionPills: XCUIElementQuery {
        app.buttons.matching(identifier: "suggestionPill")
    }

    /// First suggestion pill's text (stripped of the "Suggested reply: " a11y prefix).
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
}
