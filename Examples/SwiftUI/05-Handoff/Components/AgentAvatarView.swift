import SwiftUI
import PolyMessaging

struct AgentAvatarView: View {
    let url: URL?
    private let size: CGFloat = 28

    var body: some View {
        if let url {
            RetryableAsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                fallbackIcon
            } fallback: {
                fallbackIcon
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
        } else {
            fallbackIcon
        }
    }

    private var fallbackIcon: some View {
        Image(systemName: "person.circle.fill")
            .resizable()
            .frame(width: size, height: size)
            .foregroundColor(Color(.systemGray3))
    }
}