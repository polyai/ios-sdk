// Copyright PolyAI Limited

//  ContentView.swift
//  Examples/SwiftUI/01-Hello
//
//  Mirrors README:
//    - § "Get started > Use in your app > SwiftUI"
//

import SwiftUI
import PolyMessaging

struct ContentView: View {
    // Matches the web's MAX_MESSAGE_LENGTH cap.
    static let maxMessageLength = 500

    // @StateObject survives view re-renders — one ChatSession per chat surface.
    @StateObject var session = PolyMessaging.chat()
    @State private var input = ""

    // F1: only auto-scroll when the user is already near the bottom; otherwise
    // surface a "New messages" pill instead of yanking them away from history.
    @State private var isNearBottom = true
    @State private var hasNewBelow = false

    private var sendDisabled: Bool {
        input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.hasEnded
    }

    /// `failureReason` is non-nil once the SDK hits a terminal failure it
    /// can't auto-recover from — most notably an invalid `apiKey`. We
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
            // ScrollViewReader gives us scrollTo(id:); the ".id("bottom")"
            // sentinel at the end of the LazyVStack is the anchor we scroll to
            // on every message change AND on every text-length change (so the
            // view tracks the growing bubble while streaming).
            GeometryReader { outer in
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(session.messages) { message in
                                Text(message.text ?? "")
                                    .padding(10)
                                    .background(Color(.systemGray6))
                                    .cornerRadius(12)
                                    // Cap bubble width at ~75% of the actual container
                                    // width (tracks rotation / iPad split-view, F5) so
                                    // long messages wrap instead of spanning edge-to-edge.
                                    .frame(maxWidth: outer.size.width > 0 ? outer.size.width * 0.75 : .infinity, alignment: .leading)
                            }
                            // Stable scroll anchor + bottom-visibility probe.
                            Color.clear.frame(height: 1).id("bottom")
                                .background(GeometryReader { g in
                                    Color.clear.preference(
                                        key: BottomVisibleKey.self,
                                        value: g.frame(in: .named("chatScroll")).maxY
                                    )
                                })
                        }
                        .padding()
                    }
                    .coordinateSpace(name: "chatScroll")
                    .accessibilityIdentifier("messageList")
                    .onPreferenceChange(BottomVisibleKey.self) { bottomMaxY in
                        let near = bottomMaxY <= outer.size.height + 80
                        if near != isNearBottom { isNearBottom = near }
                        if near, hasNewBelow { hasNewBelow = false }
                    }
                    .overlay(alignment: .bottom) {
                        if hasNewBelow {
                            newMessagesPill(proxy: proxy)
                                .padding(.bottom, 10)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .onChange(of: session.messages.count) { _ in
                        onNewContent(proxy: proxy)
                    }
                    // Streaming grows the last agent message's text in place
                    // (messages.count doesn't change), so also follow its length.
                    .onChange(of: session.messages.last?.text ?? "") { _ in
                        if isNearBottom { scrollToBottom(proxy: proxy) } else { hasNewBelow = true }
                    }
                }
            }

            HStack(alignment: .bottom, spacing: 12) {
                composerField
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(Color(.systemGray6)).clipShape(RoundedRectangle(cornerRadius: 18))
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
            // gives a useful "auth(unauthorized)" instead of the generic
            // "The operation couldn't be completed" .localizedDescription.
            Text(session.failureReason.map { String(describing: $0) } ?? "")
        }
    }

    // F4: a composer that grows 1–5 lines on iOS 16+ (web parity); single-line
    // fallback on iOS 15. Return sends in both cases (newlines arrive via paste).
    @ViewBuilder
    private var composerField: some View {
        if #available(iOS 16.0, *) {
            TextField("Message...", text: $input, axis: .vertical)
                .lineLimit(1...5)
                .onChange(of: input) { handleComposerChange($0) }
        } else {
            TextField("Message...", text: $input)
                .submitLabel(.send)
                .onChange(of: input) { newValue in
                    if newValue.count > Self.maxMessageLength {
                        input = String(newValue.prefix(Self.maxMessageLength))
                    }
                }
                .onSubmit(send)
        }
    }

    /// iOS 16+ growing field: Return inserts '\n', so detect a trailing newline and
    /// treat it as a send; otherwise enforce the length cap.
    private func handleComposerChange(_ newValue: String) {
        if newValue.hasSuffix("\n") {
            send()
            return
        }
        if newValue.count > Self.maxMessageLength {
            input = String(newValue.prefix(Self.maxMessageLength))
        }
    }

    // MARK: - Scroll

    /// A new message/turn arrived: follow it only if the user is already at the
    /// bottom; otherwise leave them where they are and show the pill.
    private func onNewContent(proxy: ScrollViewProxy) {
        if isNearBottom {
            scrollToBottom(proxy: proxy)
        } else {
            hasNewBelow = true
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
    }

    private func newMessagesPill(proxy: ScrollViewProxy) -> some View {
        Button {
            withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            hasNewBelow = false
            isNearBottom = true
        } label: {
            Label("New messages", systemImage: "arrow.down")
                .font(.caption.bold())
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.blue))
                .foregroundColor(.white)
                .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
        }
        .accessibilityLabel("Scroll to newest messages")
    }

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        input = ""
        guard !text.isEmpty else { return }
        Task { try? await session.send(text) }
    }
}

/// Reports the bottom sentinel's maxY within the scroll viewport so the view can
/// tell whether the user is parked near the bottom.
private struct BottomVisibleKey: PreferenceKey {
    static let defaultValue: CGFloat = .greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = min(value, nextValue())
    }
}
