// Copyright PolyAI Limited

import XCTest
@testable import PolyMessaging

final class MulticasterReplayTests: XCTestCase {

    // State-like Multicaster (replay=true): late subscriber receives the last
    // emitted value on subscribe. Closes the cold-subscribe race in
    // PolyMessagingClient.connectionStatus / sessionState getters.
    func testReplayDeliversLastValueToLateSubscriber() async {
        let caster = Multicaster<Int>(replayLastValue: true)
        caster.emit(7)
        caster.emit(42)

        var received: [Int] = []
        let task = Task {
            for await value in caster.subscribe() {
                received.append(value)
                if received.count >= 1 { break }
            }
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()

        // Should have received the last value (42), not 7.
        XCTAssertEqual(received, [42])
    }

    // Event-like Multicaster (replay=false): late subscriber sees nothing
    // until the next emit. Prevents replaying old one-shot events.
    func testEventStreamSkipsHistoryOnLateSubscribe() async {
        let caster = Multicaster<Int>(replayLastValue: false)
        caster.emit(1)
        caster.emit(2)

        var received: [Int] = []
        let task = Task {
            for await value in caster.subscribe() {
                received.append(value)
                if received.count >= 1 { break }
            }
        }
        try? await Task.sleep(nanoseconds: 100_000_000)

        // No replay → no emissions yet.
        XCTAssertTrue(received.isEmpty)

        // New emit after subscribe → delivered.
        caster.emit(3)
        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()

        XCTAssertEqual(received, [3])
    }

    // Multiple replay subscribers each get the same last value.
    func testReplayDeliversToMultipleLateSubscribers() async {
        let caster = Multicaster<String>(replayLastValue: true)
        caster.emit("hello")

        let stream1 = caster.subscribe()
        let stream2 = caster.subscribe()

        async let first: String? = {
            for await v in stream1 { return v }
            return nil
        }()
        async let second: String? = {
            for await v in stream2 { return v }
            return nil
        }()

        let result1 = await first
        let result2 = await second
        XCTAssertEqual(result1, "hello")
        XCTAssertEqual(result2, "hello")
    }
}
