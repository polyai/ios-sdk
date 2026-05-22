import Foundation

struct LogEntry: Identifiable {
    let id = UUID()
    let summary: String
    let detail: String?
}
