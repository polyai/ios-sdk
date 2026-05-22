//  ContentView.swift
//  Examples/SwiftUI/01-Hello
//
//  Mirrors README:
//    - § "Get started > Use in your app > SwiftUI"
//
//  Keep README snippets in sync with this file. See SKILL.md §12.

import SwiftUI
import PolyMessaging

struct ContentView: View {
    // @StateObject survives view re-renders — one ChatSession per chat surface.
    @StateObject var session = PolyMessaging.chat()
    @State private var input = ""

    private var sendDisabled: Bool {
        input.trimmingCharacters(in: .whitespaces).isEmpty || session.hasEnded
    }

    var body: some View {
        VStack(spacing: 0) {
            List(session.messages) { message in
                Text(message.text ?? "")
            }
            .accessibilityIdentifier("messageList")

            HStack(spacing: 12) {
                TextField("Message...", text: $input)
                    .textFieldStyle(.plain)
                    .submitLabel(.send)
                    .onSubmit(send)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(Color(.systemGray6)).clipShape(Capsule())
                    .accessibilityIdentifier("composer")

                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 36))
                        .foregroundColor(sendDisabled ? .gray : .blue)
                }
                .disabled(sendDisabled)
                .accessibilityIdentifier("sendButton")
            }
            .padding(.horizontal).padding(.vertical, 8).background(.bar)
        }
    }

    private func send() {
        let text = input
        input = ""
        Task { try? await session.send(text) }
    }
}
