// Copyright PolyAI Limited

import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Device form factor reported on session create. Orthogonal to ``Platform``
/// (`ios` can be phone or tablet). Mirrors the web SDK's `device_type` (MES-537).
public enum DeviceType: String, Sendable {
    case mobile
    case tablet
    case desktop
}

/// Pure ``deviceType(for:)`` mapping is split from the impure ``detect()`` read
/// so classification is unit-testable on any host (incl. the macOS test runner).
enum DeviceTypeDetector {

    /// Decoupled from `UIUserInterfaceIdiom` so the mapping works without UIKit.
    enum InterfaceIdiom {
        case phone
        case pad
        case mac
        /// tvOS, visionOS, `.unspecified`, etc.
        case other
    }

    /// Anything not phone/tablet falls back to `.desktop` (MES-537's default).
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

    /// Without UIKit (native macOS) there is no idiom to read, so it's a desktop.
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
