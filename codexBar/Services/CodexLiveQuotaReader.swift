import Foundation

struct CodexLiveQuotaSnapshot: Equatable, Sendable {
    let usedPercent: Double
    let resetAt: Date
    let observedAt: Date
    let planType: String?
}

enum CodexLiveQuotaParser {
    nonisolated private static var weeklyWindowMinutes: Int { 7 * 24 * 60 }

    nonisolated static func snapshot(from line: Data) -> CodexLiveQuotaSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              root["type"] as? String == "event_msg",
              let timestamp = root["timestamp"] as? String,
              let observedAt = iso8601Date(timestamp),
              let payload = root["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let rateLimits = payload["rate_limits"] as? [String: Any],
              rateLimits["limit_id"] as? String == "codex",
              let primary = rateLimits["primary"] as? [String: Any],
              intValue(primary["window_minutes"]) == weeklyWindowMinutes,
              let usedPercent = doubleValue(primary["used_percent"]),
              usedPercent.isFinite,
              let resetsAt = doubleValue(primary["resets_at"]) else {
            return nil
        }

        return CodexLiveQuotaSnapshot(
            usedPercent: min(max(usedPercent, 0), 100),
            resetAt: Date(timeIntervalSince1970: resetsAt),
            observedAt: observedAt,
            planType: rateLimits["plan_type"] as? String
        )
    }

    nonisolated private static func iso8601Date(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    nonisolated private static func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? String { return Double(value) }
        return nil
    }

    nonisolated private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Double { return Int(value) }
        if let value = value as? String { return Int(value) }
        return nil
    }
}

enum CodexLiveQuotaResolver {
    nonisolated private static var maximumSnapshotAge: TimeInterval { 24 * 60 * 60 }
    nonisolated private static var resetTimeTolerance: TimeInterval { 2 }

    nonisolated static func resolvedUsedPercent(
        whamUsedPercent: Double,
        whamResetAt: Date?,
        whamPlanType: String,
        liveSnapshot: CodexLiveQuotaSnapshot?,
        now: Date
    ) -> Double {
        guard let whamResetAt,
              let liveSnapshot,
              isFresh(liveSnapshot, now: now),
              resetMatches(liveSnapshot.resetAt, whamResetAt),
              planMatches(liveSnapshot.planType, whamPlanType) else {
            return whamUsedPercent
        }

        // 同一固定窗口内已用量只会上升。取较大值既修正 WHAM 的滞后，也避免旧会话覆盖更新值。
        return min(max(max(whamUsedPercent, liveSnapshot.usedPercent), 0), 100)
    }

    nonisolated static func isFresh(_ snapshot: CodexLiveQuotaSnapshot, now: Date) -> Bool {
        let age = now.timeIntervalSince(snapshot.observedAt)
        return age >= -5 * 60 && age <= maximumSnapshotAge && snapshot.resetAt > now
    }

    nonisolated static func resetMatches(_ lhs: Date, _ rhs: Date) -> Bool {
        abs(lhs.timeIntervalSince(rhs)) <= resetTimeTolerance
    }

    nonisolated static func planMatches(_ livePlanType: String?, _ whamPlanType: String) -> Bool {
        livePlanType == nil || livePlanType == whamPlanType
    }
}

