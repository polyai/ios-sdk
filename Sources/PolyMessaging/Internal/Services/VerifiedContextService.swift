// Copyright PolyAI Limited

import Foundation

/// Asks the customer's handler for a JWT and submits it. Never throws, and
/// resolves within `totalBudget` so the agent join always goes out.
actor VerifiedContextService {

    // Same limits as the web SDK.
    static let defaultHandlerTimeout: TimeInterval = 4
    static let defaultTotalBudget: TimeInterval = 5

    private let handler: VerifiedContextHandler
    private let api: RestApiPort
    private let logger: PolyLogger
    private let handlerTimeout: TimeInterval
    private let totalBudget: TimeInterval

    init(
        handler: @escaping VerifiedContextHandler,
        api: RestApiPort,
        logger: PolyLogger,
        handlerTimeout: TimeInterval = VerifiedContextService.defaultHandlerTimeout,
        totalBudget: TimeInterval = VerifiedContextService.defaultTotalBudget
    ) {
        self.handler = handler
        self.api = api
        self.logger = logger
        self.handlerTimeout = handlerTimeout
        self.totalBudget = totalBudget
    }

    func run(_ request: VerifiedContextRequest, notifyAgent: Bool = false) async -> VerifiedContextStatus {
        let started = Date()
        let status = await resolve(request, notifyAgent: notifyAgent, started: started)
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        switch status {
        case .failed(let reason):
            logger.warn("Verified context failed — agent joins without it", metadata: [
                "sessionId": request.sessionId, "reason": "\(reason)", "ms": "\(ms)",
            ])
        default:
            logger.info("Verified context resolved", metadata: [
                "sessionId": request.sessionId, "status": "\(status)", "ms": "\(ms)",
            ])
        }
        return status
    }

    // MARK: - Private

    private func resolve(
        _ request: VerifiedContextRequest,
        notifyAgent: Bool,
        started: Date
    ) async -> VerifiedContextStatus {
        let handler = self.handler
        let outcome = await withDeadline(handlerTimeout) { () -> HandlerOutcome in
            do {
                guard let token = try await handler(request), !token.isEmpty else { return .noToken }
                return .token(token)
            } catch {
                return .threw(String(describing: error))
            }
        }

        let token: String
        switch outcome {
        case nil:
            return .failed(.callbackTimedOut)
        case .noToken?:
            return .declined
        case .threw(let reason)?:
            return .failed(.callbackFailed(reason))
        case .token(let t)?:
            token = t
        }

        let remaining = totalBudget - Date().timeIntervalSince(started)
        guard remaining > 0 else { return .failed(.submitFailed("Timed out")) }

        let api = self.api
        let submitted = await withDeadline(remaining) { () -> PolyError.VerifiedContext? in
            do {
                try await api.submitVerifiedContext(
                    sessionId: request.sessionId, token: token, notifyAgent: notifyAgent
                )
                return nil
            } catch PolyError.verifiedContext(let reason) {
                return reason
            } catch {
                return .submitFailed(String(describing: error))
            }
        }

        switch submitted {
        case nil:
            return .failed(.submitFailed("Timed out"))
        case .some(nil):
            return .set
        case .some(.some(let reason)):
            return .failed(reason)
        }
    }

    private enum HandlerOutcome: Sendable {
        case token(String)
        case noToken
        case threw(String)
    }
}
