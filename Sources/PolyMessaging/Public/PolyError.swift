// Copyright PolyAI Limited

import Foundation

public enum PolyError: Error, Sendable, Equatable {

    public enum Auth: Sendable, Equatable {
        case tokenAcquisitionFailed
        case unauthorized
    }

    public enum Session: Sendable, Equatable {
        case sessionCreationFailed(SessionErrorCode)
        case unexpectedDisconnect(code: Int, reason: String)
        case maxReconnectAttemptsExceeded
        case sessionExpired
        case sessionEnded(reason: String?)
    }

    public enum Message: Sendable, Equatable {
        case deliveryFailed(draftId: String)
        case payloadTooLarge(maxBytes: Int)
    }

    public enum Transport: Sendable, Equatable {
        case networkError(String)
        case protocolError(reason: String)
    }

    public enum Voice: Sendable, Equatable {
        /// Voice calling is not yet available — there is no bundled on-device
        /// media (WebRTC audio) engine. The signaling pipeline is implemented;
        /// only the audio engine is outstanding.
        case notImplemented
        case signalingFailed(String)
        case mediaFailed(String)
        case timedOut
    }

    case auth(Auth)
    case session(Session)
    case message(Message)
    case transport(Transport)
    case voice(Voice)
    case invalidConfiguration(String)
}

public extension PolyError {

    var isAuthError: Bool {
        if case .auth = self { return true }
        return false
    }

    var isSessionError: Bool {
        if case .session = self { return true }
        return false
    }

    var isTransportError: Bool {
        if case .transport = self { return true }
        return false
    }

    var isSessionExpired: Bool {
        self == .session(.sessionExpired)
    }

    var isRetryable: Bool {
        switch self {
        case .transport:
            return true
        case .session(.unexpectedDisconnect), .session(.maxReconnectAttemptsExceeded):
            return true
        default:
            return false
        }
    }
}

// MARK: - Human-readable rendering
//
// PolyError conforms to:
//   - CustomStringConvertible — `String(describing:)` and `"\(error)"` return
//     a short user-facing message safe to surface in UI.
//   - LocalizedError — `error.localizedDescription` returns the same string,
//     for code that expects the standard Cocoa error idiom.
//
// The auto-synthesized structural form ("auth(PolyMessaging.PolyError.Auth.
// unauthorized)") is still available via `String(reflecting: error)` for logs
// and crash reports — use that for debugging, not for UI.

extension PolyError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .auth(.tokenAcquisitionFailed):
            return "Couldn't get an access token. Check your connection and try again."
        case .auth(.unauthorized):
            return "Your API key was rejected. Please contact support."

        case .session(.sessionCreationFailed(let code)):
            // code.rawValue is the human-readable string the backend sent
            // (e.g. "Missing authentication headers"). The Swift case name
            // would be camelCase and unhelpful for end users.
            return "Couldn't start a session: \(code.rawValue)."
        case .session(.unexpectedDisconnect(let code, let reason)):
            return reason.isEmpty
                ? "Disconnected unexpectedly (code \(code))."
                : "Disconnected unexpectedly (code \(code)): \(reason)"
        case .session(.maxReconnectAttemptsExceeded):
            return "Connection lost — please try reconnecting."
        case .session(.sessionExpired):
            return "Your session timed out. Start a new chat to continue."
        case .session(.sessionEnded(let reason)):
            if let reason, !reason.isEmpty {
                return "Conversation ended: \(reason)"
            }
            return "Conversation ended."

        case .message(.deliveryFailed):
            return "Couldn't deliver your message. Please try again."
        case .message(.payloadTooLarge(let maxBytes)):
            let kb = maxBytes / 1024
            return "Message is too large (max \(kb) KB)."

        case .transport(.networkError(let reason)):
            return reason.isEmpty ? "Network problem." : "Network problem: \(reason)"
        case .transport(.protocolError(let reason)):
            return reason.isEmpty ? "Connection problem." : "Connection problem: \(reason)"

        case .voice(.notImplemented):
            return "Voice calling isn't available in this SDK build."
        case .voice(.signalingFailed(let reason)):
            return reason.isEmpty ? "Voice call setup failed." : "Voice call setup failed: \(reason)"
        case .voice(.mediaFailed(let reason)):
            return reason.isEmpty ? "Voice call audio failed." : "Voice call audio failed: \(reason)"
        case .voice(.timedOut):
            return "Voice call timed out."

        case .invalidConfiguration(let reason):
            return reason.isEmpty ? "Invalid configuration." : "Invalid configuration: \(reason)"
        }
    }
}

extension PolyError: LocalizedError {
    public var errorDescription: String? { description }
}

extension PolyError: CustomDebugStringConvertible {
    /// Structural form for logs and crash reports — `auth(unauthorized)`,
    /// `session(unexpectedDisconnect(code: 1006, reason: "boom"))`, etc.
    /// Use this (or pattern-match the case) when you need the wire-level
    /// shape; use `description` / `localizedDescription` for UI.
    public var debugDescription: String {
        switch self {
        case .auth(let e):                    return "auth(\(e))"
        case .session(let e):                 return "session(\(e))"
        case .message(let e):                 return "message(\(e))"
        case .transport(let e):               return "transport(\(e))"
        case .voice(let e):                   return "voice(\(e))"
        case .invalidConfiguration(let r):    return "invalidConfiguration(\(r))"
        }
    }
}
