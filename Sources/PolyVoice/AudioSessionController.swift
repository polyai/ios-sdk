// Copyright PolyAI Limited

#if os(iOS)
import Foundation
import AVFoundation
import WebRTC
import PolyMessaging

/// Configures the audio session for a live call. Accessory-aware: a connected
/// headset/Bluetooth is used automatically; otherwise it falls back to the
/// loudspeaker (hands-free — the natural mode for a voice agent) when
/// `defaultToSpeaker` is true.
final class AudioSessionController: @unchecked Sendable {

    private let defaultToSpeaker: Bool
    /// CallKit drives the session lifecycle: the controller configures but never
    /// activates/deactivates, and system interruptions are CallKit's to deliver
    /// (via `didActivate`/`didDeactivate`/hold), not ours.
    let callKitMode: Bool
    private let session = RTCAudioSession.sharedInstance()
    // Guards deactivate(): never touch the process-global audio session on a call that never
    // activated it (e.g. start() failed before createOffer).
    private var activated = false

    // Sinks set by the engine (from the coordinator's actor executor) and read from
    // the AVAudioSession notification thread — so every access is under `handlerLock`.
    // Unlike `activated`/`selectedDeviceId`, these are outside the
    // `session.lockForConfiguration()` critical sections that incidentally serialize
    // the rest of this type. Handlers are always COPIED OUT and invoked after the
    // lock is released, so a sink can never re-enter this lock.
    private let handlerLock = NSLock()
    private var _onInterruption: (@Sendable (CallInterruption) -> Void)?
    private var _onAudioState: (@Sendable (AudioState) -> Void)?

    /// Sink for audio-session interruptions (phone call / Siri / another app), set by the engine.
    func setInterruptionSink(_ sink: (@Sendable (CallInterruption) -> Void)?) {
        handlerLock.lock(); _onInterruption = sink; handlerLock.unlock()
    }

    /// Sink for audio-routing snapshots (available outputs + the active one), set by the engine.
    func setAudioStateSink(_ sink: (@Sendable (AudioState) -> Void)?) {
        handlerLock.lock(); _onAudioState = sink; handlerLock.unlock()
    }

    private var interruptionSink: (@Sendable (CallInterruption) -> Void)? {
        handlerLock.lock(); defer { handlerLock.unlock() }; return _onInterruption
    }

    private var audioStateSink: (@Sendable (AudioState) -> Void)? {
        handlerLock.lock(); defer { handlerLock.unlock() }; return _onAudioState
    }
    private var selectedDeviceId: String? // nil = automatic (accessory-aware) routing
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?

