// Copyright PolyAI Limited

//  TerminalErrorScreen.swift
//  Examples/SwiftUI/04-Resilience
//
//  Mirrors README:
//    - § "Best practices > Surface .failed with a manual retry"
//

import SwiftUI
import PolyMessaging

/// Full-screen replacement for the chat UI when the SDK has given up
/// reconnecting (`session.failureReason != nil`). The user gets one big
/// "Try Again" button that calls `client.resume()` — that's the README
/// "Best practices > Surface .failed with a manual retry" pattern.
struct TerminalErrorScreen: View {
    let reason: PolyError
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundColor(.orange)
            Text("Couldn't connect")
                .font(.title2.bold())
            // .localizedDescription would just be Error's default
            // ("The operation couldn't be completed…"). String(describing:)
            // gives the case name + associated values, which is far more
            // useful for an example.
            Text(String(describing: reason))
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
            Button(action: onRetry) {
                Text("Try Again")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(10)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}
