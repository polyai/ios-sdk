// Copyright PolyAI Limited

//  URLCard.swift
//  Examples/SwiftUI/05-Handoff
//
//  Mirrors README:
//    - § "What you can build > Rich attachments"
//

import SwiftUI
import UIKit
import PolyMessaging

/// Card view for ATTACHMENT_CONTENT_TYPE_URL — surfaces a preview image,
/// a title, and a CTA. Tapping opens the URL externally.
struct URLCard: View {
    let attachment: Attachment

    var body: some View {
        Button {
            if let url = attachment.contentUrl {
                UIApplication.shared.open(url)
            }
        } label: {
            HStack(spacing: 12) {
                if let imageURL = attachment.previewImageUrl {
                    RetryableAsyncImage(url: imageURL) { image in
                        image.resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } placeholder: {
                        ProgressView().frame(width: 56, height: 56)
                    } fallback: {
                        Image(systemName: "link")
                            .frame(width: 56, height: 56)
                            .background(Color(.systemGray5))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                } else {
                    Image(systemName: "link")
                        .frame(width: 56, height: 56)
                        .background(Color(.systemGray5))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                VStack(alignment: .leading, spacing: 4) {
                    if let title = attachment.title, !title.isEmpty {
                        Text(title)
                            .font(.subheadline.bold())
                            .foregroundColor(.primary)
                            .lineLimit(2)
                    }
                    if let cta = attachment.callToActionText, !cta.isEmpty {
                        Text(cta)
                            .font(.caption.bold())
                            .foregroundColor(.blue)
                    } else if let host = attachment.contentUrl?.host {
                        Text(host)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(attachment.contentUrl == nil)
    }
}
