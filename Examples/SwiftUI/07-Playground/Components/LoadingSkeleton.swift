import SwiftUI

struct LoadingSkeleton: View {
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            bubble(width: 220)
            bubble(width: 260)
            bubble(width: 190)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
        // Decorative — hide from VoiceOver.
        .accessibilityHidden(true)
    }

    private func bubble(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.gray.opacity(pulse ? 0.12 : 0.28))
            .frame(width: width, height: 42)
    }
}

#Preview {
    LoadingSkeleton()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(.systemBackground))
}
