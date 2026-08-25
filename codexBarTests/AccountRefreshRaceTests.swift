import Foundation
import XCTest
@testable import codexAppBar

@MainActor
final class AccountRefreshRaceTests: XCTestCase {
    private let usagePath = "/backend-api/wham/usage"
    private let orgPath = "/backend-api/accounts/check/v4-2023-04-27"
    private let resetCreditsPath = "/backend-api/wham/rate-limit-reset-credits"
    private let refreshPath = "/oauth/token"

    func testPlusWhamRefreshPersistsFiveHourAndWeeklyWindows() async throws {
        let fixture = try AccountStoreFixture()
        defer { fixture.remove() }
        let key = try fixture.store.commitOAuthAccount(account(planType: "plus"))
        let client = ControlledHTTPDataClient()
        configureOptionalWhamResponses(client)
        client.respond(path: usagePath, status: 200, data: plusUsageData(fiveHour: 63, weekly: 27))
        let service = WhamService(httpClient: client)

        await service.refreshOne(key: key, store: fixture.store)

        let current = try XCTUnwrap(fixture.store.account(for: key))
        XCTAssertEqual(current.planType, "plus")
        XCTAssertTrue(current.hasFiveHourQuota)
        XCTAssertEqual(current.fiveHourUsedPercent, 63)
        XCTAssertNotNil(current.fiveHourResetAt)
        XCTAssertEqual(current.weeklyUsedPercent, 27)
        XCTAssertNotNil(current.weeklyResetAt)
    }

    func testProWhamRefreshClearsPreviouslyPersistedFiveHourWindow() async throws {
        let fixture = try AccountStoreFixture()
        defer { fixture.remove() }
        var initial = account(planType: "plus")
        initial.fiveHourUsedPercent = 88
        initial.fiveHourResetAt = Date().addingTimeInterval(3_600)
        let key = try fixture.store.upsertImportedAccount(initial)
        let client = ControlledHTTPDataClient()
        configureOptionalWhamResponses(client)
        client.respond(path: usagePath, status: 200, data: usageData(percent: 31))
        let service = WhamService(httpClient: client)

        await service.refreshOne(key: key, store: fixture.store)

        let current = try XCTUnwrap(fixture.store.account(for: key))
        XCTAssertEqual(current.planType, "pro")
        XCTAssertNil(current.fiveHourUsedPercent)
        XCTAssertNil(current.fiveHourResetAt)
        XCTAssertFalse(current.hasFiveHourQuota)
        XCTAssertEqual(current.weeklyUsedPercent, 31)
    }

    func testLateWhamUnauthorizedCannotExpireReauthorizedCredentials() async throws {
        let fixture = try AccountStoreFixture()
        defer { fixture.remove() }
        let key = try fixture.store.commitOAuthAccount(account(access: "access-old", refresh: "refresh-old"))
        let client = ControlledHTTPDataClient()
        configureOptionalWhamResponses(client)
        client.suspend(path: usagePath)
        let service = WhamService(
            httpClient: client,
            unauthorizedRetryDelayNanoseconds: 0
        )

        let request = Task { await service.refreshOne(key: key, store: fixture.store) }
        await client.waitUntilRequested(path: usagePath)
        _ = try fixture.store.commitOAuthAccount(
            account(access: "access-new", refresh: "refresh-new"),
            replacing: key
        )
        client.respond(path: usagePath, status: 200, data: usageData(percent: 48))
        client.resolveNext(path: usagePath, status: 401, data: Data("{}".utf8))
        await request.value

        let current = try XCTUnwrap(fixture.store.account(for: key))
        XCTAssertEqual(current.accessToken, "access-new")
        XCTAssertEqual(current.refreshToken, "refresh-new")
        XCTAssertFalse(current.tokenExpired)
        XCTAssertEqual(current.weeklyUsedPercent, 48)
        XCTAssertEqual(client.requestCount(path: usagePath), 2)
    }

    func testSingleWhamUnauthorizedIsRetriedBeforePersistingExpiredState() async throws {
        let fixture = try AccountStoreFixture()
        defer { fixture.remove() }
        let key = try fixture.store.commitOAuthAccount(account())
        let client = ControlledHTTPDataClient()
        configureOptionalWhamResponses(client)
        client.suspend(path: usagePath)
        let service = WhamService(
            httpClient: client,
            unauthorizedRetryDelayNanoseconds: 0
        )

        let request = Task { await service.refreshOne(key: key, store: fixture.store) }
        await client.waitUntilRequested(path: usagePath)
        client.respond(path: usagePath, status: 200, data: usageData(percent: 36))
        client.resolveNext(path: usagePath, status: 401, data: Data("{}".utf8))
        await request.value

        let current = try XCTUnwrap(fixture.store.account(for: key))
        XCTAssertEqual(client.requestCount(path: usagePath), 2)
        XCTAssertFalse(current.tokenExpired)
        XCTAssertEqual(current.weeklyUsedPercent, 36)
    }

