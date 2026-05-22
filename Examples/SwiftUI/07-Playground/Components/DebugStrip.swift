import SwiftUI

/// Tiny always-on observability strip rendered at the top of the chat view
/// when `DevSettings.showDebugStrip` is enabled. Mirrors the most useful
/// SettingsSheet diagnostics into a 1-line, always-visible chip so you can
/// watch reconnects / streaming chunks happen in real-time without opening
/// the sheet.
struct DebugStrip: View {
    @ObservedObject var diagnostics: DevDiagnostics
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 10) {
            chip(systemImage: statusIcon, text: diagnostics.connectionLabel, color: statusColor)
            chip(systemImage: "number", text: "seq \(diagnostics.lastSequence)")
            chip(systemImage: "arrow.up.arrow.down", text: "\(diagnostics.framesOut)→ ←\(diagnostics.framesIn)")
            if diagnostics.chunksIn > 0 {
                chip(systemImage: "waveform", text: "\(diagnostics.chunksIn)c", color: .blue)
            }
            Spacer(minLength: 0)
            chip(systemImage: "clock", text: lastFrameLabel())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.black.opacity(0.78))
        .foregroundColor(.white)
        .font(.system(size: 11, design: .monospaced))
        .onReceive(tick) { now = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary())
    }

    private func chip(systemImage: String, text: String, color: Color = .white.opacity(0.85)) -> some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage).font(.system(size: 9))
            Text(text)
        }
        .foregroundColor(color)
    }

    private var statusIcon: String {
        switch diagnostics.connectionLabel {
        case "open": return "dot.radiowaves.left.and.right"
        case "connecting": return "ellipsis"
        case let s where s.hasPrefix("reconnecting"): return "arrow.clockwise"
        case "closing", "closed": return "xmark.circle"
        case "failed": return "exclamationmark.triangle.fill"
        default: return "circle"
        }
    }

    private var statusColor: Color {
        let label = diagnostics.connectionLabel
        if label == "open" { return .green }
        if label == "connecting" || label.hasPrefix("reconnecting") { return .yellow }
        if label == "failed" || label == "closed" || label == "closing" { return .red }
        return .white.opacity(0.6)
    }

    private func lastFrameLabel() -> String {
        guard let at = diagnostics.lastInboundAt else { return "—" }
        let s = Int(now.timeIntervalSince(at))
        if s < 1 { return "0s" }
        return "\(s)s"
    }

    private func accessibilitySummary() -> String {
        "Status \(diagnostics.connectionLabel). Sequence \(diagnostics.lastSequence). Chunks \(diagnostics.chunksIn). Last frame \(lastFrameLabel())."
    }
}
