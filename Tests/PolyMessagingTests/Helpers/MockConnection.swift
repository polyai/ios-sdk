// Copyright PolyAI Limited

import Foundation
@testable import PolyMessaging

final class MockConnection: Connection, @unchecked Sendable {

    var connectCalls: [URL] = []
    var disconnectCalls: [(code: Int, reason: String)] = []
    var sentEvents: [OutgoingEvent] = []
    var sentRawData: [Data] = []

    let openCaster = Multicaster<Void>()
    let closeCaster = Multicaster<ConnectionCloseEvent>()
    let messageCaster = Multicaster<MessagingEvent>()
    let batchCaster = Multicaster<[MessagingEvent]>()
    let rawFrameCaster = Multicaster<Data>()
    let errorCaster = Multicaster<PolyError>()

    private var _status: ConnectionStatus = .idle

    var status: ConnectionStatus {
        get async { _status }
    }

    var openEvents: AsyncStream<Void> { openCaster.subscribe() }
    var closeEvents: AsyncStream<ConnectionCloseEvent> { closeCaster.subscribe() }
    var messages: AsyncStream<MessagingEvent> { messageCaster.subscribe() }
    var batchEvents: AsyncStream<[MessagingEvent]> { batchCaster.subscribe() }
    var rawFrames: AsyncStream<Data> { rawFrameCaster.subscribe() }
    var errors: AsyncStream<PolyError> { errorCaster.subscribe() }

    func connect(url: URL) async {
        connectCalls.append(url)
        _status = .connecting
    }

    func disconnect(code: Int, reason: String) async {
        disconnectCalls.append((code, reason))
        _status = .closed(ConnectionCloseEvent(code: code, reason: reason, wasClean: code == 1000))
    }

    func send(_ event: OutgoingEvent) async {
        sentEvents.append(event)
    }

    func sendRaw(_ data: Data) async {
        sentRawData.append(data)
    }

    // Test helpers

    func simulateOpen() {
        _status = .open
        openCaster.emit(())
    }

    func simulateClose(code: Int, reason: String = "", wasClean: Bool = true) {
        let event = ConnectionCloseEvent(code: code, reason: reason, wasClean: wasClean)
        _status = .closed(event)
        closeCaster.emit(event)
    }

    func simulateMessage(_ event: MessagingEvent) {
        messageCaster.emit(event)
    }

    func simulateError(_ error: PolyError) {
        errorCaster.emit(error)
    }
}