actor CodexLiveQuotaStore {
    static let shared = CodexLiveQuotaStore()

    private static let maximumTailBytes: UInt64 = 1024 * 1024
    private static let maximumTrackedFiles = 20

    private struct FileCursor {
        var offset: UInt64
        var trailingData: Data
    }

    private struct WindowKey: Hashable {
        let resetAtSecond: Int64
        let planType: String?
    }

    private let sessionsURL: URL
    private let calendar: Calendar
    private var cursors: [URL: FileCursor] = [:]
    private var snapshots: [WindowKey: CodexLiveQuotaSnapshot] = [:]

    init(
        sessionsURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true),
        calendar: Calendar = .current
    ) {
        self.sessionsURL = sessionsURL
        self.calendar = calendar
    }

    func latestSnapshot(
        matchingResetAt resetAt: Date,
        planType: String,
        now: Date
    ) -> CodexLiveQuotaSnapshot? {
        ingestRecentSessions(now: now)
        evictExpiredSnapshots(now: now)

        return snapshots.values
            .filter {
                CodexLiveQuotaResolver.isFresh($0, now: now) &&
                    CodexLiveQuotaResolver.resetMatches($0.resetAt, resetAt) &&
                    CodexLiveQuotaResolver.planMatches($0.planType, planType)
            }
            .max(by: { $0.observedAt < $1.observedAt })
    }

    private func ingestRecentSessions(now: Date) {
        let files = sessionFiles(now: now)
        let activeFiles = Set(files)
        cursors = cursors.filter { activeFiles.contains($0.key) }
        for file in files {
            ingest(file)
        }
    }

    private func ingest(_ url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = (attributes[.size] as? NSNumber)?.uint64Value else { return }

        var cursor = cursors[url]
        var readOffset: UInt64
        var initialReadStartsMidLine = false

        if let current = cursor, fileSize >= current.offset {
            readOffset = current.offset
            if fileSize - readOffset > Self.maximumTailBytes {
                readOffset = fileSize - Self.maximumTailBytes
                cursor = nil
                initialReadStartsMidLine = true
            }
        } else {
            readOffset = fileSize > Self.maximumTailBytes ? fileSize - Self.maximumTailBytes : 0
            cursor = nil
            initialReadStartsMidLine = readOffset > 0
        }

        guard readOffset < fileSize,
              let handle = try? FileHandle(forReadingFrom: url) else {
            if fileSize == 0 { cursors[url] = FileCursor(offset: 0, trailingData: Data()) }
            return
        }
        defer { try? handle.close() }

        try? handle.seek(toOffset: readOffset)
        guard let appendedData = try? handle.readToEnd() else { return }

        var combined = cursor?.trailingData ?? Data()
        combined.append(appendedData)
        var lines = [UInt8](combined)
            .split(separator: 0x0A, omittingEmptySubsequences: false)
            .map { bytes in Data(bytes) }
        if initialReadStartsMidLine, !lines.isEmpty {
            lines.removeFirst()
        }

        let endsAtLineBoundary = combined.last == 0x0A
        let trailingData = endsAtLineBoundary ? Data() : (lines.popLast() ?? Data())
        if endsAtLineBoundary, lines.last?.isEmpty == true {
            lines.removeLast()
        }

        for line in lines {
            guard let snapshot = CodexLiveQuotaParser.snapshot(from: line) else { continue }
            store(snapshot)
        }
        cursors[url] = FileCursor(offset: fileSize, trailingData: trailingData)
    }

    private func store(_ snapshot: CodexLiveQuotaSnapshot) {
        let key = WindowKey(
            resetAtSecond: Int64(snapshot.resetAt.timeIntervalSince1970.rounded()),
            planType: snapshot.planType
        )
        guard let existing = snapshots[key] else {
            snapshots[key] = snapshot
            return
        }
        if snapshot.observedAt > existing.observedAt ||
            (snapshot.observedAt == existing.observedAt && snapshot.usedPercent > existing.usedPercent) {
            snapshots[key] = snapshot
        }
    }

    private func evictExpiredSnapshots(now: Date) {
        snapshots = snapshots.filter { CodexLiveQuotaResolver.isFresh($0.value, now: now) }
    }

    private func sessionFiles(now: Date) -> [URL] {
        let fileManager = FileManager.default
        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        var files: [(url: URL, modifiedAt: Date)] = []

        for dayOffset in 0...1 {
            guard let date = calendar.date(byAdding: .day, value: -dayOffset, to: now) else { continue }
            let components = calendar.dateComponents([.year, .month, .day], from: date)
            guard let year = components.year, let month = components.month, let day = components.day else { continue }
            let directory = sessionsURL
                .appendingPathComponent(String(format: "%04d", year), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", day), isDirectory: true)

            guard let urls = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles]
            ) else { continue }

            for url in urls where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(forKeys: resourceKeys),
                      values.isRegularFile == true else { continue }
                files.append((url, values.contentModificationDate ?? .distantPast))
            }
        }

        return files
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(Self.maximumTrackedFiles)
            .map(\.url)
    }
}
