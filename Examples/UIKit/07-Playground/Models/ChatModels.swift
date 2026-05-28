// Copyright PolyAI Limited

//  ChatModels.swift
//  Examples/UIKit/07-Playground
//
//  Example-only view models. Mirrors the SwiftUI 07 `Models/ChatModels.swift`.
//

import Foundation

struct LogEntry: Identifiable {
    let id = UUID()
    let summary: String
    let detail: String?
}
