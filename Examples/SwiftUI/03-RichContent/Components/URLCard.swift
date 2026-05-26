// Copyright PolyAI Limited

//  URLCard.swift
//  Examples/SwiftUI/03-RichContent
//
//  Mirrors README:
//    - § "What you can build > Rich attachments"
//
//  Keep README snippets in sync with this file. See SKILL.md §12.

import SwiftUI
import UIKit
import PolyMessaging

/// Card rendering for a `.url` attachment: preview image, title,
/// call-to-action label. Tap opens `contentUrl` via `UIApplication.shared.open`.
struct URLCard: View {
    let attachment: Attachment

    var body: some View {
        Button {
            if let url = attachment.contentUrl {
                UIApplication.shared.open(url)
            }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                if let preview = attachment.previewImageUrl {
                    RetryableAsyncImage(url: preview) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        ZStack { Color(.systemGray5); ProgressView() }
                    } fallback: {
                        ZStack { Color(.systemGray5); Image(systemName: "photo").foregroundColor(.secondary) }
                    }
                    .frame(width: 260, height: 140)
                    .clipped()
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
            .frame(width: 260)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(attachment.contentUrl == nil)
    }
}
