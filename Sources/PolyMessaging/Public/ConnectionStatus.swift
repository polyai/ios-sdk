import Foundation

public enum ConnectionStatus: Sendable, Equatable {
    case idle
    case connecting
    case open
    case closing
    /// Transient disconnect — the SDK may still auto-reconnect via the reconnect ladder.
    case closed(ConnectionCloseEvent?)
    case reconnecting(attempt: Int)
    /// Terminal: SDK has exhausted reconnect and/or invalid-session budgets
    /// and will not attempt to reconnect on its own. Distinct from `.closed`
    /// (a transient disconnect that may yet recover). Consumers should
    /// expose a manual "Reconnect" affordance when this state is reached.
    case failed(reason: PolyError?)
}

public extension ConnectionStatus {
    var isConnected: Bool {
        if case .open = self { return true }
        return false
    }

    var isReconnecting: Bool {
        if case .reconnecting = self { return true }
        return false
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    var reconnectAttempt: Int? {
        if case .reconnecting(let attempt) = self { return attempt }
        return nil
    }

    var isTerminal: Bool {
        if case .failed = self { return true }
        return false
    }

    var isActive: Bool {
        switch self {
        case .connecting, .open, .reconnecting: return true
        default: return false
        }
    }
}

public struct ConnectionCloseEvent: Sendable, Equatable {
    public let code: Int
    public let reason: String
    public let wasClean: Bool
}

public enum CloseCode: Int, Sendable {
    case normal = 1000
    case noStatus = 1005
    case abnormal = 1006
    case clientReplaced = 4000
    case sessionUnknown = 4001
    case appError = 4002
}
