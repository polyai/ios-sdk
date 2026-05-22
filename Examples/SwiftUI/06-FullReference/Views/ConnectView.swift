import SwiftUI

struct ConnectView: View {
    let hasActiveSession: Bool
    let canResume: Bool
    let onResume: () -> Void
    let onStartNew: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(.systemBackground), Color.blue.opacity(0.05), Color.blue.opacity(0.1)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 20)
                        .frame(maxHeight: 60)

                    VStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(Color.blue.opacity(0.1))
                                .frame(width: 90, height: 90)
                            Circle()
                                .fill(Color.blue.opacity(0.08))
                                .frame(width: 70, height: 70)
                            Image(systemName: "bubble.left.and.bubble.right.fill")
                                .font(.system(size: 32))
                                .foregroundStyle(
                                    LinearGradient(colors: [.blue, .blue.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)
                                )
                        }

                        Text("PolyMessaging")
                            .font(.system(size: 26, weight: .bold, design: .rounded))

                        Text("AI-powered conversations")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }

                    Spacer(minLength: 20)
                        .frame(maxHeight: 40)

                    VStack(spacing: 12) {
                        HStack(spacing: 10) {
                            Image(systemName: "server.rack")
                                .foregroundColor(.blue)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Environment")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .textCase(.uppercase)
                                Text("messaging.dev.poly.ai")
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Circle()
                                .fill(Color.green)
                                .frame(width: 8, height: 8)
                        }

                        Divider()

                        HStack(spacing: 10) {
                            Image(systemName: "key.fill")
                                .foregroundColor(.blue)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Connector")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .textCase(.uppercase)
                                Text("dev connector")
                                    .font(.system(.subheadline, design: .monospaced))
                                    .foregroundColor(.primary.opacity(0.7))
                            }
                            Spacer()
                        }
                    }
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color(.secondarySystemGroupedBackground))
                            .shadow(color: .black.opacity(0.04), radius: 8, y: 4)
                    )
                    .padding(.horizontal, 24)

                    Spacer(minLength: 20)
                        .frame(maxHeight: 40)

                    let primaryShowsResume = hasActiveSession || canResume
                    Button {
                        onResume()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: primaryShowsResume ? "arrow.uturn.forward.circle.fill" : "bolt.fill")
                            Text(primaryShowsResume ? "Resume Chat" : "Start Chat")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, 24)

                    if primaryShowsResume {
                        Button {
                            onStartNew()
                        } label: {
                            Text("Start New Chat")
                                .font(.subheadline.weight(.medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.bordered)
                        .tint(.blue)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal, 24)
                        .padding(.top, 8)
                    }

                    if hasActiveSession {
                        Text("Your conversation is still active")
                            .font(.caption)
                            .foregroundColor(.blue.opacity(0.8))
                            .padding(.top, 8)
                    } else if canResume {
                        Text("A previous conversation is available to resume")
                            .font(.caption)
                            .foregroundColor(.blue.opacity(0.8))
                            .padding(.top, 8)
                    }

                    Text("PolyMessaging iOS SDK v0.2.1")
                        .font(.caption2)
                        .foregroundColor(.secondary.opacity(0.6))
                        .padding(.top, 12)
                        .padding(.bottom, 20)
                }
            }
        }
    }
}