    init(defaultToSpeaker: Bool, callKitMode: Bool = false) {
        self.defaultToSpeaker = defaultToSpeaker
        self.callKitMode = callKitMode
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: nil
        ) { [weak self] note in self?.handleInterruption(note) }
        // Re-route when a headset/Bluetooth is connected or removed mid-call.
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.handleRouteChange() }
    }

    deinit {
        for observer in [interruptionObserver, routeChangeObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Map an `AVAudioSession` interruption to the call's interruption vocabulary: a begin
    /// mutes the mic; an end resumes if the system allows, otherwise ends the call.
    private func handleInterruption(_ note: Notification) {
        // Under CallKit the system negotiates interruptions through the provider
        // (hold actions + didDeactivate/didActivate) — reacting here too would
        // fight it (e.g. ending a call CallKit merely put on hold).
        guard !callKitMode else { return }
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        let sink = interruptionSink
        switch type {
        case .began:
            sink?(.began)
        case .ended:
            let options = (info[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
            sink?(options.contains(.shouldResume) ? .endedResume : .endedStop)
        @unknown default:
            break
        }
    }

    func activate() {
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        selectedDeviceId = nil // a fresh call starts on automatic routing
        let config = Self.callConfiguration()
        do {
            if callKitMode {
                // NEVER self-activate under CallKit: a plain playAndRecord session
                // activated here blocks CallKit's elevated phone-session activation
                // and didActivate never fires. Configure only.
                try session.setConfiguration(config)
                activated = true
                // Route explicitly — do NOT rely on CallKit's activation route-change
                // to do it. Signaling takes seconds, so CallKit has usually activated
                // BEFORE this runs, and that route-change was dropped by
                // handleRouteChange()'s `activated` guard (still false back then).
                // Applying here covers that ordering; if CallKit hasn't activated yet
                // this is a no-op on an inactive session and the route-change that
                // arrives later re-applies it (`activated` is now true).
                applyRoute()
            } else {
                try session.setConfiguration(config, active: true)
                // Only a SUCCESSFUL activation may arm deactivate() — otherwise cleanup
                // would setActive(false) on a session this call never actually owned,
                // clobbering the host app's audio.
                activated = true
                applyRoute()
            }
            emitAudioState()
        } catch {
            // Best-effort — WebRTC is not in manual-audio mode here, so it
            // configures its own session when the audio unit starts.
        }
    }

    /// The audio-session shape of a voice call (playAndRecord/voiceChat + Bluetooth).
    static func callConfiguration() -> RTCAudioSessionConfiguration {
        let config = RTCAudioSessionConfiguration.webRTC()
        config.category = AVAudioSession.Category.playAndRecord.rawValue
        config.mode = AVAudioSession.Mode.voiceChat.rawValue
        config.categoryOptions = [.allowBluetooth, .allowBluetoothA2DP]
        return config
    }

    /// Route call audio to `device`, or `nil` to revert to automatic (accessory-aware) routing.
    func select(_ device: AudioDevice?) {
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        guard activated else { return }
        selectedDeviceId = device?.id
        applySelection(device)
        emitAudioState()
    }

    /// Re-evaluate the output route (accessory-aware). Must be called under `lockForConfiguration`.
    /// Forcing the loudspeaker only when nothing external is connected — and clearing the override
    /// (`.none`) otherwise — lets a headset/Bluetooth connected mid-call take over the sticky speaker.
    private func applyRoute() {
        try? session.overrideOutputAudioPort(defaultToSpeaker && !hasExternalOutput() ? .speaker : .none)
    }

    /// A mid-call route change (headset plugged/unplugged, Bluetooth connect/disconnect) → re-route.
    private func handleRouteChange() {
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        guard activated else { return }
        if selectedDeviceId == nil { applyRoute() } // only auto-route when the user hasn't pinned a device
        emitAudioState()
    }

    // MARK: - Device enumeration / selection

    private func applySelection(_ device: AudioDevice?) {
        let av = AVAudioSession.sharedInstance()
        guard let device else { // automatic
            try? av.setPreferredInput(nil)
            applyRoute()
            return
        }
        switch device.type {
        case .speakerphone:
            try? av.setPreferredInput(nil)
            try? session.overrideOutputAudioPort(.speaker)
        case .earpiece:
            try? av.setPreferredInput(nil)
            try? session.overrideOutputAudioPort(.none)
        case .wiredHeadset, .bluetooth:
            if let input = av.availableInputs?.first(where: { $0.uid == device.id }) {
                try? av.setPreferredInput(input)
            }
            try? session.overrideOutputAudioPort(.none)
        case .unknown:
            break
        }
    }

    private func emitAudioState() {
        audioStateSink?(currentAudioState())
    }

    /// A snapshot of routable outputs + the active one, from the current `AVAudioSession` route.
    private func currentAudioState() -> AudioState {
        let av = AVAudioSession.sharedInstance()
        // Built-in earpiece + speaker are always routable during a playAndRecord call.
        var devices: [AudioDevice] = [
            AudioDevice(type: .earpiece, name: "iPhone", id: "builtin.earpiece"),
            AudioDevice(type: .speakerphone, name: "Speaker", id: "builtin.speaker"),
        ]
        for input in av.availableInputs ?? [] {
            switch input.portType {
            case .headphones, .headsetMic, .usbAudio, .lineIn:
                devices.append(AudioDevice(type: .wiredHeadset, name: input.portName, id: input.uid))
            case .bluetoothHFP, .bluetoothA2DP, .bluetoothLE:
                devices.append(AudioDevice(type: .bluetooth, name: input.portName, id: input.uid))
            default:
                break
            }
        }
        // `availableInputs` only lists input-capable ports — an output-only route
        // (e.g. a Bluetooth A2DP speaker) would otherwise be missing entirely, so
        // fold in whatever the CURRENT route is playing through as well.
        for output in av.currentRoute.outputs {
            switch output.portType {
            case .headphones, .usbAudio, .lineOut:
                devices.append(AudioDevice(type: .wiredHeadset, name: output.portName, id: output.uid))
            case .bluetoothHFP, .bluetoothA2DP, .bluetoothLE, .carAudio:
                devices.append(AudioDevice(type: .bluetooth, name: output.portName, id: output.uid))
            default:
                break
            }
        }
        var seen = Set<String>()
        let unique = devices.filter { seen.insert($0.id).inserted }
        return AudioState(availableDevices: unique, selectedDevice: selectedOutput(from: av, among: unique))
    }

    /// Resolve the active output to one of `available` by category (built-ins by id, accessories by type).
    private func selectedOutput(from av: AVAudioSession, among available: [AudioDevice]) -> AudioDevice? {
        guard let output = av.currentRoute.outputs.first else { return nil }
        switch output.portType {
        case .builtInReceiver: return available.first { $0.type == .earpiece }
        case .builtInSpeaker:  return available.first { $0.type == .speakerphone }
        case .headphones, .usbAudio, .lineOut:
            return available.first { $0.id == output.uid } ?? available.first { $0.type == .wiredHeadset }
        case .bluetoothHFP, .bluetoothA2DP, .bluetoothLE, .carAudio:
            return available.first { $0.id == output.uid } ?? available.first { $0.type == .bluetooth }
        default:
            return available.first { $0.id == output.uid }
        }
    }

    func deactivate() {
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        guard activated else { return } // nothing was acquired — don't clobber the host app's audio
        activated = false
        selectedDeviceId = nil
        try? session.overrideOutputAudioPort(.none)
        if !callKitMode {
            // Under CallKit the SYSTEM deactivates (didDeactivate) — doing it here
            // would tear down a session the app doesn't own at this priority.
            try? session.setActive(false)
        }
        audioStateSink?(.empty)
    }

    /// True when a wired or Bluetooth output is currently connected.
    private func hasExternalOutput() -> Bool {
        let external: Set<AVAudioSession.Port> = [
            .headphones, .bluetoothHFP, .bluetoothA2DP, .bluetoothLE, .usbAudio, .carAudio,
        ]
        return AVAudioSession.sharedInstance().currentRoute.outputs.contains { external.contains($0.portType) }
    }
}
#endif