    func testWhamUnauthorizedReconcilesExternalActiveAuthRotation() async throws {
        let fixture = try AccountStoreFixture()
        defer { fixture.remove() }
        let key = try fixture.store.commitOAuthAccount(account())
        try fixture.store.activate(key)
        let client = ControlledHTTPDataClient()
        configureOptionalWhamResponses(client)
        client.suspend(path: usagePath)
        let service = WhamService(httpClient: client)

        let request = Task { await service.refreshOne(key: key, store: fixture.store) }
        await client.waitUntilRequested(path: usagePath)
        try fixture.writeAuthTokens(access: "access-external", refresh: "refresh-external", id: "id-external")
        client.respond(path: usagePath, status: 200, data: usageData(percent: 52))
        client.resolveNext(path: usagePath, status: 401, data: Data("{}".utf8))
        await request.value

        let current = try XCTUnwrap(fixture.store.account(for: key))
        XCTAssertEqual(current.accessToken, "access-external")
        XCTAssertEqual(current.refreshToken, "refresh-external")
        XCTAssertFalse(current.tokenExpired)
        XCTAssertEqual(current.weeklyUsedPercent, 52)
        XCTAssertEqual(client.requestCount(path: usagePath), 2)
    }

    func testLateWhamSuccessCannotOverwriteNewCredentialGeneration() async throws {
        let fixture = try AccountStoreFixture()
        defer { fixture.remove() }
        var initial = account(access: "access-old", refresh: "refresh-old")
        initial.weeklyUsedPercent = 12
        let key = try fixture.store.upsertImportedAccount(initial)
        let client = ControlledHTTPDataClient()
        configureOptionalWhamResponses(client)
        client.suspend(path: usagePath)
        let service = WhamService(httpClient: client)

        let request = Task { await service.refreshOne(key: key, store: fixture.store) }
        await client.waitUntilRequested(path: usagePath)
        _ = try fixture.store.commitOAuthAccount(
            account(access: "access-new", refresh: "refresh-new"),
            replacing: key
        )
        client.resolveNext(path: usagePath, status: 200, data: usageData(percent: 88))
        await request.value

        let current = try XCTUnwrap(fixture.store.account(for: key))
        XCTAssertEqual(current.accessToken, "access-new")
        XCTAssertEqual(current.weeklyUsedPercent, 12)
        XCTAssertNil(current.lastChecked)
    }

    func testWhamRequestsForSameCredentialGenerationAreSingleFlight() async throws {
        let fixture = try AccountStoreFixture()
        defer { fixture.remove() }
        let key = try fixture.store.commitOAuthAccount(account())
        let client = ControlledHTTPDataClient()
        configureOptionalWhamResponses(client)
        client.suspend(path: usagePath)
        let service = WhamService(httpClient: client)

        let first = Task { await service.refreshOne(key: key, store: fixture.store) }
        let second = Task { await service.refreshOne(key: key, store: fixture.store) }
        await client.waitUntilRequested(path: usagePath)
        await Task.yield()

        XCTAssertEqual(client.requestCount(path: usagePath), 1)
        client.resolveNext(path: usagePath, status: 200, data: usageData(percent: 27))
        await first.value
        await second.value
        XCTAssertEqual(fixture.store.account(for: key)?.weeklyUsedPercent, 27)
    }

    func testConcurrentRollingRefreshesShareOneRequest() async throws {
        let fixture = try AccountStoreFixture()
        defer { fixture.remove() }
        let key = try fixture.store.commitOAuthAccount(account())
        let client = ControlledHTTPDataClient()
        client.suspend(path: refreshPath)
        let service = RefreshService(httpClient: client)

        let first = Task { await service.refreshAndPersist(key: key, store: fixture.store) }
        let second = Task { await service.refreshAndPersist(key: key, store: fixture.store) }
        await client.waitUntilRequested(path: refreshPath)
        await Task.yield()

        XCTAssertEqual(client.requestCount(path: refreshPath), 1)
        client.resolveNext(path: refreshPath, status: 200, data: refreshedTokenData())
        let firstResult = await first.value
        let secondResult = await second.value
        XCTAssertEqual(firstResult, .refreshed)
        XCTAssertEqual(secondResult, .refreshed)
        let current = try XCTUnwrap(fixture.store.account(for: key))
        XCTAssertEqual(current.accessToken, "access-rotated")
        XCTAssertEqual(current.refreshToken, "refresh-rotated")
    }

    func testActiveAccountIsNeverEligibleForSilentCredentialRecovery() {
        var active = account()
        active.isActive = true

        let service = RefreshService(httpClient: ControlledHTTPDataClient())

        XCTAssertFalse(service.canRefreshWithoutUserInteraction(active))
        active.isActive = false
        XCTAssertTrue(service.canRefreshWithoutUserInteraction(active))
    }

    func testPermanentRefreshCredentialFailuresRequireReauthorization() async throws {
        let responses: [(status: Int, data: Data)] = [
            (
                400,
                try JSONSerialization.data(withJSONObject: [
                    "error": "invalid_grant",
                    "error_description": "refresh credential is no longer valid",
                ])
            ),
            (401, Data("{}".utf8)),
        ]

        for response in responses {
            let fixture = try AccountStoreFixture()
            defer { fixture.remove() }
            let key = try fixture.store.commitOAuthAccount(account())
            let client = ControlledHTTPDataClient()
            client.respond(path: refreshPath, status: response.status, data: response.data)
            let service = RefreshService(httpClient: client)

            let result = await service.refreshAndPersist(key: key, store: fixture.store)

            XCTAssertEqual(result, .needsReauthorization, "HTTP \(response.status)")
            XCTAssertTrue(try XCTUnwrap(fixture.store.account(for: key)).tokenExpired)
        }
    }

