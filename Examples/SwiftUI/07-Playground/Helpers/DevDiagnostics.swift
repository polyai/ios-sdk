import Foundation
import SwiftUI
import PolyMessaging

@MainActor
final class DevDiagnostics: ObservableObject {

    // MARK: - Live state

    @Published private(set) var sessionId: String? = nil
    @Published private(set) var sessionStatus: String = "idle"
    @Published private(set) var isReady: Bool = false
    /// Cursor the SDK uses on reconnect — useful for checking EVENT_BATCH replay.
    @Published private(set) var lastSequence: Int = 0
    @Published private(set) var connectionLabel: String = "idle"
    @Published private(set) var streamingCapability: Bool? = nil
    @Published private(set) var maxMessageSize: Int? = nil
    @Published private(set) var serverHeartbeatSeconds: Int? = nil
    @Published private(set) var serverMaxReconnectAttempts: Int? = nil

    // MARK: - Counters

    @Published private(set) var framesIn: Int = 0
    @Published private(set) var framesOut: Int = 0
    @Published private(set) var chunksIn: Int = 0
    @Published private(set) var heartbeatsIn: Int = 0
    @Published private(set) var reconnectCount: Int = 0

    @Published private(set) var lastInboundAt: Date? = nil

    // MARK: - Internals

    private var eventTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?

    func attach(to client: PolyMessagingClient) {
        reset()

        let events = client.events
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.consume(event)
            }
        }

        let status = client.connectionStatus
        statusTask = Task { [weak self] in
            for await s in status {
                guard let self else { return }
                await self.consume(status: s)
            }
        }

        let state = client.sessionState
        stateTask = Task { [weak self] in
            for await s in state {
                guard let self else { return }
                self.sessionId = s.sessionId
                self.sessionStatus = "\(s.status)"
                self.isReady = s.isReady
            }
        }
    }

    func reset() {
        eventTask?.cancel(); eventTask = nil
        statusTask?.cancel(); statusTask = nil
        stateTask?.cancel(); stateTask = nil
        sessionId = nil
        sessionStatus = "idle"
        isReady = false
        lastSequence = 0
        connectionLabel = "idle"
        streamingCapability = nil
        maxMessageSize = nil
        serverHeartbeatSeconds = nil
        serverMaxReconnectAttempts = nil
        framesIn = 0
        framesOut = 0
        chunksIn = 0
        heartbeatsIn = 0
        reconnectCount = 0
        lastInboundAt = nil
    }

    /// SDK doesn't expose an outbound-frame stream, so the app tracks this manually.
    func recordOutgoing() {
        framesOut += 1
    }

    // MARK: - Stream handlers

    private func consume(event: MessagingEvent) {
        framesIn += 1
        lastInboundAt = Date()

        if let seq = event.envelope?.sequence, seq > lastSequence {
            lastSequence = seq
        }

        switch event {
        case .sessionStart(_, let payload):
            streamingCapability = payload.capabilities.streaming
            let m = payload.capabilities.maxMessageSize
            maxMessageSize = m
            serverHeartbeatSeconds = payload.capabilities.heartbeatIntervalSeconds
            serverMaxReconnectAttempts = payload.capabilities.maxReconnectAttempts
        case .agentMessageChunk:
            chunksIn += 1
        case .heartbeat:
            heartbeatsIn += 1
        default:
            break
        }
    }

    private func consume(_ event: MessagingEvent) async { consume(event: event) }

    private func consume(status: ConnectionStatus) async {
        connectionLabel = label(for: status)
        if case .reconnecting = status {
            reconnectCount += 1
        }
    }

    private func label(for status: ConnectionStatus) -> String {
        switch status {
        case .idle: return "idle"
        case .connecting: return "connecting"
        case .open: return "open"
        case .reconnecting(let n): return "reconnecting (\(n))"
        case .closing: return "closing"
        case .closed: return "closed"
        case .failed: return "failed"
        }
    }
}
