import XCTest
@testable import codexAppBar

final class AppVersionTests: XCTestCase {
    func testDateBuildIsDisplayedAsPublicReleaseVersion() {
        XCTAssertEqual(
            AppVersion.display(marketingVersion: "1.9", bundleVersion: "20260714"),
            "v2026.07.14"
        )
    }

    func testDateBuildSuffixIsPreserved() {
        XCTAssertEqual(
            AppVersion.display(marketingVersion: "1.9", bundleVersion: "20260714.2"),
            "v2026.07.14.2"
        )
    }

    func testValidLeapDayIsDisplayedAsReleaseVersion() {
        XCTAssertEqual(
            AppVersion.display(marketingVersion: "1.9", bundleVersion: "20280229"),
            "v2028.02.29"
        )
    }

    func testDateBuildSuffixWithLeadingZeroFallsBackToLegacyDisplay() {
        XCTAssertEqual(
            AppVersion.display(marketingVersion: "1.9", bundleVersion: "20260714.002"),
            "v1.9 (20260714.002)"
        )
    }

    func testDateBuildZeroSuffixFallsBackToLegacyDisplay() {
        XCTAssertEqual(
            AppVersion.display(marketingVersion: "1.9", bundleVersion: "20260714.0"),
            "v1.9 (20260714.0)"
        )
    }

    func testInvalidDateBuildFallsBackToLegacyDisplay() {
        XCTAssertEqual(
            AppVersion.display(marketingVersion: "1.9", bundleVersion: "20260229"),
            "v1.9 (20260229)"
        )
    }

    func testLegacyBuildKeepsMarketingVersion() {
        XCTAssertEqual(
            AppVersion.display(marketingVersion: "1.9", bundleVersion: "42"),
            "v1.9 (42)"
        )
    }

    func testMalformedDateBuildFallsBackToLegacyDisplay() {
        XCTAssertEqual(
            AppVersion.display(marketingVersion: "1.9", bundleVersion: "20260714.1.2"),
            "v1.9 (20260714.1.2)"
        )
    }
}