    func testTransientRefreshFailureDoesNotMarkCredentialExpired() async throws {
        let fixture = try AccountStoreFixture()
        defer { fixture.remove() }
        let key = try fixture.store.commitOAuthAccount(account())
        let client = ControlledHTTPDataClient()
        client.respond(
            path: refreshPath,
            status: 503,
            data: try JSONSerialization.data(withJSONObject: [
                "error": "temporarily_unavailable",
                "error_description": "try again later",
            ])
        )
        let service = RefreshService(httpClient: client)

        let result = await service.refreshAndPersist(key: key, store: fixture.store)

        XCTAssertEqual(result, .transientFailure)
        let current = try XCTUnwrap(fixture.store.account(for: key))
        XCTAssertFalse(current.tokenExpired)
        XCTAssertEqual(current.refreshToken, "refresh-old")
    }

    func testLateRefreshTokenReusedCannotInvalidateNewOAuthCredentials() async throws {
        let fixture = try AccountStoreFixture()
        defer { fixture.remove() }
        let key = try fixture.store.commitOAuthAccount(account(access: "access-old", refresh: "refresh-old"))
        let client = ControlledHTTPDataClient()
        client.suspend(path: refreshPath)
        let service = RefreshService(httpClient: client)

        let request = Task { await service.refreshAndPersist(key: key, store: fixture.store) }
        await client.waitUntilRequested(path: refreshPath)
        _ = try fixture.store.commitOAuthAccount(
            account(access: "access-new", refresh: "refresh-new"),
            replacing: key
        )
        client.resolveNext(path: refreshPath, status: 400, data: refreshTokenReusedData())

        let result = await request.value
        XCTAssertEqual(result, .superseded)
        let current = try XCTUnwrap(fixture.store.account(for: key))
        XCTAssertEqual(current.accessToken, "access-new")
        XCTAssertEqual(current.refreshToken, "refresh-new")
        XCTAssertFalse(current.tokenExpired)
    }

    func testLateRefreshSuccessCannotOverwriteNewOAuthCredentials() async throws {
        let fixture = try AccountStoreFixture()
        defer { fixture.remove() }
        let key = try fixture.store.commitOAuthAccount(account(access: "access-old", refresh: "refresh-old"))
        let client = ControlledHTTPDataClient()
        client.suspend(path: refreshPath)
        let service = RefreshService(httpClient: client)

        let request = Task { await service.refreshAndPersist(key: key, store: fixture.store) }
        await client.waitUntilRequested(path: refreshPath)
        _ = try fixture.store.commitOAuthAccount(
            account(access: "access-oauth", refresh: "refresh-oauth", id: "id-oauth"),
            replacing: key
        )
        client.resolveNext(path: refreshPath, status: 200, data: refreshedTokenData())

        let result = await request.value
        XCTAssertEqual(result, .superseded)
        let current = try XCTUnwrap(fixture.store.account(for: key))
        XCTAssertEqual(current.accessToken, "access-oauth")
        XCTAssertEqual(current.refreshToken, "refresh-oauth")
        XCTAssertEqual(current.idToken, "id-oauth")
    }

    func testActiveOAuthWritesLatestCredentialsToAuthFile() throws {
        let fixture = try AccountStoreFixture()
        defer { fixture.remove() }
        let key = try fixture.store.commitOAuthAccount(account(access: "access-old", refresh: "refresh-old"))
        try fixture.store.activate(key)

        _ = try fixture.store.commitOAuthAccount(
            account(access: "access-new", refresh: "refresh-new", id: "id-new"),
            replacing: key
        )

        let auth = try fixture.readAuthTokens()
        XCTAssertEqual(auth["access_token"] as? String, "access-new")
        XCTAssertEqual(auth["refresh_token"] as? String, "refresh-new")
        XCTAssertEqual(auth["id_token"] as? String, "id-new")
        XCTAssertFalse(fixture.store.syncActiveCredentialsFromAuthFile())
        XCTAssertEqual(fixture.store.account(for: key)?.accessToken, "access-new")
    }

    func testReauthorizationMigratesSelectedRowWhenStableAccountKeyChanges() throws {
        let fixture = try AccountStoreFixture()
        defer { fixture.remove() }
        let oldKey = try fixture.store.commitOAuthAccount(account())
        var updated = account(access: "access-new", refresh: "refresh-new", id: "id-new")
        updated.accountId = "account-key-v2"

        let newKey = try fixture.store.commitOAuthAccount(updated, replacing: oldKey)

        XCTAssertNil(fixture.store.account(for: oldKey))
        XCTAssertEqual(fixture.store.accounts.count, 1)
        XCTAssertEqual(fixture.store.account(for: newKey)?.accessToken, "access-new")
        XCTAssertFalse(try XCTUnwrap(fixture.store.account(for: newKey)).tokenExpired)
    }

    func testReauthorizationCanReuseExistingWorkspaceClaimWhenOAuthOmitsIt() throws {
        let fixture = try AccountStoreFixture()
        defer { fixture.remove() }
        let key = try fixture.store.commitOAuthAccount(account())
        var updated = account(access: "access-new", refresh: "refresh-new", id: "id-new")
        updated.chatgptAccountId = ""

        let committedKey = try fixture.store.commitOAuthAccount(updated, replacing: key)

        let current = try XCTUnwrap(fixture.store.account(for: committedKey))
        XCTAssertEqual(current.chatgptAccountId, "workspace-key")
        XCTAssertEqual(current.accessToken, "access-new")
    }

