import SwiftUI

struct LoadingView: View {
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView().scaleEffect(1.5)
            Text("Connecting...").font(.subheadline).foregroundColor(.secondary)
            Spacer()
        }
    }
}
