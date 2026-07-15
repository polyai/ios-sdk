// Copyright PolyAI Limited

import SwiftUI
import PolyMessaging
import PolyVoice

struct ContentView: View {
    @State private var call: PolyCall?
    @State private var state: CallState = .idle
    @State private var muted = false
    @State private var audioState: AudioState = .empty
    @State private var observer: Task<Void, Never>?
    @State private var audioObserver: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 24) {
            Text("PolyAI Voice").font(.largeTitle.bold())
            Text(statusText)
                .foregroundStyle(statusColor)
                .multilineTextAlignment(.center)

            Button(action: toggleCall) {
                Text(buttonText).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(state.isActive ? .red : .accentColor)
            .disabled(isConnecting)

            if isConnected {
                Button(muted ? "Unmute" : "Mute") { toggleMute() }
                    .buttonStyle(.bordered)

                // iOS keeps one active output + auto-routes accessories; the app's real
                // control is speaker ↔ earpiece. Show the current route, toggle the speaker.
                if let selected = audioState.selectedDevice {
                    Text("Output: \(selected.name)").font(.caption).foregroundStyle(.secondary)
                    Button(isSpeaker ? "Speaker: on" : "Speaker: off") { toggleSpeaker() }
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(32)
    }

    // MARK: - Derived UI

    private var isConnecting: Bool { if case .connecting = state { return true }; return false }
    private var isConnected: Bool { if case .connected = state { return true }; return false }
    private var isSpeaker: Bool { audioState.selectedDevice?.type == .speakerphone }

    private var statusText: String {
        switch state {
        case .idle: return "Tap to call the agent"
        case .connecting: return "Connecting…"
        case .connected: return "Connected — say hello 👋"
        case .ended: return "Call ended"
        case .failed(let error): return "Failed: \(error)"
        }
    }

    private var statusColor: Color {
        switch state {
        case .connected: return .green
        case .failed: return .red
        case .connecting: return .orange
        default: return .secondary
        }
    }

    private var buttonText: String {
        switch state {
        case .connecting: return "Connecting…"
        case .connected: return "End call"
        default: return "Start call"
        }
    }

    // MARK: - Actions

    private func toggleCall() {
        if state.isActive {
            Task { await call?.end() }
        } else {
            startCall()
        }
    }

    private func startCall() {
        // Fill in your connector from Agent Studio › Connector Settings.
        let config = Configuration(apiKey: "YOUR_API_KEY")
        let newCall: PolyCall
        do {
            newCall = try PolyVoice.call(
                config: config,
                options: VoiceOptions(webrtcToken: "YOUR_WEBRTC_TOKEN")
            )
        } catch {
            state = .failed(error as? PolyError ?? .voice(.signalingFailed("\(error)")))
            return
        }
        muted = false
        call = newCall

        observer?.cancel()
        audioObserver?.cancel()
        let states = newCall.states
        observer = Task {
            for await newState in states {
                await MainActor.run { self.state = newState }
            }
        }
        let audioStates = newCall.audioState
        audioObserver = Task {
            for await snapshot in audioStates {
                await MainActor.run { self.audioState = snapshot }
            }
        }
        Task { try? await newCall.start() }
    }

    private func toggleMute() {
        muted.toggle()
        Task { await call?.setMuted(muted) }
    }

    /// Flip between the loudspeaker and the earpiece. Accessories (headset/Bluetooth) are
    /// routed by the system automatically; this is the one output an app reliably controls.
    private func toggleSpeaker() {
        let target: AudioDevice.DeviceType = isSpeaker ? .earpiece : .speakerphone
        if let device = audioState.availableDevices.first(where: { $0.type == target }) {
            Task { await call?.setAudioDevice(device) }
        }
    }
}
