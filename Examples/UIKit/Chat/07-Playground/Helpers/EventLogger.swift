// Copyright PolyAI Limited

//  EventLogger.swift
//  Examples/UIKit/07-Playground
//
//  Converts SDK events / status strings into LogEntry rows for LogsViewController.
//  Uses the SDK's public `debugSummary` / `debugDetail` event helpers.
//

import Foundation
import PolyMessaging

enum EventLogger {

    static func makeEntry(_ msg: String, detail: String? = nil) -> LogEntry {
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        return LogEntry(summary: "[\(ts)] \(msg)", detail: detail)
    }

    static func makeEntry(event: MessagingEvent) -> LogEntry {
        makeEntry(event.debugSummary, detail: event.debugDetail)
    }
}
