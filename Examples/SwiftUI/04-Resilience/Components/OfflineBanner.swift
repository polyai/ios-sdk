// Copyright PolyAI Limited

//  OfflineBanner.swift
//  Examples/SwiftUI/04-Resilience
//
//  Mirrors README:
//    - § "What you can build > Connection monitoring"
//

import SwiftUI

/// Shown above the ConnectionBanner when the OS reports no network path.
/// Distinct from the SDK's reconnect banner: this means the *device* is
/// offline, not that the websocket is reconnecting.
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
