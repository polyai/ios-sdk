import SwiftUI

struct TypingIndicator: View {
    var avatarUrl: URL?
    @State private var dotOffsets: [CGFloat] = [0, 0, 0]

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            AgentAvatarView(url: avatarUrl)

            HStack(spacing: 5) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(Color(.systemGray2))
                        .frame(width: 8, height: 8)
                        .offset(y: dotOffsets[i])
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color(.systemGray5))
            .clipShape(RoundedRectangle(cornerRadius: 18))
        }
        .onAppear { startAnimation() }
    }

    private func startAnimation() {
        for i in 0..<3 {
            let delay = Double(i) * 0.2
            withAnimation(
                .easeInOut(duration: 0.5)
                .repeatForever(autoreverses: true)
                .delay(delay)
            ) {
                dotOffsets[i] = -6
            }
        }
    }
}
