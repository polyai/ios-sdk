// Copyright PolyAI Limited

import XCTest
@testable import PolyMessaging

/// Opt-in **live** messaging integration probe. Drives the real public path —
/// `PolyMessaging.start` → `ChatSession` → the live WebSocket — and asserts
/// a full minimal conversation: the agent greets on join, and replies to a user
/// message. This is the first end-to-end check of auth → session → WS → join →
/// message → reply against a real backend (the deterministic equivalents live in
/// `E2EScenarioTests`/`ChatSessionTests` over a `MockConnection`).
///
/// Skipped by default (it hits the network). Run with:
///
///     POLY_LIVE=1 swift test --filter LiveMessagingProbeTests
///
/// The agent always opens with its own configured welcome — clients can't override
/// it. The SDK sends a plain `EVENT_TYPE_REQUEST_POLY_AGENT_JOIN` with an empty
/// payload (the backend rejects any custom greeting variant).
@MainActor
final class LiveMessagingProbeTests: XCTestCase {

    func test_liveConversation_agentGreetsAndReplies() async throws {
        let session = PolyMessaging.start(try liveConfigOrSkip())

        let greeted = await waitUntil(session, timeout: 45) { $0.agentMessages.isEmpty == false }
        let greeting = session.agentMessages.first?.text
        print("LIVE probe — agent greeting: \(greeting ?? "<none>")")
        print("LIVE probe — connection=\(session.connection) failure=\(String(describing: session.failureReason))")
        XCTAssertTrue(greeted, "agent should send an opening message on join")

        let greetingCount = session.agentMessages.count
        try await session.send("Hello, what are your opening hours?")
        let replied = await waitUntil(session, timeout: 45) { $0.agentMessages.count > greetingCount }
        print("LIVE probe — agent reply: \(session.agentMessages.last?.text ?? "<none>")")
        XCTAssertTrue(replied, "agent should reply to the user message")

        await session.client.shutdown()
    }

    /// Drives the dev "WebbyChat" agent's reliable triggers (also used by the
    /// FullReference XCUITests): "send me a link to google" and "end the convo".
    func test_liveRichConversation_carouselLinkAndEnd() async throws {
        let session = PolyMessaging.start(try liveConfigOrSkip())

        let greeted = await waitUntil(session, timeout: 45) { $0.agentMessages.isEmpty == false }
        XCTAssertTrue(greeted, "agent should greet on join")
        let greeting = session.agentMessages.first
        print("LIVE rich — greeting: \(greeting?.text ?? "<none>")")
        print("LIVE rich — greeting suggestions=\(greeting?.suggestions.count ?? 0) attachments=\(greeting?.attachments.count ?? 0)")

        XCTAssertFalse(greeting?.suggestions.isEmpty ?? true,
                       "greeting should carry response-suggestion pills")
        // Attachment may land a frame after the message, so wait for it.
        let hasCarousel = await waitUntil(session, timeout: 10) {
            $0.agentMessages.contains { !$0.attachments.isEmpty }
        }
        XCTAssertTrue(hasCarousel, "greeting should carry an attachment (the carousel)")
        if let att = session.agentMessages.flatMap({ $0.attachments }).first {
            print("LIVE rich — attachment type=\(att.contentType.rawValue) url=\(att.contentUrl?.absoluteString ?? "nil")")
        }

        var count = session.agentMessages.count
        try await session.send("send me a link to google")
        let gotLink = await waitUntil(session, timeout: 60) {
            $0.agentMessages.count > count &&
            ($0.agentMessages.last?.text.lowercased().contains("http") ?? false)
        }
        print("LIVE rich — link reply: \(session.agentMessages.last?.text ?? "<none>")")
        XCTAssertTrue(gotLink, "asking for a link should return a reply containing a URL")

        // Server SESSION_END flips hasEnded.
        count = session.agentMessages.count
        try await session.send("end the convo")
        let ended = await waitUntil(session, timeout: 60) { $0.hasEnded }
        print("LIVE rich — hasEnded=\(session.hasEnded) connection=\(session.connection)")
        XCTAssertTrue(ended, "asking the agent to end should end the conversation (hasEnded == true)")

        await session.client.shutdown()
    }

    /// Skips when no token is set. A connector token is cluster-scoped: with a
    /// host identifier we target that named cluster (default "dev"), else prod US.
    private func liveConfigOrSkip() throws -> Configuration {
        let env = ProcessInfo.processInfo.environment
        let token = env["POLY_CONNECTOR_TOKEN"] ?? env["POLY_LIVE_TOKEN"] ?? ""
        try XCTSkipUnless(
            !token.isEmpty,
            "Set POLY_CONNECTOR_TOKEN (or POLY_LIVE_TOKEN) to run the live messaging probe"
        )
        if let host = env["POLY_HOST_IDENTIFIER"] {
            return .init(
                apiKey: token,
                environment: .cluster(env["POLY_CLUSTER"] ?? "dev"),
                hostIdentifier: host
            )
        }
        return .init(apiKey: token, environment: .us)
    }

    private func waitUntil(_ s: ChatSession, timeout: TimeInterval, _ cond: (ChatSession) -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond(s) { return true }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return cond(s)
    }
}
