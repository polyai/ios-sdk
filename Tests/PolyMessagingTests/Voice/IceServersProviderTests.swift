// Copyright PolyAI Limited

import XCTest
@testable import PolyMessaging

/// Parsing of the gateway ICE-servers response + the static fallback provider.
final class IceServersProviderTests: XCTestCase {

    func test_parse_turnWithCreds_stunArray_andStringForm() {
        let json = Data("""
        {"iceServers":[
          {"urls":["stun:stun.l.google.com:19302"]},
          {"urls":["turn:turn.example.com:3478"],"username":"user","credential":"pass"},
          {"urls":"turn:single.example.com:3478","username":"u2","credential":"c2"}
        ]}
        """.utf8)
        let servers = GatewayIceServersFetcher.parse(json)
        XCTAssertEqual(servers.count, 3)
        XCTAssertEqual(servers[0].urls, ["stun:stun.l.google.com:19302"])
        XCTAssertNil(servers[0].username)
        XCTAssertNil(servers[0].credential)
        XCTAssertEqual(servers[1].urls, ["turn:turn.example.com:3478"])
        XCTAssertEqual(servers[1].username, "user")
        XCTAssertEqual(servers[1].credential, "pass")
        XCTAssertEqual(servers[2].urls, ["turn:single.example.com:3478"]) // single string coerced to [String]
        XCTAssertEqual(servers[2].username, "u2")
    }

    func test_parse_malformedOrEmpty_returnsEmpty() {
        XCTAssertTrue(GatewayIceServersFetcher.parse(Data("not json".utf8)).isEmpty)
        XCTAssertTrue(GatewayIceServersFetcher.parse(Data("{}".utf8)).isEmpty)
        // entries without any urls are skipped
        XCTAssertTrue(GatewayIceServersFetcher.parse(Data(#"{"iceServers":[{"username":"u"}]}"#.utf8)).isEmpty)
    }

    func test_staticProvider_returnsGivenServers() async {
        let servers = await StaticIceServersProvider().fetch()
        XCTAssertEqual(servers, IceServer.default)
    }
}