    func testReauthorizationCannotRestoreAnAccountDeletedDuringOAuth() throws {
        let fixture = try AccountStoreFixture()
        defer { fixture.remove() }
        let key = try fixture.store.commitOAuthAccount(account())
        fixture.store.remove(key)

        XCTAssertThrowsError(try fixture.store.commitOAuthAccount(
            account(access: "access-new", refresh: "refresh-new", id: "id-new"),
            replacing: key
        )) { error in
            guard case TokenStoreError.missingAccount = error else {
                return XCTFail("Expected missingAccount, got \(error)")
            }
        }
        XCTAssertTrue(fixture.store.accounts.isEmpty)
    }

    func testAuthSyncSelectsCorrectMemberWhenTeamWorkspaceIsShared() throws {
        let fixture = try AccountStoreFixture()
        defer { fixture.remove() }
        var first = account(access: "access-a", refresh: "refresh-a", id: "id-a")
        first.email = "a@example.com"
        first.accountId = "member-a"
        first.chatgptAccountId = "shared-workspace"
        var second = account(access: "access-b", refresh: "refresh-b", id: "id-b")
        second.email = "b@example.com"
        second.accountId = "member-b"
        second.chatgptAccountId = "shared-workspace"
        let firstKey = try fixture.store.commitOAuthAccount(first)
        let secondKey = try fixture.store.commitOAuthAccount(second)
        try fixture.store.activate(firstKey)
        let externalAccess = jwt([
            "iat": Date().timeIntervalSince1970,
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "shared-workspace",
                "chatgpt_account_user_id": "member-b",
            ],
        ])
        let externalID = jwt(["email": "b@example.com"])
        try fixture.writeAuthTokens(
            access: externalAccess,
            refresh: "refresh-b-new",
            id: externalID,
            accountId: "shared-workspace"
        )

        XCTAssertTrue(fixture.store.syncActiveCredentialsFromAuthFile())

