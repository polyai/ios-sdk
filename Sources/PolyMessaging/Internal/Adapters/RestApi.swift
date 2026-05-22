import Foundation

actor RestApi: RestApiPort {

    private let baseURL: URL
    private let connectorToken: String
    private let hostIdentifier: String
    private let logger: PolyLogger
    private let urlSession: URLSession

    private var accessToken: String?

    private static let maxRetries = 3
    private static let retryDelay: UInt64 = 1_000_000_000
    private static let maxRetryAfter: TimeInterval = 30
    private static let defaultRetryAfter: TimeInterval = 5

    init(baseURL: URL, connectorToken: String, hostIdentifier: String, logger: PolyLogger, urlSession: URLSession = .shared) {
        self.baseURL = baseURL
        self.connectorToken = connectorToken
        self.hostIdentifier = hostIdentifier
        self.logger = logger
        self.urlSession = urlSession
    }

    // MARK: - RestApiPort

    func obtainAccessToken() async throws -> AccessTokenResponse {
        // Mirror web V2ApiAdapter: clear cached credentials before
        // re-issuing the obtain-token call so a failed in-flight token
        // can't leak into a fresh fetch.
        accessToken = nil

        let url = baseURL.appendingPathComponent("access-token")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(connectorToken, forHTTPHeaderField: "X-Token")
        request.setValue(hostIdentifier, forHTTPHeaderField: "X-Host")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Polyai-Correlation-Id")
        request.httpBody = "{}".data(using: .utf8)

        let (data, _) = try await executeWithRetry(request, endpoint: "access-token")
        let json = try parseJSON(data)

        let token = json.string("access_token") ?? ""

        guard !token.isEmpty else {
            throw PolyError.auth(.tokenAcquisitionFailed)
        }

        let expiresIn = json.int("expires_in") ?? 3600
        let tokenType = json.string("token_type") ?? "Bearer"

        accessToken = token

        logger.debug("Access token obtained", metadata: nil)

        return AccessTokenResponse(accessToken: token, expiresIn: expiresIn, tokenType: tokenType)
    }

    func createSession(context: SessionContext) async throws -> SessionCreated {
        // Reset the cached access token at the top so a stale handle from
        // a previous session doesn't leak into the new session creation —
        // mirrors web V2ApiAdapter.createSession's first line.
        // (We restore it on success below.)
        let inFlightToken = accessToken
        accessToken = nil
        guard let token = inFlightToken, !token.isEmpty else {
            throw PolyError.auth(.tokenAcquisitionFailed)
        }
        accessToken = token

        let url = baseURL.appendingPathComponent("sessions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Polyai-Correlation-Id")
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        request.setValue("PolyMessaging-iOS/\(PolyMessaging.version) (iOS; \(osVersion))", forHTTPHeaderField: "User-Agent")

        let body: [String: Any] = [
            "streaming_enabled": context.streamingEnabled,
            "platform": context.platform,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await executeWithRetry(request, endpoint: "sessions")
        let json = try parseJSON(data)

        let sessionId = json.string("session_id") ?? ""
        guard !sessionId.isEmpty else {
            throw PolyError.session(.sessionCreationFailed(.sessionCreationFailed))
        }

        logger.debug("Session created", metadata: ["sessionId": sessionId])

        return SessionCreated(sessionId: sessionId)
    }

    func currentAccessToken() async -> String? {
        accessToken
    }

    // MARK: - HTTP execution with retry

    private func executeWithRetry(_ request: URLRequest, endpoint: String) async throws -> (Data, HTTPURLResponse) {
        var lastError: Error?

        // maxRetries=3 means 4 total attempts (initial + 3 retries) to match
        // the web BaseFetchApiAdapter contract.
        for attempt in 0...Self.maxRetries {
            do {
                let (data, response) = try await urlSession.data(for: request)

                guard let http = response as? HTTPURLResponse else {
                    throw PolyError.transport(.networkError("Non-HTTP response"))
                }

                if (200..<300).contains(http.statusCode) {
                    return (data, http)
                }

                // Rate-limited — honour Retry-After header and consume a retry attempt.
                if http.statusCode == 429 {
                    let retryAfterSeconds = min(
                        TimeInterval(http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? Self.defaultRetryAfter),
                        Self.maxRetryAfter
                    )
                    logger.warn(
                        "Rate limited (429), retrying after \(Int(retryAfterSeconds))s, attempt \(attempt + 1)/\(Self.maxRetries + 1)",
                        metadata: ["endpoint": endpoint]
                    )
                    lastError = PolyError.transport(.networkError("HTTP 429 rate limited"))
                    if attempt < Self.maxRetries {
                        try? await Task.sleep(nanoseconds: UInt64(retryAfterSeconds * 1_000_000_000))
                    }
                    continue
                }

                if (400..<500).contains(http.statusCode) {
                    throw mapClientError(statusCode: http.statusCode, data: data, endpoint: endpoint)
                }

                logger.warn("Server error \(http.statusCode), attempt \(attempt + 1)/\(Self.maxRetries + 1)", metadata: ["endpoint": endpoint])
                lastError = PolyError.transport(.networkError("HTTP \(http.statusCode)"))

            } catch let error as PolyError {
                switch error {
                case .auth, .session:
                    throw error
                default:
                    logger.warn("Request failed, attempt \(attempt + 1)/\(Self.maxRetries + 1)", metadata: ["endpoint": endpoint])
                    lastError = error
                }
            } catch {
                logger.warn("Network error, attempt \(attempt + 1)/\(Self.maxRetries + 1)", metadata: ["endpoint": endpoint, "error": error.localizedDescription])
                lastError = error
            }

            if attempt < Self.maxRetries {
                try? await Task.sleep(nanoseconds: Self.retryDelay)
            }
        }

        throw lastError ?? PolyError.transport(.networkError("Max retries exceeded for /\(endpoint)"))
    }

    private func mapClientError(statusCode: Int, data: Data, endpoint: String) -> PolyError {
        if statusCode == 401 || statusCode == 403 {
            return .auth(.unauthorized)
        }

        // Parse the error body uniformly across endpoints (web does this for
        // every endpoint, not just /sessions). Lets us surface a meaningful
        // SessionErrorCode for /access-token failures too.
        let parsedCode: SessionErrorCode? = {
            guard let json = try? JSONSerialization.jsonObject(with: data) as? WireJSON,
                  let message = json.string("message") ?? json.string("error") else {
                return nil
            }
            return SessionErrorCode(rawValue: message)
        }()

        if endpoint == "sessions" {
            return .session(.sessionCreationFailed(parsedCode ?? .unknown))
        }

        // For /access-token and other endpoints, surface the parsed code via
        // session-creation-failed (its enum is the catch-all error vocabulary
        // for the connector handshake).
        if let code = parsedCode {
            return .session(.sessionCreationFailed(code))
        }

        return .auth(.tokenAcquisitionFailed)
    }

    private func parseJSON(_ data: Data) throws -> WireJSON {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? WireJSON else {
            throw PolyError.transport(.protocolError(reason: "Invalid JSON response"))
        }
        return json
    }
}
