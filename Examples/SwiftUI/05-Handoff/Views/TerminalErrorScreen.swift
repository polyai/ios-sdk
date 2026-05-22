//  TerminalErrorScreen.swift
//  Examples/SwiftUI/05-Handoff
//
//  Mirrors README:
//    - § "Best practices > Distinguish terminal errors from reconnects"
//
//  Keep README snippets in sync with this file. See SKILL.md §12.

import SwiftUI

/// Full-bleed screen for errors that aren't recoverable by reconnect —
/// auth failures, configuration mistakes, dead sessions, etc.
struct TerminalErrorScreen: View {
    let message: String
    let onStartNew: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundColor(.orange)
            Text("Something went wrong").font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
            Button(action: onStartNew) {
                Text("Start New Chat")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(10)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 32)
        }
    }
}
