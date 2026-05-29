// Copyright PolyAI Limited

import Foundation

struct OSLogLogger: PolyLogger {
    private let level: LogLevel

    init(level: LogLevel = .error) {
        self.level = level
    }

    func debug(_ message: String, metadata: [String: any Sendable]?) {
        guard level >= .debug else { return }
        emit("DEBUG", message, metadata)
    }

    func info(_ message: String, metadata: [String: any Sendable]?) {
        guard level >= .info else { return }
        emit("INFO ", message, metadata)
    }

    func warn(_ message: String, metadata: [String: any Sendable]?) {
        guard level >= .warn else { return }
        emit("WARN ", message, metadata)
    }

    func error(_ message: String, metadata: [String: any Sendable]?) {
        guard level >= .error else { return }
        emit("ERROR", message, metadata)
    }

    private func emit(_ tag: String, _ message: String, _ metadata: [String: any Sendable]?) {
        print("[poly:\(tag)] \(message)\(Self.format(metadata))")
    }

    private static func format(_ metadata: [String: any Sendable]?) -> String {
        guard let metadata, !metadata.isEmpty else { return "" }
        let pairs = metadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\(String(describing: $0.value))" }
        return " {" + pairs.joined(separator: " ") + "}"
    }
}
