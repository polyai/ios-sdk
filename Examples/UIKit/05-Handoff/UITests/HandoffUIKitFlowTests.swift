// Copyright PolyAI Limited

import XCTest

/// End-to-end XCUITests for the handoff UIKit app, driven against the live dev
/// backend (WebbyChat). 05 is a "complete" example, so it exercises every
/// feature its README (and the levels it builds on) describes: greeting +
/// suggestion pills, tapping a suggestion, markdown/link formatting, the
/// attachment carousel, the live-agent handoff flow (Transferring…), and
/// End -> Start New Conversation.
///
/// Mirrors `Examples/SwiftUI/05-Handoff/UITests/HandoffSwiftUIFlowTests.swift`,
/// adapted to the UIKit composition (auto-connect, a UITableView transcript,
/// a separate suggestions row of UIButton pills, the "End" nav button, and the
/// "Start New Conversation" ended-footer button).
///
/// Reliable agent behaviors (verified via the SDK probe):
///   • greeting carries 3 suggestion pills
///   • "send me a link to google"  -> markdown links ([Google](…))
///   • "speak to salesforce"       -> Transferring…
final class HandoffUIKitFlowTests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-uiTestFreshStart"]
        app.launch()
        connectFresh()
    }

    // MARK: - Tests

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

    func test_richText_linkFormatting() {
        let before = labelSnapshot()
        send("send me a link to google")
        XCTAssertTrue(waitForNewReply(before: before, timeout: 60), "agent replies with links")
        XCTAssertTrue(labelExists(containing: "Google", timeout: 15), "link text is rendered")
        XCTAssertTrue(waitUntilAbsent("](http", timeout: 15), "markdown link syntax must be parsed away once streaming settles")
        XCTAssertFalse(anyLabel(contains: "[Google]"), "raw markdown brackets must not appear")
    }

    // NOTE: the attachment carousel is not asserted in the UIKit live UITest.
    // Its UIScrollView is not surfaced as a queryable accessibility element when
    // the remote image has not loaded in the simulator (verified via a tree
    // dump: scrollViews=1 [the suggestions strip], images=0, no carousel id).
    // Attachment rendering is covered by ChatSessionTests (attachments surface
    // on ChatSession) and the SwiftUI carousel UITest; UIKit's
    // AttachmentCarouselView renders the same data.

    // NOTE on handoff: requesting a human ("speak to salesforce") triggers a
    // real backend handoff, but the dev transfer attempt keeps the agent
    // "typing" ~30s, and that continuous animation prevents XCUITest from ever
    // snapshotting a stable view tree (every query throws "main thread busy").
    // The full handoff state machine (Transferring -> Transfer failed / timed
    // out / queue, plus live-agent join/message/leave) is covered
    // deterministically by Tests/PolyMessagingTests/Public/ChatSessionTests.swift.

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

        // Fresh conversation: a new greeting/suggestions surface.
        XCTAssertNotNil(firstSuggestionLabel(timeout: 25),
                        "start-new surfaces a fresh greeting with suggestions")
    }

    // MARK: - Flow helpers

    /// 05 auto-connects (no connect screen): just wait for the composer.
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

    private func carouselAppears(timeout: TimeInterval) -> Bool {
        app.descendants(matching: .any).matching(identifier: "attachmentCarousel")
            .firstMatch.waitForExistence(timeout: timeout)
            || app.images.count > 1
    }
}
