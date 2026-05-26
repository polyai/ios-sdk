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

    /// `failureReason` is non-nil once the SDK hits a terminal failure it
    /// can't auto-recover from — most notably an invalid `connectorToken`. We
    /// bind it to `.alert` so an obvious "Couldn't connect" dialog appears
    /// instead of letting the app sit silently with an empty message list.
    private var failureAlertBinding: Binding<Bool> {
        Binding(
            get: { session.failureReason != nil },
            set: { _ in }
        )
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
        .alert("Couldn't connect", isPresented: failureAlertBinding) {
            Button("Try Again") {
                Task { try? await session.client.resume() }
            }
        } message: {
            // PolyError doesn't conform to LocalizedError, so String(describing:)
            // gives a useful "auth(unauthorized)" instead of the generic
            // "The operation couldn't be completed" .localizedDescription.
            Text(session.failureReason.map { String(describing: $0) } ?? "")
        }
    }

    private func send() {
        let text = input
        input = ""
        Task { try? await session.send(text) }
    }
}
