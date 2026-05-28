// Copyright PolyAI Limited

import SwiftUI

struct RichText: View {
    let raw: String

    init(_ text: String) {
        self.raw = text
    }

    var body: some View {
        Text(parse(raw))
            .tint(.blue)
            .environment(\.openURL, OpenURLAction { url in
                UIApplication.shared.open(url)
                return .handled
            })
    }

    private static let mdLinkPattern = #"\[([^\]]+)\]\(([^\)]+)\)"#
    private static let bareURLPattern = #"https?://[^\s<>\"\'`\]\[]+[^\s<>\"\'`\]\[.,;:!?\)]"#
    private static let combinedPattern = "(\(mdLinkPattern))|(\(bareURLPattern))"

    private func parse(_ text: String) -> AttributedString {
        guard let regex = try? NSRegularExpression(pattern: Self.combinedPattern) else {
            return parsePlain(text)
        }

        let nsString = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsString.length))
        guard !matches.isEmpty else { return parsePlain(text) }

        var result = AttributedString()
        var cursor = 0

        for match in matches {
            if match.range.location > cursor {
                let before = nsString.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                result.append(parsePlain(before))
            }

            if match.range(at: 1).location != NSNotFound,
               match.range(at: 2).location != NSNotFound,
               match.range(at: 3).location != NSNotFound {
                let linkText = nsString.substring(with: match.range(at: 2))
                let urlString = nsString.substring(with: match.range(at: 3))
                if let url = URL(string: urlString) {
                    var link = AttributedString(linkText)
                    link.link = url
                    link.foregroundColor = .blue
                    link.underlineStyle = .single
                    result.append(link)
                } else {
                    result.append(AttributedString(linkText))
                }
            } else if match.range(at: 4).location != NSNotFound {
                let urlString = nsString.substring(with: match.range(at: 4))
                if let url = URL(string: urlString) {
                    var link = AttributedString(urlString)
                    link.link = url
                    link.foregroundColor = .blue
                    link.underlineStyle = .single
                    result.append(link)
                } else {
                    result.append(AttributedString(urlString))
                }
            }

            cursor = match.range.location + match.range.length
        }

        if cursor < nsString.length {
            result.append(parsePlain(nsString.substring(from: cursor)))
        }

        return result
    }

    private func parsePlain(_ text: String) -> AttributedString {
        var result = AttributedString()
        var remaining = text[...]

        while !remaining.isEmpty {
            if let range = remaining.range(of: #"\*\*(.+?)\*\*"#, options: .regularExpression) {
                let before = remaining[remaining.startIndex..<range.lowerBound]
                if !before.isEmpty { result.append(AttributedString(String(before))) }
                let inner = String(remaining[range]).dropFirst(2).dropLast(2)
                var bold = AttributedString(String(inner))
                bold.inlinePresentationIntent = .stronglyEmphasized
                result.append(bold)
                remaining = remaining[range.upperBound...]
                continue
            }

            if let range = remaining.range(of: #"(?<!\*)\*([^\*]+?)\*(?!\*)"#, options: .regularExpression) {
                let before = remaining[remaining.startIndex..<range.lowerBound]
                if !before.isEmpty { result.append(AttributedString(String(before))) }
                let inner = String(remaining[range]).dropFirst(1).dropLast(1)
                var italic = AttributedString(String(inner))
                italic.inlinePresentationIntent = .emphasized
                result.append(italic)
                remaining = remaining[range.upperBound...]
                continue
            }

            if let range = remaining.range(of: #"`([^`]+?)`"#, options: .regularExpression) {
                let before = remaining[remaining.startIndex..<range.lowerBound]
                if !before.isEmpty { result.append(AttributedString(String(before))) }
                let inner = String(remaining[range]).dropFirst(1).dropLast(1)
                var code = AttributedString(String(inner))
                code.inlinePresentationIntent = .code
                result.append(code)
                remaining = remaining[range.upperBound...]
                continue
            }

            result.append(AttributedString(String(remaining)))
            break
        }

        return result
    }
}
