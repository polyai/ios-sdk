// Copyright PolyAI Limited

//  ConnectionBanner.swift
//  Examples/SwiftUI/04-Resilience
//
//  Mirrors README:
//    - § "Best practices > Render reconnects as a banner"
//    - § "What you can build > Connection monitoring"
//

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
