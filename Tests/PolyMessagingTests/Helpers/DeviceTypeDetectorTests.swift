// Copyright PolyAI Limited

import XCTest
@testable import PolyMessaging

final class DeviceTypeDetectorTests: XCTestCase {

    // MARK: - Pure mapping (deviceType(for:))

    func testPhoneIsMobile() {
        XCTAssertEqual(DeviceTypeDetector.deviceType(for: .phone), .mobile)
    }

    func testPadIsTablet() {
        XCTAssertEqual(DeviceTypeDetector.deviceType(for: .pad), .tablet)
    }

    func testMacIsDesktop() {
        // Mac Catalyst (`.mac` idiom) — and the requirement that running on a
        // Mac reports `desktop`.
        XCTAssertEqual(DeviceTypeDetector.deviceType(for: .mac), .desktop)
    }

    func testOtherIdiomFallsBackToDesktop() {
        // tvOS / visionOS / `.unspecified` — MES-537's ambiguous→desktop default.
        XCTAssertEqual(DeviceTypeDetector.deviceType(for: .other), .desktop)
    }

    // MARK: - Live detection

    func testDetectReturnsAValidDeviceType() {
        // On the macOS test host there is no UIKit idiom, so this resolves to
        // `.desktop`; on a device it reflects the real idiom. Either way it must
        // be one of the three known classes.
        let detected = DeviceTypeDetector.detect()
        XCTAssertTrue([.mobile, .tablet, .desktop].contains(detected))
    }

    func testRawValuesMatchWireContract() {
        // The string sent as `device_type` must match the web SDK / backend
        // column exactly.
        XCTAssertEqual(DeviceType.mobile.rawValue, "mobile")
        XCTAssertEqual(DeviceType.tablet.rawValue, "tablet")
        XCTAssertEqual(DeviceType.desktop.rawValue, "desktop")
    }
}
