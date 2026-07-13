import XCTest
@testable import codexAppBar

final class WeeklyQuotaTests: XCTestCase {
    func testNewSingleWindowResponseUsesPrimaryAsWeekly() throws {
        let result = try WhamService.shared.parseUsage([
            "plan_type": "pro",
            "rate_limit": [
                "primary_window": window(used: 23, seconds: 604_800, resetAt: 1_800_000_000),
                "secondary_window": NSNull()
            ]
        ])

        XCTAssertEqual(result.weeklyUsedPercent, 23)
        XCTAssertEqual(result.weeklyResetAt?.timeIntervalSince1970, 1_800_000_000)
    }

    func testLegacyDualWindowResponseUsesSecondaryAsWeekly() throws {
        let result = try WhamService.shared.parseUsage([
            "rate_limit": [
                "primary_window": window(used: 91, seconds: 18_000, resetAt: 1_700_000_000),
                "secondary_window": window(used: 42, seconds: 604_800, resetAt: 1_800_000_000)
            ]
        ])

        XCTAssertEqual(result.weeklyUsedPercent, 42)
        XCTAssertEqual(result.weeklyResetAt?.timeIntervalSince1970, 1_800_000_000)
    }

    func testWindowPositionDoesNotDefineWeeklySemantics() throws {
        let result = try WhamService.shared.parseUsage([
            "rate_limit": [
                "primary_window": window(used: 17, seconds: 604_800, resetAt: 1_800_000_000),
                "secondary_window": window(used: 88, seconds: 18_000, resetAt: 1_700_000_000)
            ]
        ])

        XCTAssertEqual(result.weeklyUsedPercent, 17)
    }

    func testMissingWeeklyWindowFailsInsteadOfReturningZero() {
        XCTAssertThrowsError(try WhamService.shared.parseUsage([
            "rate_limit": [
                "primary_window": window(used: 55, seconds: 18_000, resetAt: 1_700_000_000),
                "secondary_window": NSNull()
            ]
        ])) { error in
            XCTAssertEqual(error as? WhamError, .parseError)
        }
    }

    func testUsedPercentIsClamped() throws {
        let result = try WhamService.shared.parseUsage([
            "rate_limit": [
                "primary_window": window(used: 150, seconds: 604_800, resetAt: 1_800_000_000)
            ]
        ])

        XCTAssertEqual(result.weeklyUsedPercent, 100)
    }

    func testLegacyTokenPoolMigratesSecondaryWindowAndWritesWeeklyKeys() throws {
        let checkedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let weeklyResetAt = checkedAt.addingTimeInterval(4 * 24 * 60 * 60)
        let account = try decodeLegacyAccount(
            primaryUsed: 75,
            secondaryUsed: 36,
            primaryResetAt: checkedAt.addingTimeInterval(2 * 60 * 60),
            secondaryResetAt: weeklyResetAt,
            checkedAt: checkedAt
        )

        XCTAssertEqual(account.weeklyUsedPercent, 36)
        XCTAssertEqual(account.weeklyResetAt, weeklyResetAt)

        let encoded = try makeEncoder().encode(account)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(json["weekly_used_percent"] as? Double, 36)
        XCTAssertNotNil(json["weekly_reset_at"])
        XCTAssertNil(json["primary_used_percent"])
        XCTAssertNil(json["secondary_used_percent"])
    }

    func testPoolSavedByOldAppAfterRolloutMigratesPrimarySevenDayWindow() throws {
        let checkedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let weeklyResetAt = checkedAt.addingTimeInterval(6 * 24 * 60 * 60)
        let account = try decodeLegacyAccount(
            primaryUsed: 64,
            secondaryUsed: 0,
            primaryResetAt: weeklyResetAt,
            secondaryResetAt: nil,
            checkedAt: checkedAt
        )

        XCTAssertEqual(account.weeklyUsedPercent, 64)
        XCTAssertEqual(account.weeklyResetAt, weeklyResetAt)
    }

    func testUsageStatusUsesOnlyWeeklyQuota() {
        XCTAssertEqual(TokenAccount(weeklyUsedPercent: 79.9).usageStatus, .ok)
        XCTAssertEqual(TokenAccount(weeklyUsedPercent: 80).usageStatus, .warning)
        XCTAssertEqual(TokenAccount(weeklyUsedPercent: 100).usageStatus, .exceeded)
        XCTAssertTrue(TokenAccount(weeklyUsedPercent: 100).weeklyExhausted)
    }

    private func window(used: Double, seconds: Int, resetAt: TimeInterval) -> [String: Any] {
        [
            "used_percent": used,
            "limit_window_seconds": seconds,
            "reset_at": resetAt
        ]
    }

    private func decodeLegacyAccount(
        primaryUsed: Double,
        secondaryUsed: Double,
        primaryResetAt: Date?,
        secondaryResetAt: Date?,
        checkedAt: Date
    ) throws -> TokenAccount {
        var json: [String: Any] = [
            "email": "test@example.com",
            "account_id": "account",
            "chatgpt_account_id": "workspace",
            "access_token": "access",
            "refresh_token": "refresh",
            "id_token": "id",
            "plan_type": "pro",
            "primary_used_percent": primaryUsed,
            "secondary_used_percent": secondaryUsed,
            "last_checked": iso8601(checkedAt),
            "is_active": true,
            "is_suspended": false,
            "token_expired": false
        ]
        if let primaryResetAt { json["primary_reset_at"] = iso8601(primaryResetAt) }
        if let secondaryResetAt { json["secondary_reset_at"] = iso8601(secondaryResetAt) }
        let data = try JSONSerialization.data(withJSONObject: json)
        return try makeDecoder().decode(TokenAccount.self, from: data)
    }

    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
