import SwiftUI
import PolyMessaging

struct AttachmentCarousel: View {
    let attachments: [Attachment]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Array(attachments.enumerated()), id: \.offset) { _, attachment in
                    AttachmentCard(attachment: attachment)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
        }
        .accessibilityIdentifier("attachmentCarousel")
    }
}

struct AttachmentCard: View {
    let attachment: Attachment

    var body: some View {
        Button {
            if let url = attachment.contentUrl {
                UIApplication.shared.open(url)
            }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                if let imageURL = attachment.previewImageUrl ?? attachment.contentUrl {
                    RetryableAsyncImage(url: imageURL) { image in
                        image.resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 220, height: 140)
                            .clipped()
                    } placeholder: {
                        ProgressView().frame(width: 220, height: 140)
                    } fallback: {
                        imagePlaceholder
                    }
                }

                if let title = attachment.title, !title.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(title)
                            .font(.subheadline.bold())
                            .foregroundColor(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        if let cta = attachment.callToActionText, !cta.isEmpty {
                            Text(cta)
                                .font(.caption.bold())
                                .foregroundColor(.blue)
                        }
                    }
                    .padding(10)
                }
            }
            .frame(width: 220)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(attachment.contentUrl == nil)
    }

    private var imagePlaceholder: some View {
        Rectangle()
            .fill(Color(.systemGray4))
            .frame(width: 220, height: 140)
            .overlay(Image(systemName: "photo").foregroundColor(.gray))
    }
}
