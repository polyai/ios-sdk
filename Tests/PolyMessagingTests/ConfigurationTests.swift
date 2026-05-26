// Copyright PolyAI Limited

import XCTest
@testable import PolyMessaging

final class ConfigurationTests: XCTestCase {

    func testConfigureWithValidToken() throws {
        let client = try PolyMessaging.configure(.init(apiKey: "ct_test_abc", environment: .dev))
        XCTAssertEqual(client.config.apiKey, "ct_test_abc")
    }

    func testConfigureWithEmptyTokenThrows() {
        XCTAssertThrowsError(try PolyMessaging.configure(.init(apiKey: "", environment: .dev))) { error in
            guard case PolyError.invalidConfiguration = error else {
                XCTFail("Expected invalidConfiguration, got \(error)")
                return
            }
        }
    }

}
