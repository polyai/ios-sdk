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
        // Mac Catalyst (`.mac` idiom) must report `desktop`.
        XCTAssertEqual(DeviceTypeDetector.deviceType(for: .mac), .desktop)
    }

    func testOtherIdiomFallsBackToDesktop() {
        // tvOS / visionOS / `.unspecified` — MES-537's ambiguous→desktop default.
        XCTAssertEqual(DeviceTypeDetector.deviceType(for: .other), .desktop)
    }

    // MARK: - Live detection

    func testDetectReturnsAValidDeviceType() {
        // No UIKit idiom on the macOS test host, so this resolves to `.desktop`.
        let detected = DeviceTypeDetector.detect()
        XCTAssertTrue([.mobile, .tablet, .desktop].contains(detected))
    }

    func testRawValuesMatchWireContract() {
        // `device_type` wire strings must match the web SDK / backend exactly.
        XCTAssertEqual(DeviceType.mobile.rawValue, "mobile")
        XCTAssertEqual(DeviceType.tablet.rawValue, "tablet")
        XCTAssertEqual(DeviceType.desktop.rawValue, "desktop")
    }
}
