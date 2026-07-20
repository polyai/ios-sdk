// Copyright PolyAI Limited

import Foundation

/// An audio output a call can be routed to (earpiece, loudspeaker, wired headset, Bluetooth).
///
/// Obtain instances from ``PolyCall/audioState`` — never construct one. Pass an instance to
/// ``PolyCall/setAudioDevice(_:)`` to switch the live call's output, or `nil` to revert to
/// automatic routing.
public struct AudioDevice: Sendable, Equatable, Identifiable {

    /// The category of an ``AudioDevice`` — pick an icon/label without string-matching `name`.
    public enum Kind: Sendable, Equatable {
        case earpiece
        case speakerphone
        case wiredHeadset
        case bluetooth
        case unknown
    }

    /// The kind of output.
    public let kind: Kind
    /// Human-readable label for a picker (e.g. `"AirPods Pro"`, `"Speaker"`).
    public let name: String
    /// Opaque, stable identity (the `AVAudioSession` port UID, or a synthetic id for the
    /// built-in earpiece/speaker). Part of `Equatable`/`id` so two Bluetooth devices stay distinct.
    public let id: String

    /// Constructed by the SDK's audio engine — you obtain instances from ``PolyCall/audioState``,
    /// you don't build them yourself.
    ///
    /// SPI rather than API: `PolyVoice` is a separate module and needs to build these,
    /// but that's an SDK-internal need. Keeping it out of the public surface means the
    /// memberwise shape isn't semver-locked.
    @_spi(PolyVoice)
    public init(kind: Kind, name: String, id: String) {
        self.kind = kind
        self.name = name
        self.id = id
    }

    public static func == (lhs: AudioDevice, rhs: AudioDevice) -> Bool {
        lhs.kind == rhs.kind && lhs.id == rhs.id
    }
}

/// A consistent snapshot of audio routing: the outputs available right now and which one is active.
///
/// Delivered as a single value (not two flows) so `availableDevices` and `selectedDevice` can never
/// momentarily disagree. Observe it via ``PolyCall/audioState`` to drive a device picker.
public struct AudioState: Sendable, Equatable {
    /// Every output the call can currently be routed to. Empty before the call's audio is engaged.
    public let availableDevices: [AudioDevice]
    /// The active output, or `nil` before the call's audio is engaged.
    public let selectedDevice: AudioDevice?

    public init(availableDevices: [AudioDevice], selectedDevice: AudioDevice?) {
        self.availableDevices = availableDevices
        self.selectedDevice = selectedDevice
    }

    /// The pre-call / torn-down snapshot: nothing available, nothing selected.
    public static let empty = AudioState(availableDevices: [], selectedDevice: nil)
}
