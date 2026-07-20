// Copyright PolyAI Limited

//  OfflineBanner.swift
//  Examples/SwiftUI/05-Handoff
//
//  Mirrors README:
//    - § "What you can build > Offline detection"
//

import SwiftUI

/// Pinned above the chat when device connectivity is lost. Distinct from
/// the SDK's reconnect banner (which fires on WebSocket drop).
struct OfflineBanner: View {
    let isOnline: Bool

    var body: some View {
        if !isOnline {
            HStack(spacing: 8) {
                Image(systemName: "wifi.slash")
                Text("You're offline").font(.caption.bold())
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(Color(.systemRed).opacity(0.18))
            .foregroundColor(.red)
        }
    }
}
