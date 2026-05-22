import XCTest
@testable import PolyMessaging

final class ConfigurationTests: XCTestCase {

    func testConfigureWithValidToken() throws {
        let client = try PolyMessaging.configure(.init(connectorToken: "ct_test_abc", environment: .dev))
        XCTAssertEqual(client.config.connectorToken, "ct_test_abc")
    }

    func testConfigureWithEmptyTokenThrows() {
        XCTAssertThrowsError(try PolyMessaging.configure(.init(connectorToken: "", environment: .dev))) { error in
            guard case PolyError.invalidConfiguration = error else {
                XCTFail("Expected invalidConfiguration, got \(error)")
                return
            }
        }
    }

}
