import Foundation
import SQLite3

/// 只读查询 ~/.codex/state_5.sqlite 的 threads 表。
/// codex 自维护每个 thread 的 tokens_used（累计）+ updated_at，单条带索引 SQL 毫秒级。
/// 只读打开，不锁库，不影响正在运行的 Codex（WAL 允许并发读）。
struct CodexStatsDB {
    struct WindowStat {
        var threadCount: Int = 0
        var totalTokens: Int = 0
    }

    private static var dbPath: String {
        let home: URL
        if let pw = getpwuid(getuid()), let pwDir = pw.pointee.pw_dir {
            home = URL(fileURLWithPath: String(cString: pwDir))
        } else {
            home = FileManager.default.homeDirectoryForCurrentUser
        }
        return home.appendingPathComponent(".codex/state_5.sqlite").path
    }

    /// 查询 updated_at ≥ since 的 thread 数与累计 token 之和。
    static func stat(since: Date) -> WindowStat {
        var result = WindowStat()
        guard FileManager.default.fileExists(atPath: dbPath) else { return result }

        var db: OpaquePointer?
        // 只读 + URI，WAL 库并发读安全
        let uri = "file:\(dbPath)?mode=ro&immutable=0"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            return result
        }
        defer { sqlite3_close(db) }

        // 忙等 2s，避免 codex 写时短暂冲突直接失败
        sqlite3_busy_timeout(db, 2000)

        let sql = "SELECT COUNT(*), COALESCE(SUM(tokens_used), 0) FROM threads WHERE updated_at >= ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return result }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, Int64(since.timeIntervalSince1970))
        if sqlite3_step(stmt) == SQLITE_ROW {
            result.threadCount = Int(sqlite3_column_int64(stmt, 0))
            result.totalTokens = Int(sqlite3_column_int64(stmt, 1))
        }
        return result
    }

    /// 每日 token 用量（updated_at ≥ since），key = 当地时区的 "yyyy-MM-dd"。
    /// 用于 GitHub 风格贡献热力图。
    static func dailyTokens(since: Date) -> [String: Int] {
        var out: [String: Int] = [:]
        guard FileManager.default.fileExists(atPath: dbPath) else { return out }

        var db: OpaquePointer?
        let uri = "file:\(dbPath)?mode=ro&immutable=0"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            return out
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)

        // SQLite 直接按本地时区分组成日期串
        let sql = """
        SELECT date(updated_at, 'unixepoch', 'localtime') d, SUM(tokens_used) t
        FROM threads WHERE updated_at >= ? GROUP BY d;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return out }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, Int64(since.timeIntervalSince1970))
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let d = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }) else { continue }
            out[d] = Int(sqlite3_column_int64(stmt, 1))
        }
        return out
    }

    /// 按 model 分组的 token 用量（updated_at ≥ since），降序，最多 limit 条。
    static func byModel(since: Date, limit: Int = 5) -> [(model: String, tokens: Int)] {
        var rows: [(String, Int)] = []
        guard FileManager.default.fileExists(atPath: dbPath) else { return rows }

        var db: OpaquePointer?
        let uri = "file:\(dbPath)?mode=ro&immutable=0"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            return rows
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)

        let sql = """
        SELECT COALESCE(NULLIF(model, ''), model_provider) m, SUM(tokens_used) t
        FROM threads WHERE updated_at >= ?
        GROUP BY m ORDER BY t DESC LIMIT ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return rows }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, Int64(since.timeIntervalSince1970))
        sqlite3_bind_int(stmt, 2, Int32(limit))
        while sqlite3_step(stmt) == SQLITE_ROW {
            let model = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "unknown"
            let tokens = Int(sqlite3_column_int64(stmt, 1))
            rows.append((model, tokens))
        }
        return rows
    }
}
