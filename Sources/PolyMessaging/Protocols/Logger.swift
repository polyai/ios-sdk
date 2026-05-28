// Copyright PolyAI Limited

import Foundation

/// Structured logger.
///
/// **PII discipline:** the SDK never logs message bodies, user names, or
/// any free-form user content via this surface. Callers must follow the
/// same policy. Values that are inherently sensitive (tokens, signatures,
/// PII) must be omitted, hashed, or truncated by the caller.
///
/// `metadata` values are typed `any Sendable` (not `String`) so callers can
/// pass numbers, bools, or nested objects without stringifying. Implementers
/// are responsible for serialising values for their backing store
/// (`String(describing:)` is a safe default).
public protocol PolyLogger: Sendable {
    func debug(_ message: String, metadata: [String: any Sendable]?)
    func info(_ message: String, metadata: [String: any Sendable]?)
    func warn(_ message: String, metadata: [String: any Sendable]?)
    func error(_ message: String, metadata: [String: any Sendable]?)
}

extension PolyLogger {
    public func debug(_ message: String) { debug(message, metadata: nil) }
    public func info(_ message: String) { info(message, metadata: nil) }
    public func warn(_ message: String) { warn(message, metadata: nil) }
    public func error(_ message: String) { error(message, metadata: nil) }
}