        let currentFirst = try XCTUnwrap(fixture.store.account(for: firstKey))
        let currentSecond = try XCTUnwrap(fixture.store.account(for: secondKey))
        XCTAssertFalse(currentFirst.isActive)
        XCTAssertEqual(currentFirst.accessToken, "access-a")
        XCTAssertTrue(currentSecond.isActive)
        XCTAssertEqual(currentSecond.accessToken, externalAccess)
        XCTAssertEqual(currentSecond.refreshToken, "refresh-b-new")
    }

    func testOlderAuthGenerationCannotRollBackActiveCredentials() throws {
        let fixture = try AccountStoreFixture()
        defer { fixture.remove() }
        let issuedAt = Date()
        let currentAccess = jwt([
            "iat": issuedAt.timeIntervalSince1970,
            "exp": issuedAt.addingTimeInterval(3_600).timeIntervalSince1970,
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "workspace-key",
                "chatgpt_account_user_id": "account-key",
            ],
        ])
        let currentID = jwt(["email": "person@example.com"])
        let key = try fixture.store.commitOAuthAccount(
            account(access: currentAccess, refresh: "refresh-current", id: currentID)
        )
        try fixture.store.activate(key)
        let olderAccess = jwt([
            "iat": issuedAt.addingTimeInterval(-3_600).timeIntervalSince1970,
            "exp": issuedAt.addingTimeInterval(1_800).timeIntervalSince1970,
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "workspace-key",
                "chatgpt_account_user_id": "account-key",
            ],
        ])
        try fixture.writeAuthTokens(
            access: olderAccess,
            refresh: "refresh-older",
            id: currentID
        )

        XCTAssertFalse(fixture.store.syncActiveCredentialsFromAuthFile())

        let current = try XCTUnwrap(fixture.store.account(for: key))
        XCTAssertEqual(current.accessToken, currentAccess)
        XCTAssertEqual(current.refreshToken, "refresh-current")
        XCTAssertEqual(try fixture.readAuthTokens()["access_token"] as? String, currentAccess)
    }

    func testInactiveRefreshCannotCommitAfterAccountBecomesActive() async throws {
        let fixture = try AccountStoreFixture()
        defer { fixture.remove() }
        let key = try fixture.store.commitOAuthAccount(account())
        let client = ControlledHTTPDataClient()
        client.suspend(path: refreshPath)
        let service = RefreshService(httpClient: client)

        let request = Task { await service.refreshAndPersist(key: key, store: fixture.store) }
        await client.waitUntilRequested(path: refreshPath)
        try fixture.store.activate(key)
        client.resolveNext(path: refreshPath, status: 200, data: refreshedTokenData())

        let result = await request.value
        XCTAssertEqual(result, .superseded)
        let auth = try fixture.readAuthTokens()
        XCTAssertEqual(auth["access_token"] as? String, "access-old")
        XCTAssertEqual(auth["refresh_token"] as? String, "refresh-old")
        XCTAssertEqual(fixture.store.account(for: key)?.accessToken, "access-old")
    }

    func testRemovedAccountIsNotRestoredByLateWhamCompletion() async throws {
        let fixture = try AccountStoreFixture()
        defer { fixture.remove() }
        let key = try fixture.store.commitOAuthAccount(account())
        let client = ControlledHTTPDataClient()
        configureOptionalWhamResponses(client)
        client.suspend(path: usagePath)
        let service = WhamService(httpClient: client)

        let request = Task { await service.refreshOne(key: key, store: fixture.store) }
        await client.waitUntilRequested(path: usagePath)
        fixture.store.remove(key)
        client.resolveNext(path: usagePath, status: 200, data: usageData(percent: 73))
        await request.value

        XCTAssertNil(fixture.store.account(for: key))
    }

    func testWhamAccessStatusMappingKeeps401402And403Distinct() async throws {
        for (status, expectsExpired, expectsSuspended) in [
            (401, true, false),
            (402, false, false),
            (403, false, true),
        ] {
            let fixture = try AccountStoreFixture()
            defer { fixture.remove() }
            var testedAccount = account()
            if status == 401 {
                testedAccount.accessToken = jwt([
                    "iat": Date().addingTimeInterval(-600).timeIntervalSince1970,
                    "exp": Date().addingTimeInterval(-60).timeIntervalSince1970,
                ])
            }
            let key = try fixture.store.commitOAuthAccount(testedAccount)
            let client = ControlledHTTPDataClient()
            configureOptionalWhamResponses(client)
            client.respond(path: usagePath, status: status, data: Data("{}".utf8))
            let service = WhamService(
                httpClient: client,
                unauthorizedRetryDelayNanoseconds: 0
            )

            await service.refreshOne(key: key, store: fixture.store)

            let current = try XCTUnwrap(fixture.store.account(for: key))
            XCTAssertEqual(current.tokenExpired, expectsExpired, "HTTP \(status)")
            XCTAssertEqual(current.isSuspended, expectsSuspended, "HTTP \(status)")
        }
    }

    func testRepeatedWhamUnauthorizedExpiresOnlyAfterSameGenerationPersists() async throws {
        var clock = Date()
        let access = jwt([
            "iat": clock.addingTimeInterval(-300).timeIntervalSince1970,
            "exp": clock.addingTimeInterval(3_600).timeIntervalSince1970,
        ])
        let fixture = try AccountStoreFixture()
        defer { fixture.remove() }
        let key = try fixture.store.commitOAuthAccount(account(access: access))
        let client = ControlledHTTPDataClient()
        configureOptionalWhamResponses(client)
        client.respond(path: usagePath, status: 401, data: Data("{}".utf8))
        let service = WhamService(
            httpClient: client,
            now: { clock },
            unauthorizedRetryDelayNanoseconds: 0
        )

        await service.refreshOne(key: key, store: fixture.store)
        XCTAssertFalse(try XCTUnwrap(fixture.store.account(for: key)).tokenExpired)

        clock = clock.addingTimeInterval(16)
        await service.refreshOne(key: key, store: fixture.store)
        XCTAssertTrue(try XCTUnwrap(fixture.store.account(for: key)).tokenExpired)
        XCTAssertEqual(client.requestCount(path: usagePath), 4)
    }

    func testFreshOAuthGenerationStaysAvailableDuringGrace() async throws {
        var clock = Date()
        let access = jwt([
            "iat": clock.timeIntervalSince1970,
            "exp": clock.addingTimeInterval(3_600).timeIntervalSince1970,
        ])
        let fixture = try AccountStoreFixture()
        defer { fixture.remove() }
        let key = try fixture.store.commitOAuthAccount(account(access: access))
        try fixture.store.activate(key)
        let client = ControlledHTTPDataClient()
        configureOptionalWhamResponses(client)
        client.respond(path: usagePath, status: 401, data: Data("{}".utf8))
        let service = WhamService(
            httpClient: client,
            now: { clock },
            unauthorizedRetryDelayNanoseconds: 0
        )

        await service.refreshOne(key: key, store: fixture.store)
        XCTAssertFalse(try XCTUnwrap(fixture.store.account(for: key)).tokenExpired)

        clock = clock.addingTimeInterval(30)
        await service.refreshOne(key: key, store: fixture.store)
        XCTAssertFalse(try XCTUnwrap(fixture.store.account(for: key)).tokenExpired)

        clock = clock.addingTimeInterval(91)
        await service.refreshOne(key: key, store: fixture.store)
        XCTAssertTrue(try XCTUnwrap(fixture.store.account(for: key)).tokenExpired)
    }

    func testLegacySingle401FlagIsClearedUntilUnauthorizedIsConfirmed() async throws {
        var clock = Date()
        let access = jwt([
            "iat": clock.addingTimeInterval(-300).timeIntervalSince1970,
            "exp": clock.addingTimeInterval(3_600).timeIntervalSince1970,
        ])
        let fixture = try AccountStoreFixture()
        defer { fixture.remove() }
        var legacy = account(access: access)
        legacy.tokenExpired = true
        let key = try fixture.store.upsertImportedAccount(legacy)
        try fixture.store.activate(key)
        XCTAssertFalse(try XCTUnwrap(
            fixture.store.account(for: key)
        ).authorizationInvalidConfirmed)
        let client = ControlledHTTPDataClient()
        configureOptionalWhamResponses(client)
        client.respond(path: usagePath, status: 401, data: Data("{}".utf8))
        let service = WhamService(
            httpClient: client,
            now: { clock },
            unauthorizedRetryDelayNanoseconds: 0
        )

        await service.refreshOne(key: key, store: fixture.store)
        XCTAssertFalse(try XCTUnwrap(fixture.store.account(for: key)).tokenExpired)

        clock = clock.addingTimeInterval(16)
        await service.refreshOne(key: key, store: fixture.store)
        let current = try XCTUnwrap(fixture.store.account(for: key))
        XCTAssertTrue(current.tokenExpired)
        XCTAssertTrue(current.authorizationInvalidConfirmed)
    }

    func testInactiveWhamUnauthorizedRefreshesCredentialsAndRetriesUsage() async throws {
        let fixture = try AccountStoreFixture()
        defer { fixture.remove() }
        let key = try fixture.store.commitOAuthAccount(account())
        let client = ControlledHTTPDataClient()
        configureOptionalWhamResponses(client)
        client.enqueue(path: usagePath, status: 401, data: Data("{}".utf8))
        client.enqueue(path: usagePath, status: 401, data: Data("{}".utf8))
        client.enqueue(path: usagePath, status: 200, data: usageData(percent: 41))
        client.respond(path: refreshPath, status: 200, data: refreshedTokenData())
        let refreshService = RefreshService(httpClient: client)
        let whamService = WhamService(
            httpClient: client,
            credentialRefreshService: refreshService,
            unauthorizedRetryDelayNanoseconds: 0
        )

        await whamService.refreshOne(key: key, store: fixture.store)

        let current = try XCTUnwrap(fixture.store.account(for: key))
        XCTAssertEqual(current.accessToken, "access-rotated")
        XCTAssertEqual(current.refreshToken, "refresh-rotated")
        XCTAssertEqual(current.weeklyUsedPercent, 41)
        XCTAssertFalse(current.tokenExpired)
        XCTAssertEqual(client.requestCount(path: usagePath), 3)
        XCTAssertEqual(client.requestCount(path: refreshPath), 1)
    }

    func testOptionalResetCreditsFailureDoesNotOverrideSuccessfulUsage() async throws {
        let fixture = try AccountStoreFixture()
        defer { fixture.remove() }
        let key = try fixture.store.commitOAuthAccount(account())
        let client = ControlledHTTPDataClient()
        client.respond(path: usagePath, status: 200, data: usageData(percent: 44))
        client.respond(path: orgPath, status: 403, data: Data("{}".utf8))
        client.respond(path: resetCreditsPath, status: 403, data: Data("{}".utf8))
        let service = WhamService(httpClient: client)

        await service.refreshOne(key: key, store: fixture.store)

        let current = try XCTUnwrap(fixture.store.account(for: key))
        XCTAssertEqual(current.weeklyUsedPercent, 44)
        XCTAssertFalse(current.tokenExpired)
        XCTAssertFalse(current.isSuspended)
    }

    func testImportWithMissingRefreshAndIdPreservesExistingCredentialsAndTelemetry() throws {
        let fixture = try AccountStoreFixture()
        defer { fixture.remove() }
        var existing = account()
        existing.weeklyUsedPercent = 61
        existing.organizationName = "Existing Org"
        let key = try fixture.store.upsertImportedAccount(existing)
        var imported = account(access: "access-imported", refresh: "", id: "")
        imported.weeklyUsedPercent = 0
        imported.organizationName = nil

        _ = try fixture.store.upsertImportedAccount(imported)

        let current = try XCTUnwrap(fixture.store.account(for: key))
        XCTAssertEqual(current.accessToken, "access-imported")
        XCTAssertEqual(current.refreshToken, "refresh-old")
        XCTAssertEqual(current.idToken, "id-old")
        XCTAssertEqual(current.weeklyUsedPercent, 61)
        XCTAssertEqual(current.organizationName, "Existing Org")
    }

    func testActivateWithStaleAccountValueWritesLatestStoredCredentials() throws {
        let fixture = try AccountStoreFixture()
        defer { fixture.remove() }
        let stale = account(access: "access-old", refresh: "refresh-old", id: "id-old")
        let key = try fixture.store.commitOAuthAccount(stale)
        _ = try fixture.store.commitOAuthAccount(
            account(access: "access-new", refresh: "refresh-new", id: "id-new"),
            replacing: key
        )

        try fixture.store.activate(stale)

        let auth = try fixture.readAuthTokens()
        XCTAssertEqual(auth["access_token"] as? String, "access-new")
        XCTAssertEqual(auth["refresh_token"] as? String, "refresh-new")
        XCTAssertEqual(auth["id_token"] as? String, "id-new")
    }

    func testIdTokenOnlyAuthSyncInvalidatesOldCredentialRevision() throws {
        let fixture = try AccountStoreFixture()
        defer { fixture.remove() }
        let key = try fixture.store.commitOAuthAccount(account(id: "id-old"))
        try fixture.store.activate(key)
        let before = try XCTUnwrap(fixture.store.snapshot(for: key)).revision
        try fixture.writeAuthTokens(access: "access-old", refresh: "refresh-old", id: "id-new")

        XCTAssertTrue(fixture.store.syncActiveCredentialsFromAuthFile())

        let after = try XCTUnwrap(fixture.store.snapshot(for: key)).revision
        XCTAssertNotEqual(before, after)
        XCTAssertEqual(fixture.store.account(for: key)?.idToken, "id-new")
    }

    func testStoreLoadReconcilesNewerActiveAuthBeforePublishingAccounts() throws {
        let fixture = try AccountStoreFixture()
        defer { fixture.remove() }
        let key = try fixture.store.commitOAuthAccount(account())
        try fixture.store.activate(key)
        let revision = try XCTUnwrap(fixture.store.snapshot(for: key)).revision
        XCTAssertEqual(fixture.store.markTokenExpired(key, ifCurrent: revision), .applied)
        try fixture.writeAuthTokens(access: "access-external", refresh: "refresh-external", id: "id-external")

        let reloaded = TokenStore(poolURL: fixture.poolURL, authURL: fixture.authURL)
        let current = try XCTUnwrap(reloaded.account(for: key))

        XCTAssertEqual(current.accessToken, "access-external")
        XCTAssertFalse(current.tokenExpired)
        XCTAssertTrue(current.isActive)
    }

    func testAuthDirectoryMonitorReconcilesAtomicCredentialReplacement() async throws {
        let fixture = try AccountStoreFixture()
        let key = try fixture.store.commitOAuthAccount(account())
        try fixture.store.activate(key)
        fixture.store.startMonitoringActiveAuthFile()
        defer {
            fixture.store.stopMonitoringActiveAuthFile()
            fixture.remove()
        }

        try fixture.writeAuthTokens(access: "access-external", refresh: "refresh-external", id: "id-external")
        for _ in 0..<30 where fixture.store.account(for: key)?.accessToken != "access-external" {
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        let current = try XCTUnwrap(fixture.store.account(for: key))
        XCTAssertEqual(current.accessToken, "access-external")
        XCTAssertFalse(current.tokenExpired)
    }

    func testAuthDirectoryMonitorDoesNotClearConfirmedInvalidStateForSameGeneration() async throws {
        let fixture = try AccountStoreFixture()
        let key = try fixture.store.commitOAuthAccount(account())
        try fixture.store.activate(key)
        fixture.store.startMonitoringActiveAuthFile()
        defer {
            fixture.store.stopMonitoringActiveAuthFile()
            fixture.remove()
        }
        let revision = try XCTUnwrap(fixture.store.snapshot(for: key)).revision

        XCTAssertEqual(fixture.store.markTokenExpired(key, ifCurrent: revision), .applied)
        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertTrue(try XCTUnwrap(fixture.store.account(for: key)).tokenExpired)
        XCTAssertFalse(fixture.store.syncActiveCredentialsFromAuthFile())
        XCTAssertTrue(try XCTUnwrap(fixture.store.account(for: key)).tokenExpired)
    }

    func testAccessTokenExpiryIsIndependentFromSubscriptionExpiry() throws {
        let accessExpiration = Date().addingTimeInterval(3_600)
        let subscriptionExpiration = Date().addingTimeInterval(30 * 24 * 3_600)
        let access = jwt([
            "exp": accessExpiration.timeIntervalSince1970,
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "workspace-key",
                "chatgpt_account_user_id": "account-key",
                "chatgpt_plan_type": "pro",
            ],
        ])
        let id = jwt([
            "email": "person@example.com",
            "https://api.openai.com/auth": [
                "chatgpt_subscription_active_until": ISO8601DateFormatter().string(from: subscriptionExpiration),
            ],
        ])

        let built = AccountBuilder.build(from: OAuthTokens(
            accessToken: access,
            refreshToken: "refresh-old",
            idToken: id
        ))
        let service = RefreshService(httpClient: ControlledHTTPDataClient())

        XCTAssertEqual(try XCTUnwrap(built.accessTokenExpiresAt).timeIntervalSince1970,
                       accessExpiration.timeIntervalSince1970,
                       accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(built.expiresAt).timeIntervalSince1970,
                       subscriptionExpiration.timeIntervalSince1970,
                       accuracy: 1)
        XCTAssertTrue(service.needsRefresh(built))
    }

    func testRefreshResponseWithoutIdTokenPreservesCurrentIdToken() async throws {
        let fixture = try AccountStoreFixture()
        defer { fixture.remove() }
        let key = try fixture.store.commitOAuthAccount(account(id: "id-existing"))
        let client = ControlledHTTPDataClient()
        client.respond(
            path: refreshPath,
            status: 200,
            data: try JSONSerialization.data(withJSONObject: [
                "access_token": "access-rotated",
                "refresh_token": "refresh-rotated",
            ])
        )
        let service = RefreshService(httpClient: client)

        let result = await service.refreshAndPersist(key: key, store: fixture.store)
        XCTAssertEqual(result, .refreshed)
        let current = try XCTUnwrap(fixture.store.account(for: key))
        XCTAssertEqual(current.idToken, "id-existing")
        XCTAssertEqual(current.accessToken, "access-rotated")
    }

    private func configureOptionalWhamResponses(_ client: ControlledHTTPDataClient) {
        client.respond(path: orgPath, status: 200, data: Data("{}".utf8))
        client.respond(path: resetCreditsPath, status: 200, data: Data("[]".utf8))
    }

    private func account(
        access: String = "access-old",
        refresh: String = "refresh-old",
        id: String = "id-old",
        planType: String = "pro"
    ) -> TokenAccount {
        TokenAccount(
            email: "person@example.com",
            accountId: "account-key",
            chatgptAccountId: "workspace-key",
            accessToken: access,
            refreshToken: refresh,
            idToken: id,
            expiresAt: Date().addingTimeInterval(60),
            planType: planType
        )
    }

    private func usageData(percent: Double) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "plan_type": "pro",
            "rate_limit": [
                "primary_window": [
                    "used_percent": percent,
                    "limit_window_seconds": 604_800,
                    "reset_at": Date().addingTimeInterval(3_600).timeIntervalSince1970,
                ]
            ]
        ])
    }

    private func plusUsageData(fiveHour: Double, weekly: Double) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "plan_type": "plus",
            "rate_limit": [
                "primary_window": [
                    "used_percent": fiveHour,
                    "limit_window_seconds": 18_000,
                    "reset_at": Date().addingTimeInterval(3_600).timeIntervalSince1970,
                ],
                "secondary_window": [
                    "used_percent": weekly,
                    "limit_window_seconds": 604_800,
                    "reset_at": Date().addingTimeInterval(6 * 24 * 3_600).timeIntervalSince1970,
                ],
            ],
        ])
    }

    private func refreshedTokenData() -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "access_token": "access-rotated",
            "refresh_token": "refresh-rotated",
            "id_token": "id-rotated",
        ])
    }

    private func refreshTokenReusedData() -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "error": [
                "code": "refresh_token_reused",
                "message": "credential was already rotated",
            ]
        ])
    }

    private func jwt(_ payload: [String: Any]) -> String {
        let header = try! JSONSerialization.data(withJSONObject: ["alg": "none"])
        let body = try! JSONSerialization.data(withJSONObject: payload)
        return "\(base64URL(header)).\(base64URL(body)).signature"
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

@MainActor
private final class ControlledHTTPDataClient: HTTPDataClient {
    private struct Stub {
        let status: Int
        let data: Data
    }

    private var immediate: [String: Stub] = [:]
    private var queued: [String: [Stub]] = [:]
    private var suspendedPaths: Set<String> = []
    private var pending: [String: [CheckedContinuation<(Data, URLResponse), Error>]] = [:]
    private var counts: [String: Int] = [:]
    private var requestWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func respond(path: String, status: Int, data: Data) {
        immediate[path] = Stub(status: status, data: data)
        suspendedPaths.remove(path)
    }

    func enqueue(path: String, status: Int, data: Data) {
        queued[path, default: []].append(Stub(status: status, data: data))
    }

    func suspend(path: String) {
        suspendedPaths.insert(path)
        immediate[path] = nil
    }

    func requestCount(path: String) -> Int {
        counts[path, default: 0]
    }

    func waitUntilRequested(path: String) async {
        if requestCount(path: path) > 0 { return }
        await withCheckedContinuation { continuation in
            requestWaiters[path, default: []].append(continuation)
        }
    }

    func resolveNext(path: String, status: Int, data: Data) {
        guard var continuations = pending[path], !continuations.isEmpty else {
            XCTFail("No pending request for \(path)")
            return
        }
        let continuation = continuations.removeFirst()
        pending[path] = continuations
        let url = URL(string: "https://example.test\(path)")!
        continuation.resume(returning: (data, response(url: url, status: status)))
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let path = request.url?.path ?? ""
        counts[path, default: 0] += 1
        let waiters = requestWaiters.removeValue(forKey: path) ?? []
        waiters.forEach { $0.resume() }

        if var stubs = queued[path], !stubs.isEmpty {
            let stub = stubs.removeFirst()
            queued[path] = stubs
            let url = request.url ?? URL(string: "https://example.test")!
            return (stub.data, response(url: url, status: stub.status))
        }
        if let stub = immediate[path] {
            let url = request.url ?? URL(string: "https://example.test")!
            return (stub.data, response(url: url, status: stub.status))
        }
        if suspendedPaths.contains(path) {
            return try await withCheckedThrowingContinuation { continuation in
                pending[path, default: []].append(continuation)
            }
        }

        let url = request.url ?? URL(string: "https://example.test")!
        return (Data("{}".utf8), response(url: url, status: 200))
    }

    private func response(url: URL, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
    }
}

@MainActor
private final class AccountStoreFixture {
    let rootURL: URL
    let poolURL: URL
    let authURL: URL
    let store: TokenStore

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexBarAccountRace-\(UUID().uuidString)", isDirectory: true)
        poolURL = rootURL.appendingPathComponent("token_pool.json")
        authURL = rootURL.appendingPathComponent("auth.json")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        store = TokenStore(poolURL: poolURL, authURL: authURL, autoLoad: false)
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }

    func readAuthTokens() throws -> [String: Any] {
        let data = try Data(contentsOf: authURL)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(root["tokens"] as? [String: Any])
    }

    func writeAuthTokens(
        access: String,
        refresh: String,
        id: String,
        accountId: String = "workspace-key"
    ) throws {
        let root: [String: Any] = [
            "auth_mode": "chatgpt",
            "tokens": [
                "access_token": access,
                "refresh_token": refresh,
                "id_token": id,
                "account_id": accountId,
            ]
        ]
        try JSONSerialization.data(withJSONObject: root).write(to: authURL, options: .atomic)
    }
}
