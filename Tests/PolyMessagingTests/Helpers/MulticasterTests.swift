import XCTest
@testable import PolyMessaging

final class MulticasterTests: XCTestCase {

    func testEmitToSingleSubscriber() async {
        let caster = Multicaster<Int>()
        let stream = caster.subscribe()

        caster.emit(42)
        caster.finish()

        var values: [Int] = []
        for await v in stream { values.append(v) }
        XCTAssertEqual(values, [42])
    }

    func testEmitToMultipleSubscribers() async {
        let caster = Multicaster<String>()
        let s1 = caster.subscribe()
        let s2 = caster.subscribe()

        caster.emit("hello")
        caster.finish()

        var v1: [String] = []
        for await v in s1 { v1.append(v) }

        var v2: [String] = []
        for await v in s2 { v2.append(v) }

        XCTAssertEqual(v1, ["hello"])
        XCTAssertEqual(v2, ["hello"])
    }

    func testFinishEndsStreams() async {
        let caster = Multicaster<Int>()
        let stream = caster.subscribe()

        caster.emit(1)
        caster.emit(2)
        caster.finish()
        caster.emit(3)

        var values: [Int] = []
        for await v in stream { values.append(v) }
        XCTAssertEqual(values, [1, 2])
    }

    func testSubscriptionCleanupOnCancel() async {
        let caster = Multicaster<Int>()
        let stream = caster.subscribe()

        let task = Task {
            for await _ in stream {}
        }
        task.cancel()

        try? await Task.sleep(nanoseconds: 100_000_000)
        caster.emit(99)
        caster.finish()
    }
}
