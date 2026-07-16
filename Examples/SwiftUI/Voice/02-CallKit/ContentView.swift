// Copyright PolyAI Limited

import SwiftUI
import PolyMessaging
import PolyVoice

/// 01-Hello's tap-to-call, now as a **system call**: CallKit shows the green
/// call indicator, lock-screen / AirPods / car controls work, and a cellular
/// call offers hold instead of killing the agent call. All user intents route
/// through `CallKitController`; the `PolyCall` only ever reacts to the
/// provider's `perform` callbacks.
///
/// CallKit is broken on the simulator (calls are auto-ended, `didActivate`
/// never fires), so there the example falls back to a plain 01-Hello-style call.
struct ContentView: View {
    @State private var call: PolyCall?
    @State private var state: CallState = .idle
    @State private var muted = false
    @State private var audioState: AudioState = .empty
    @State private var observer: Task<Void, Never>?
    @State private var audioObserver: Task<Void, Never>?
    @State private var callKit = CallKitController()

    #if targetEnvironment(simulator)
    private let callKitAvailable = false
    #else
    private let callKitAvailable = true
    #endif

    var body: some View {
        VStack(spacing: 24) {
            Text("PolyAI Voice + CallKit").font(.largeTitle.bold())
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

                if let selected = audioState.selectedDevice {
                    Text("Output: \(selected.name)").font(.caption).foregroundStyle(.secondary)
                    Button(isSpeaker ? "Speaker: on" : "Speaker: off") { toggleSpeaker() }
                        .buttonStyle(.bordered)
                }

                Text("Lock the screen or background the app —\nthe call survives, and the system UI controls it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
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

    // MARK: - Actions (user intents go to CallKit; the call obeys `perform`)

    private func toggleCall() {
        if state.isActive {
            if callKitAvailable { callKit.requestEnd() } else { Task { await call?.end() } }
        } else {
            startCall()
        }
    }

    private func toggleMute() {
        if callKitAvailable {
            callKit.requestMute(!muted) // state updates when CallKit performs it
        } else {
            muted.toggle()
            Task { await call?.setMuted(muted) }
        }
    }

    private func startCall() {
        // Fill in your connector from Agent Studio › Connector Settings.
        let config = Configuration(apiKey: "YOUR_API_KEY")
        let newCall: PolyCall
        do {
            newCall = try PolyVoice.call(
                config: config,
                options: VoiceOptions(
                    webrtcToken: "YOUR_WEBRTC_TOKEN",
                    callKit: callKitAvailable // audio start/stop deferred to CallKit
                )
            )
        } catch {
            state = .failed(error as? PolyError ?? .voice(.signalingFailed("\(error)")))
            return
        }
        muted = false
        call = newCall
        observeCall(newCall)

        // The system approves the call, then `perform(CXStartCallAction)` runs
        // `performStart` below. Without CallKit (simulator), start directly.
        callKit.performStart = { Task { try? await newCall.start() } }
        callKit.performEnd = { Task { await newCall.end() } }
        callKit.performMute = { m in
            Task { await newCall.setMuted(m) }
            muted = m
        }
        callKit.onRequestError = { error in
            Task { @MainActor in
                state = .failed(.voice(.signalingFailed("CallKit refused the call: \(error.localizedDescription)")))
            }
        }
        if callKitAvailable {
            callKit.requestStart(agentName: "PolyAI Agent")
        } else {
            Task { try? await newCall.start() }
        }
    }

    /// Mirror the call's real state into CallKit: connected → the system call
    /// timer starts; agent hangup / failure → reported (a user hangup was
    /// already a `CXEndCallAction`, so `reportEnded` no-ops by then).
    private func observeCall(_ newCall: PolyCall) {
        observer?.cancel()
        audioObserver?.cancel()
        let states = newCall.states
        observer = Task {
            for await newState in states {
                await MainActor.run {
                    self.state = newState
                    guard callKitAvailable else { return }
                    switch newState {
                    case .connected: callKit.reportConnected()
                    case .ended: callKit.reportEnded(failed: false)
                    case .failed: callKit.reportEnded(failed: true)
                    default: break
                    }
                }
            }
        }
        let audioStates = newCall.audioState
        audioObserver = Task {
            for await snapshot in audioStates {
                await MainActor.run { self.audioState = snapshot }
            }
        }
    }

    /// Flip between the loudspeaker and the earpiece. Accessories (headset/Bluetooth)
    /// are routed by the system automatically; this works under CallKit too.
    private func toggleSpeaker() {
        let target: AudioDevice.DeviceType = isSpeaker ? .earpiece : .speakerphone
        if let device = audioState.availableDevices.first(where: { $0.type == target }) {
            Task { await call?.setAudioDevice(device) }
        }
    }
}
