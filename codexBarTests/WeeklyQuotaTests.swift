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

        XCTAssertNil(result.fiveHourUsedPercent)
        XCTAssertNil(result.fiveHourResetAt)
        XCTAssertEqual(result.weeklyUsedPercent, 23)
        XCTAssertEqual(result.weeklyResetAt?.timeIntervalSince1970, 1_800_000_000)
    }

    func testPlusDualWindowResponseRestoresFiveHourAndWeeklyQuota() throws {
        let result = try WhamService.shared.parseUsage([
            "plan_type": "plus",
            "rate_limit": [
                "primary_window": window(used: 61, seconds: 18_000, resetAt: 1_700_000_000),
                "secondary_window": window(used: 42, seconds: 604_800, resetAt: 1_800_000_000)
            ]
        ])

        XCTAssertEqual(result.fiveHourUsedPercent, 61)
        XCTAssertEqual(result.fiveHourResetAt?.timeIntervalSince1970, 1_700_000_000)
        XCTAssertEqual(result.weeklyUsedPercent, 42)
        XCTAssertEqual(result.weeklyResetAt?.timeIntervalSince1970, 1_800_000_000)
    }

    func testWindowPositionDoesNotDefinePlusQuotaSemantics() throws {
        let result = try WhamService.shared.parseUsage([
            "plan_type": "plus",
            "rate_limit": [
                "primary_window": window(used: 17, seconds: 604_800, resetAt: 1_800_000_000),
                "secondary_window": window(used: 88, seconds: 18_000, resetAt: 1_700_000_000)
            ]
        ])

        XCTAssertEqual(result.fiveHourUsedPercent, 88)
        XCTAssertEqual(result.weeklyUsedPercent, 17)
    }

    func testProIgnoresFiveHourWindowAndKeepsWeeklyOnly() throws {
        let result = try WhamService.shared.parseUsage([
            "plan_type": "pro",
            "rate_limit": [
                "primary_window": window(used: 91, seconds: 18_000, resetAt: 1_700_000_000),
                "secondary_window": window(used: 37, seconds: 604_800, resetAt: 1_800_000_000)
            ]
        ])

        XCTAssertNil(result.fiveHourUsedPercent)
        XCTAssertNil(result.fiveHourResetAt)
        XCTAssertEqual(result.weeklyUsedPercent, 37)
    }

    func testLegacyDualWindowResponseUsesSecondaryAsWeekly() throws {
        let result = try WhamService.shared.parseUsage([
            "rate_limit": [
                "primary_window": window(used: 91, seconds: 18_000, resetAt: 1_700_000_000),
                "secondary_window": window(used: 42, seconds: 604_800, resetAt: 1_800_000_000)
            ]
        ])

        XCTAssertNil(result.fiveHourUsedPercent)
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
            "plan_type": "plus",
            "rate_limit": [
                "primary_window": window(used: -10, seconds: 18_000, resetAt: 1_700_000_000),
                "secondary_window": window(used: 150, seconds: 604_800, resetAt: 1_800_000_000)
            ]
        ])

        XCTAssertEqual(result.fiveHourUsedPercent, 0)
        XCTAssertEqual(result.weeklyUsedPercent, 100)
    }

    func testCodexLiveQuotaEventOverridesLaggingWhamValueForSameWindow() throws {
        let line = Data(#"{"timestamp":"2026-07-16T16:20:51.266Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":21.0,"window_minutes":10080,"resets_at":1784788618},"plan_type":"prolite"}}}"#.utf8)
        let snapshot = try XCTUnwrap(CodexLiveQuotaParser.snapshot(from: line))
        let now = Date(timeIntervalSince1970: 1_784_220_000)

        let resolved = CodexLiveQuotaResolver.resolvedUsedPercent(
            whamUsedPercent: 9,
            whamResetAt: Date(timeIntervalSince1970: 1_784_788_618),
            whamPlanType: "prolite",
            liveSnapshot: snapshot,
            now: now
        )

        XCTAssertEqual(resolved, 21)
    }

    func testCodexLiveQuotaParserReadsBothPlusWindowsAndKeepsWeeklyCompatibility() throws {
        let observedAt = Date(timeIntervalSince1970: 1_784_220_000)
        let fiveHourResetAt = Date(timeIntervalSince1970: 1_784_230_000)
        let weeklyResetAt = Date(timeIntervalSince1970: 1_784_788_618)
        let line = Data(dualQuotaEventLine(
            timestamp: observedAt,
            fiveHourUsedPercent: 64,
            fiveHourResetAt: fiveHourResetAt,
            weeklyUsedPercent: 22,
            weeklyResetAt: weeklyResetAt,
            planType: "plus"
        ).utf8)

        let snapshots = CodexLiveQuotaParser.snapshots(from: line)
        XCTAssertEqual(snapshots.count, 2)
        XCTAssertTrue(snapshots.contains(where: {
            $0.usedPercent == 64 && $0.resetAt == fiveHourResetAt
        }))
        XCTAssertTrue(snapshots.contains(where: {
            $0.usedPercent == 22 && $0.resetAt == weeklyResetAt
        }))

        let weeklySnapshot = try XCTUnwrap(CodexLiveQuotaParser.snapshot(from: line))
        XCTAssertEqual(weeklySnapshot.usedPercent, 22)
        XCTAssertEqual(weeklySnapshot.resetAt, weeklyResetAt)
    }

    func testCodexLiveQuotaNeverRegressesNewerWhamValue() {
        let now = Date(timeIntervalSince1970: 1_784_220_000)
        let resetAt = Date(timeIntervalSince1970: 1_784_788_618)
        let snapshot = CodexLiveQuotaSnapshot(
            usedPercent: 21,
            resetAt: resetAt,
            observedAt: now,
            planType: "prolite"
        )

        XCTAssertEqual(
            CodexLiveQuotaResolver.resolvedUsedPercent(
                whamUsedPercent: 25,
                whamResetAt: resetAt,
                whamPlanType: "prolite",
                liveSnapshot: snapshot,
                now: now
            ),
            25
        )
    }

    func testCodexLiveQuotaRejectsDifferentResetWindowOrPlan() {
        let now = Date(timeIntervalSince1970: 1_784_220_000)
        let snapshot = CodexLiveQuotaSnapshot(
            usedPercent: 21,
            resetAt: Date(timeIntervalSince1970: 1_784_788_618),
            observedAt: now,
            planType: "prolite"
        )

        XCTAssertEqual(
            CodexLiveQuotaResolver.resolvedUsedPercent(
                whamUsedPercent: 9,
                whamResetAt: Date(timeIntervalSince1970: 1_784_700_000),
                whamPlanType: "prolite",
                liveSnapshot: snapshot,
                now: now
            ),
            9
        )
        XCTAssertEqual(
            CodexLiveQuotaResolver.resolvedUsedPercent(
                whamUsedPercent: 9,
                whamResetAt: snapshot.resetAt,
                whamPlanType: "team",
                liveSnapshot: snapshot,
                now: now
            ),
            9
        )
    }

    func testCodexLiveQuotaStoreMatchesWindowAndIncrementallyCompletesPartialLine() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("codex-live-quota-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = Date(timeIntervalSince1970: 1_784_220_000)
        let resetAt = Date(timeIntervalSince1970: 1_784_788_618)
        let components = calendar.dateComponents([.year, .month, .day], from: now)
        let directory = root
            .appendingPathComponent(String(format: "%04d", try XCTUnwrap(components.year)), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", try XCTUnwrap(components.month)), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", try XCTUnwrap(components.day)), isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("rollout-test.jsonl")

        let matchingLine = quotaEventLine(
            timestamp: now.addingTimeInterval(-60),
            usedPercent: 21,
            resetAt: resetAt,
            planType: "prolite"
        )
        let newerDifferentPlanLine = quotaEventLine(
            timestamp: now.addingTimeInterval(-30),
            usedPercent: 80,
            resetAt: resetAt,
            planType: "team"
        )
        try Data("\(matchingLine)\n\(newerDifferentPlanLine)\n".utf8).write(to: fileURL)

        let store = CodexLiveQuotaStore(sessionsURL: root, calendar: calendar)
        let matchingSnapshot = await store.latestSnapshot(
            matchingResetAt: resetAt,
            planType: "prolite",
            now: now
        )
        XCTAssertEqual(matchingSnapshot?.usedPercent, 21)

        let updatedLine = Data(quotaEventLine(
            timestamp: now.addingTimeInterval(-10),
            usedPercent: 23,
            resetAt: resetAt,
            planType: "prolite"
        ).utf8)
        let splitIndex = updatedLine.count / 2
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: updatedLine.prefix(splitIndex))

        let beforeCompletion = await store.latestSnapshot(
            matchingResetAt: resetAt,
            planType: "prolite",
            now: now
        )
        XCTAssertEqual(beforeCompletion?.usedPercent, 21)

        try handle.write(contentsOf: updatedLine.suffix(from: splitIndex))
        try handle.write(contentsOf: Data("\n".utf8))
        let afterCompletion = await store.latestSnapshot(
            matchingResetAt: resetAt,
            planType: "prolite",
            now: now
        )
        XCTAssertEqual(afterCompletion?.usedPercent, 23)
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
        XCTAssertNil(json["five_hour_used_percent"])
        XCTAssertNil(json["primary_used_percent"])
        XCTAssertNil(json["secondary_used_percent"])
    }

    func testLegacyPlusPoolRestoresFiveHourWindowAndWritesCanonicalKeys() throws {
        let checkedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let fiveHourResetAt = checkedAt.addingTimeInterval(2 * 60 * 60)
        let weeklyResetAt = checkedAt.addingTimeInterval(4 * 24 * 60 * 60)
        let account = try decodeLegacyAccount(
            planType: "plus",
            primaryUsed: 75,
            secondaryUsed: 36,
            primaryResetAt: fiveHourResetAt,
            secondaryResetAt: weeklyResetAt,
            checkedAt: checkedAt
        )

        XCTAssertTrue(account.hasFiveHourQuota)
        XCTAssertEqual(account.fiveHourUsedPercent, 75)
        XCTAssertEqual(account.fiveHourResetAt, fiveHourResetAt)
        XCTAssertEqual(account.weeklyUsedPercent, 36)

        let encoded = try makeEncoder().encode(account)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(json["five_hour_used_percent"] as? Double, 75)
        XCTAssertNotNil(json["five_hour_reset_at"])
        XCTAssertEqual(json["weekly_used_percent"] as? Double, 36)
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

    func testUsageStatusUsesPlanAwareQuotaWindows() {
        XCTAssertEqual(TokenAccount(weeklyUsedPercent: 79.9).usageStatus, .ok)
        XCTAssertEqual(TokenAccount(weeklyUsedPercent: 80).usageStatus, .warning)
        XCTAssertEqual(TokenAccount(weeklyUsedPercent: 100).usageStatus, .exceeded)
        XCTAssertTrue(TokenAccount(weeklyUsedPercent: 100).weeklyExhausted)

        let plusWarning = TokenAccount(planType: "plus", fiveHourUsedPercent: 80, weeklyUsedPercent: 10)
        XCTAssertTrue(plusWarning.hasFiveHourQuota)
        XCTAssertEqual(plusWarning.usageStatus, .warning)

        let plusExhausted = TokenAccount(planType: "plus", fiveHourUsedPercent: 100, weeklyUsedPercent: 10)
        XCTAssertTrue(plusExhausted.fiveHourExhausted)
        XCTAssertTrue(plusExhausted.quotaExhausted)
        XCTAssertEqual(plusExhausted.usageStatus, .exceeded)

        let pro = TokenAccount(planType: "pro", fiveHourUsedPercent: 100, weeklyUsedPercent: 10)
        XCTAssertFalse(pro.hasFiveHourQuota)
        XCTAssertNil(pro.fiveHourUsedPercent)
        XCTAssertFalse(pro.quotaExhausted)
        XCTAssertEqual(pro.usageStatus, .ok)
    }

    private func window(used: Double, seconds: Int, resetAt: TimeInterval) -> [String: Any] {
        [
            "used_percent": used,
            "limit_window_seconds": seconds,
            "reset_at": resetAt
        ]
    }

    private func quotaEventLine(
        timestamp: Date,
        usedPercent: Double,
        resetAt: Date,
        planType: String
    ) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return #"{"timestamp":"\#(formatter.string(from: timestamp))","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":\#(usedPercent),"window_minutes":10080,"resets_at":\#(resetAt.timeIntervalSince1970)},"plan_type":"\#(planType)"}}}"#
    }

    private func dualQuotaEventLine(
        timestamp: Date,
        fiveHourUsedPercent: Double,
        fiveHourResetAt: Date,
        weeklyUsedPercent: Double,
        weeklyResetAt: Date,
        planType: String
    ) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return #"{"timestamp":"\#(formatter.string(from: timestamp))","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":\#(fiveHourUsedPercent),"window_minutes":300,"resets_at":\#(fiveHourResetAt.timeIntervalSince1970)},"secondary":{"used_percent":\#(weeklyUsedPercent),"window_minutes":10080,"resets_at":\#(weeklyResetAt.timeIntervalSince1970)},"plan_type":"\#(planType)"}}}"#
    }

    private func decodeLegacyAccount(
        planType: String = "pro",
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
            "plan_type": planType,
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
