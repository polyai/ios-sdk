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
