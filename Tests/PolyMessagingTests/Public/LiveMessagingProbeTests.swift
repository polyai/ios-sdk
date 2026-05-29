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

    /// API key for the live probe. Supply it via the `POLY_LIVE_TOKEN`
    /// environment variable when running; defaults to empty otherwise.
    private let devToken = ""

    func test_liveConversation_agentGreetsAndReplies() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["POLY_LIVE"] == "1",
            "Set POLY_LIVE=1 to run the live messaging probe"
        )

        let token = ProcessInfo.processInfo.environment["POLY_LIVE_TOKEN"] ?? devToken
        let session = PolyMessaging.start(.init(apiKey: token, environment: .us))

        // 1) Agent greets on join.
        let greeted = await waitUntil(session, timeout: 45) { $0.agentMessages.isEmpty == false }
        let greeting = session.agentMessages.first?.text
        print("LIVE probe — agent greeting: \(greeting ?? "<none>")")
        print("LIVE probe — connection=\(session.connection) failure=\(String(describing: session.failureReason))")
        XCTAssertTrue(greeted, "agent should send an opening message on join")

        // 2) Agent replies to a user message (a real back-and-forth turn).
        let greetingCount = session.agentMessages.count
        try await session.send("Hello, what are your opening hours?")
        let replied = await waitUntil(session, timeout: 45) { $0.agentMessages.count > greetingCount }
        print("LIVE probe — agent reply: \(session.agentMessages.last?.text ?? "<none>")")
        XCTAssertTrue(replied, "agent should reply to the user message")

        await session.client.shutdown()
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
