import Foundation
import SQLite3

/// 只读查询 Codex state_5.sqlite 的 threads 表。
/// codex 自维护每个 thread 的 tokens_used（累计）+ updated_at，单条带索引 SQL 毫秒级。
/// 只读打开，不锁库，不影响正在运行的 Codex（WAL 允许并发读）。
struct CodexStatsDB {
    struct WindowStat: Sendable {
        var threadCount: Int
        var totalTokens: Int

        nonisolated init(threadCount: Int = 0, totalTokens: Int = 0) {
            self.threadCount = threadCount
            self.totalTokens = totalTokens
        }
    }

    nonisolated private static var homeDirectory: URL {
        if let pw = getpwuid(getuid()), let pwDir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: pwDir))
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    nonisolated private static var dbPaths: [String] {
        let codexHome = homeDirectory.appendingPathComponent(".codex")
        return [
            codexHome.appendingPathComponent("sqlite/state_5.sqlite").path,
            codexHome.appendingPathComponent("state_5.sqlite").path
        ]
    }

    nonisolated private static func readFromFirstAvailableDB<T>(_ read: (OpaquePointer) -> T?) -> T? {
        for path in dbPaths where FileManager.default.fileExists(atPath: path) {
            var db: OpaquePointer?
            // 只读 + URI，WAL 库并发读安全
            let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
            let uri = "file:\(encodedPath)?mode=ro&immutable=0"
            guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
                  let openedDB = db else {
                if let db { sqlite3_close(db) }
                continue
            }
            defer { sqlite3_close(openedDB) }

            // 忙等 2s，避免 codex 写时短暂冲突直接失败
            sqlite3_busy_timeout(openedDB, 2000)
            if let result = read(openedDB) {
                return result
            }
        }
        return nil
    }

    /// 查询 updated_at ≥ since 的 thread 数与累计 token 之和。
    nonisolated static func stat(since: Date) -> WindowStat {
        readFromFirstAvailableDB { db in
            var result = WindowStat()
            let sql = "SELECT COUNT(*), COALESCE(SUM(tokens_used), 0) FROM threads WHERE updated_at >= ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_int64(stmt, 1, Int64(since.timeIntervalSince1970))
            if sqlite3_step(stmt) == SQLITE_ROW {
                result.threadCount = Int(sqlite3_column_int64(stmt, 0))
                result.totalTokens = Int(sqlite3_column_int64(stmt, 1))
            }
            return result
        } ?? WindowStat()
    }

    /// 每日 token 用量（updated_at ≥ since），key = 当地时区的 "yyyy-MM-dd"。
    /// 用于 GitHub 风格贡献热力图。
    nonisolated static func dailyTokens(since: Date) -> [String: Int] {
        readFromFirstAvailableDB { db in
            var out: [String: Int] = [:]
            // SQLite 直接按本地时区分组成日期串
            let sql = """
            SELECT date(updated_at, 'unixepoch', 'localtime') d, SUM(tokens_used) t
            FROM threads WHERE updated_at >= ? GROUP BY d;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_int64(stmt, 1, Int64(since.timeIntervalSince1970))
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let d = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }) else { continue }
                out[d] = Int(sqlite3_column_int64(stmt, 1))
            }
            return out
        } ?? [:]
    }

    /// 按 model 分组的 token 用量（updated_at ≥ since），降序，最多 limit 条。
    nonisolated static func byModel(since: Date, limit: Int = 5) -> [(model: String, tokens: Int)] {
        readFromFirstAvailableDB { db in
            var rows: [(String, Int)] = []
            let sql = """
            SELECT COALESCE(NULLIF(model, ''), model_provider) m, SUM(tokens_used) t
            FROM threads WHERE updated_at >= ?
            GROUP BY m ORDER BY t DESC LIMIT ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_int64(stmt, 1, Int64(since.timeIntervalSince1970))
            sqlite3_bind_int(stmt, 2, Int32(limit))
            while sqlite3_step(stmt) == SQLITE_ROW {
                let model = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "unknown"
                let tokens = Int(sqlite3_column_int64(stmt, 1))
                rows.append((model, tokens))
            }
            return rows
        } ?? []
    }
}
