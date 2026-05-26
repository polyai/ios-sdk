// Copyright PolyAI Limited

//  URLCard.swift
//  Examples/SwiftUI/04-Resilience
//
//  Mirrors README:
//    - § "What you can build > Rich attachments"
//
//  Keep README snippets in sync with this file. See SKILL.md §12.

import SwiftUI
import UIKit
import PolyMessaging

/// Preview card for an `AttachmentContentType.url` attachment. Renders
/// the preview image (if provided), the title, and a CTA. Tapping the
/// card opens the `contentUrl` in the system browser.
struct URLCard: View {
    let attachment: Attachment

    var body: some View {
        Button {
            if let url = attachment.contentUrl {
                UIApplication.shared.open(url)
            }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                if let imageURL = attachment.previewImageUrl {
                    RetryableAsyncImage(url: imageURL) { image in
                        image.resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 240, height: 130)
                            .clipped()
                    } placeholder: {
                        ProgressView().frame(width: 240, height: 130)
                    } fallback: {
                        Rectangle()
                            .fill(Color(.systemGray4))
                            .frame(width: 240, height: 130)
                            .overlay(Image(systemName: "link").foregroundColor(.gray))
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    if let title = attachment.title, !title.isEmpty {
                        Text(title)
                            .font(.subheadline.bold())
                            .foregroundColor(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    if let cta = attachment.callToActionText, !cta.isEmpty {
                        Text(cta)
                            .font(.caption.bold())
                            .foregroundColor(.blue)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 240)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(attachment.contentUrl == nil)
    }
}
