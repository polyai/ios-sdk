// Copyright PolyAI Limited

//  ConnectionBanner.swift
//  Examples/SwiftUI/05-Handoff
//
//  Mirrors README:
//    - § "Best practices > Render reconnects as a banner"
//    - § "What you can build > Connection monitoring"
//
//  Keep README snippets in sync with this file. See SKILL.md §12.

import SwiftUI
import PolyMessaging

struct ConnectionBanner: View {
    let status: ConnectionStatus

    var body: some View {
        if case .reconnecting = status {
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.7)
                Text("Reconnecting...").font(.caption).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(Color(.systemYellow).opacity(0.15))
        }
    }
}
