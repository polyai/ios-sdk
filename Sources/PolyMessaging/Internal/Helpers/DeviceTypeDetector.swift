// Copyright PolyAI Limited

import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Device form factor reported on session create, for analytics segmentation.
/// Orthogonal to ``Platform`` (`ios` = embedding channel), not a replacement: an
/// `ios` session can be a phone or tablet, and on macOS it's a desktop. Mirrors
/// the web SDK's `device_type` dimension (MES-537).
public enum DeviceType: String, Sendable {
    case mobile
    case tablet
    case desktop
}

/// Resolves the running device's form factor.
///
/// The pure ``deviceType(for:)`` mapping is split from the impure ``detect()``
/// (`UIDevice`/UIKit) read so the classification is unit-testable on any host,
/// including the macOS test runner. Mirrors the web SDK's `readDeviceSignals` /
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

    /// Pure classification; anything not unambiguously phone/tablet falls back to
    /// `.desktop` — MES-537's required default and correct for Mac Catalyst/macOS.
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
