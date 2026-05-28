// Copyright PolyAI Limited

import XCTest
@testable import PolyMessaging

final class ConfigurationTests: XCTestCase {

    func testConfigureWithValidApiKey() throws {
        let client = try PolyMessaging.configure(.init(apiKey: "test_api_key", environment: .production))
        XCTAssertEqual(client.config.apiKey, "test_api_key")
    }

    func testConfigureWithEmptyApiKeyThrows() {
        XCTAssertThrowsError(try PolyMessaging.configure(.init(apiKey: "", environment: .production))) { error in
            guard case PolyError.invalidConfiguration = error else {
                XCTFail("Expected invalidConfiguration, got \(error)")
                return
            }
        }
    }

}
