// Copyright PolyAI Limited

import Foundation

typealias WireJSON = [String: Any]

extension Dictionary where Key == String, Value == Any {

    func string(_ key: String) -> String? {
        self[key] as? String
    }

    func int(_ key: String) -> Int? {
        if let i = self[key] as? Int { return i }
        if let d = self[key] as? Double { return Int(d) }
        return nil
    }

    func bool(_ key: String) -> Bool? {
        self[key] as? Bool
    }

    func double(_ key: String) -> Double? {
        self[key] as? Double
    }

    func dict(_ key: String) -> WireJSON? {
        self[key] as? WireJSON
    }

    func array(_ key: String) -> [WireJSON]? {
        self[key] as? [WireJSON]
    }

    func stringArray(_ key: String) -> [String]? {
        self[key] as? [String]
    }

    func url(_ key: String) -> URL? {
        guard let s = string(key), !s.isEmpty else { return nil }
        return URL(string: s)
    }

    func date(_ key: String) -> Date? {
        guard let s = string(key) else { return nil }
        return ISO8601DateFormatter.shared.date(from: s)
            ?? ISO8601DateFormatter.fallback.date(from: s)
    }
}

extension ISO8601DateFormatter {
    fileprivate static let shared: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static let fallback: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

func parseISO8601(_ string: String) -> Date {
    ISO8601DateFormatter.shared.date(from: string)
        ?? ISO8601DateFormatter.fallback.date(from: string)
        ?? Date()
}
