import SwiftUI

struct SuggestionRow: View {
    let suggestions: [String]
    let onTap: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(suggestions, id: \.self) { s in
                    Button {
                        onTap(s)
                    } label: {
                        Text(s)
                            .font(.subheadline)
                            .lineLimit(1)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.blue.opacity(0.1))
                            .foregroundColor(.blue)
                            .clipShape(Capsule())
                    }
                    .accessibilityLabel("Suggested reply: \(s)")
                    .accessibilityIdentifier("suggestionPill")
                }
            }
            .padding(.horizontal, 2)
        }
    }
}
