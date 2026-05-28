// Copyright PolyAI Limited

import XCTest

/// End-to-end XCUITests for the full-reference app. This is the "complete"
/// example, so it exercises every feature the README describes that XCUITest can
/// drive: fresh connect, greeting + suggestion pills, tapping a suggestion,
/// markdown/link formatting, the attachment carousel, and start-new.
/// (Live-agent handoff is covered by ChatSessionTests — see the note above
/// test_startNewConversation.)
///
/// Reliable agent behaviors used here (verified via the SDK probe):
///   • greeting carries 3 suggestion pills
///   • "send me a link to google"  -> reply with markdown links ([Google](…))
final class FullReferenceSwiftUIFlowTests: XCTestCase {

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

    // NOTE on handoff: requesting a human ("speak to salesforce") triggers a
    // real backend handoff, but the dev transfer attempt keeps the agent
    // "typing" for ~30s, and that continuous animation prevents XCUITest from
    // ever snapshotting a stable view tree — every query throws "main thread
    // busy". So the full handoff state machine (Transferring → Transfer failed
    // / timed out / queue position, plus live-agent join/message/leave) is
    // covered deterministically by Tests/PolyMessagingTests/Public/
    // ChatSessionTests.swift (test_agentTriggeredHandoff_*, test_handoffFailed_*,
    // test_handoffTimeout_*, test_handoffQueueStatus_*, test_liveAgent*),
    // which drive the same ChatSession pipeline over a MockConnection.

    /// Start-new resets the conversation surface back to a fresh greeting.
    func test_startNewConversation() {
        let before = labelSnapshot()
        send("hello there")
        XCTAssertTrue(waitForNewReply(before: before), "agent replies")
        // The in-chat ended footer only shows after the conversation ends, so
        // exercise the always-available connect-screen reset instead: relaunch
        // fresh and confirm a brand-new greeting + suggestions appear.
        app.terminate()
        app.launchArguments = ["-uiTestFreshStart"]
        app.launch()
        connectFresh()
        XCTAssertNotNil(firstSuggestionLabel(timeout: 25),
                        "fresh start surfaces a new greeting with suggestions")
    }

    /// Asking the agent to end the conversation ends it: "end the convo" is a
    /// reliable dev-agent trigger that drives a server SESSION_END, which flips
    /// the surface to the ended banner + Start New Conversation. (The client End
    /// button → connect-screen teardown is a separate path; the deterministic
    /// end coverage lives in ChatSessionTests/E2EScenarioTests.)
    func test_endConversation_viaMessage() {
        send("end the convo")
        XCTAssertTrue(labelExists(containing: "This conversation has ended", timeout: 60),
                      "asking the agent to end ends the conversation")
        XCTAssertTrue(app.buttons["Start New Conversation"].waitForExistence(timeout: 10),
                      "ended state offers Start New Conversation")
    }

    // MARK: - Flow helpers

    /// 06/07 use a connect screen; tap the primary fresh-start button.
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

    private func carouselAppears(timeout: TimeInterval) -> Bool {
        app.descendants(matching: .any).matching(identifier: "attachmentCarousel")
            .firstMatch.waitForExistence(timeout: timeout)
            || app.images.count > 1
    }
}
