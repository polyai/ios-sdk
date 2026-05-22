import XCTest
@testable import PolyMessaging

final class HeartbeatServiceTests: XCTestCase {

    func testStartEmitsTicks() async {
        let service = HeartbeatService(intervalSeconds: 1)

        let expectation = XCTestExpectation(description: "tick emitted")
        let task = Task {
            for await _ in service.tick.subscribe() {
                expectation.fulfill()
                break
            }
        }

        await service.start(intervalSeconds: 1)
        await fulfillment(of: [expectation], timeout: 3.0)
        await service.stop()
        task.cancel()
    }

    func testStopCancelsTicking() async {
        let service = HeartbeatService(intervalSeconds: 1)
        await service.start()
        await service.stop()

        let expectation = XCTestExpectation(description: "no tick")
        expectation.isInverted = true

        let task = Task {
            for await _ in service.tick.subscribe() {
                expectation.fulfill()
            }
        }

        await fulfillment(of: [expectation], timeout: 2.0)
        task.cancel()
    }

    func testSetIntervalRestartsTimer() async {
        let service = HeartbeatService(intervalSeconds: 100)
        await service.start()

        // Change to 1 second — should tick soon
        await service.setInterval(1)

        let expectation = XCTestExpectation(description: "tick after interval change")
        let task = Task {
            for await _ in service.tick.subscribe() {
                expectation.fulfill()
                break
            }
        }

        await fulfillment(of: [expectation], timeout: 3.0)
        await service.stop()
        task.cancel()
    }

    func testSetIntervalGuardsZero() async {
        let service = HeartbeatService(intervalSeconds: 30)
        await service.setInterval(0)
        // Should not crash; interval unchanged
    }

    func testResetToDefaultInterval() async {
        let service = HeartbeatService(intervalSeconds: 30)
        await service.setInterval(5)
        await service.resetToDefaultInterval()
        // Should reset to 30 — no direct assertion but verifies no crash
    }

    func testDestroyFinishesMulticasters() async {
        let service = HeartbeatService(intervalSeconds: 30)
        await service.start()
        await service.destroy()
        // Should not crash; multicasters finished
    }
}
