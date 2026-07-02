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

    // MARK: - VoiceEnvironment endpoint construction

    func test_iceServersURL_buildsGatewayEndpoint_encodingToken() {
        let url = VoiceEnvironment(environment: .cluster("dev")).iceServersURL(token: "ab/cd ef")
        XCTAssertEqual(url?.scheme, "https")
        XCTAssertEqual(url?.host, "webrtc-gateway.dev.polyai.app")
        XCTAssertEqual(url?.path, "/api/v1/ice-servers")
        let token = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?.first { $0.name == "token" }?.value
        XCTAssertEqual(token, "ab/cd ef", "the token round-trips (percent-encoded on the wire)")
    }

    func test_signalingURL_perRegion() {
        XCTAssertEqual(
            VoiceEnvironment(environment: .us).signalingURL.absoluteString,
            "wss://webrtc-gateway.us-1.polyai.app/api/v1/webrtc/signal"
        )
    }

    // MARK: - fetch() HTTP orchestration (STUN fallback)

    private func mockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func fetcher(_ session: URLSession) -> GatewayIceServersFetcher {
        var f = GatewayIceServersFetcher(url: URL(string: "https://gw.test/api/v1/ice-servers?token=t"),
                                         logger: OSLogLogger(level: .none))
        f.urlSession = session
        return f
    }

    func test_fetch_nilURL_returnsDefault() async {
        let f = GatewayIceServersFetcher(url: nil, logger: OSLogLogger(level: .none))
        let servers = await f.fetch()
        XCTAssertEqual(servers, IceServer.default)
    }

    func test_fetch_success_parsesServers() async {
        MockURLProtocol.handler = { req in
            let body = Data(#"{"iceServers":[{"urls":["turn:t.example:3478"],"username":"u","credential":"c"}]}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        defer { MockURLProtocol.handler = nil }
        let servers = await fetcher(mockSession()).fetch()
        XCTAssertEqual(servers.count, 1)
        XCTAssertEqual(servers.first?.urls, ["turn:t.example:3478"])
        XCTAssertEqual(servers.first?.username, "u")
    }

    func test_fetch_non2xx_fallsBackToStun() async {
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
        defer { MockURLProtocol.handler = nil }
        let servers = await fetcher(mockSession()).fetch()
        XCTAssertEqual(servers, IceServer.default)
    }

    func test_fetch_networkError_fallsBackToStun() async {
        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        defer { MockURLProtocol.handler = nil }
        let servers = await fetcher(mockSession()).fetch()
        XCTAssertEqual(servers, IceServer.default)
    }

    func test_fetch_emptyList_fallsBackToStun() async {
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data(#"{"iceServers":[]}"#.utf8))
        }
        defer { MockURLProtocol.handler = nil }
        let servers = await fetcher(mockSession()).fetch()
        XCTAssertEqual(servers, IceServer.default, "an empty list still yields a usable STUN default")
    }
}

/// Minimal `URLProtocol` stub so `fetch()`'s HTTP path can be driven without a network.
final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}
