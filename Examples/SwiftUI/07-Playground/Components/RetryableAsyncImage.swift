import SwiftUI

struct RetryableAsyncImage<Content: View, Placeholder: View, Fallback: View>: View {
    let url: URL
    @ViewBuilder let content: (Image) -> Content
    @ViewBuilder let placeholder: () -> Placeholder
    @ViewBuilder let fallback: () -> Fallback

    @State private var loadId = UUID()
    @State private var failed = false

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                content(image)
            case .failure:
                fallback()
                    .onTapGesture { reload() }
                    .onAppear { scheduleAutoRetry() }
            case .empty:
                placeholder()
            @unknown default:
                fallback()
            }
        }
        .id(loadId)
    }

    private func reload() {
        loadId = UUID()
    }

    private func scheduleAutoRetry() {
        guard !failed else { return }
        failed = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            reload()
            failed = false
        }
    }
}
