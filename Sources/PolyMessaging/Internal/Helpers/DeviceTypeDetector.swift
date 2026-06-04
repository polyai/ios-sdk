// Copyright PolyAI Limited

import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Device *class* (form factor) reported on session create so analytics can
/// segment traffic by device. Orthogonal to ``Platform`` (`ios`), not a
/// replacement: `platform` is the embedding *channel* (the native SDK), while
/// `deviceType` is the physical *device class*. An `ios` session can be a phone
/// or a tablet — and the same SDK running on macOS is a desktop. Mirrors the
/// web SDK's `device_type` dimension (MES-537).
public enum DeviceType: String, Sendable {
    case mobile
    case tablet
    case desktop
}

/// Resolves the running device's form factor.
///
/// The pure ``deviceType(for:)`` mapping is deliberately split from the impure
/// ``detect()`` read (`UIDevice` / UIKit) so the classification logic is
/// unit-testable on any host — including the macOS test runner, which has no
/// device idiom to read. This mirrors the web SDK's `readDeviceSignals` /
/// `detectDeviceType` split.
enum DeviceTypeDetector {

    /// Abstract interface idiom, decoupled from `UIUserInterfaceIdiom` so the
    /// mapping can be exercised without UIKit.
    enum InterfaceIdiom {
        case phone
        case pad
        case mac
        /// Any other / unknown idiom (tvOS, visionOS, `.unspecified`, …).
        case other
    }

    /// Pure classification. Anything that isn't unambiguously a phone or tablet
    /// falls back to `.desktop` — both MES-537's required default and the
    /// correct answer for Mac Catalyst (`.mac`) and native macOS builds.
    static func deviceType(for idiom: InterfaceIdiom) -> DeviceType {
        switch idiom {
        case .phone:
            return .mobile
        case .pad:
            return .tablet
        case .mac, .other:
            return .desktop
        }
    }

    /// Reads the live interface idiom. On platforms without UIKit (a native
    /// macOS build) there is no idiom to read, so the device is a desktop.
    static func detect() -> DeviceType {
        #if canImport(UIKit) && !os(watchOS)
        return deviceType(for: currentIdiom())
        #else
        return .desktop
        #endif
    }

    #if canImport(UIKit) && !os(watchOS)
    private static func currentIdiom() -> InterfaceIdiom {
        switch UIDevice.current.userInterfaceIdiom {
        case .phone:
            return .phone
        case .pad:
            return .pad
        case .mac:
            return .mac
        default:
            return .other
        }
    }
    #endif
}
