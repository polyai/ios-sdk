import SwiftUI

/// Centered timestamp pill rendered between message groups (iMessage style).
/// Inserted by ChatView whenever the time gap between two consecutive
/// messages exceeds `MessageTimestamp.groupGapSeconds`, plus above the very
/// first message so the top of the list always anchors a time.
struct TimestampSeparator: View {
    let date: Date

    var body: some View {
        HStack {
            Spacer()
            Text(MessageTimestamp.groupHeader(date))
                .font(.caption2.weight(.semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            Spacer()
        }
        .padding(.vertical, 6)
        .accessibilityLabel(MessageTimestamp.groupHeader(date))
    }
}
