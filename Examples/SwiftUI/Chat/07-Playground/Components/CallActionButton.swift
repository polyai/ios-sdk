// Copyright PolyAI Limited

import SwiftUI
import PolyMessaging

struct CallActionButton: View {
    let action: ChatCallAction

    var body: some View {
        if let url = URL(string: "tel:\(action.contactNumber.filter { $0.isNumber || $0 == "+" })") {
            Link(destination: url) {
                HStack(spacing: 6) {
                    Image(systemName: "phone.fill")
                    Text(action.title.isEmpty ? action.contactNumber : action.title)
                }
                .font(.subheadline.bold())
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.green)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}
