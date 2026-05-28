// Copyright PolyAI Limited

import Foundation
import os

struct OSLogLogger: PolyLogger {
    private let logger = os.Logger(subsystem: "ai.poly.messaging", category: "SDK")
    private let level: LogLevel

    init(level: LogLevel = .error) {
        self.level = level
    }

    func debug(_ message: String, metadata: [String: any Sendable]?) {
        guard level >= .debug else { return }
        logger.debug("\(message) \(Self.format(metadata))")
    }

    func info(_ message: String, metadata: [String: any Sendable]?) {
        guard level >= .info else { return }
        logger.info("\(message) \(Self.format(metadata))")
    }

    func warn(_ message: String, metadata: [String: any Sendable]?) {
        guard level >= .warn else { return }
        logger.warning("\(message) \(Self.format(metadata))")
    }

    func error(_ message: String, metadata: [String: any Sendable]?) {
        guard level >= .error else { return }
        logger.error("\(message) \(Self.format(metadata))")
    }

    private static func format(_ metadata: [String: any Sendable]?) -> String {
        guard let metadata, !metadata.isEmpty else { return "" }
        let pairs = metadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\(String(describing: $0.value))" }
        return "{" + pairs.joined(separator: " ") + "}"
    }
}
