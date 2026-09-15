import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct FileState {
    var offset: Int
    var lastTs: Double?
    var mtime: Double
    var size: Int
}

final class Store {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "qoderbar.store")
    private var windowsCache: [QoderProduct: [IdentityWindow]] = [:]

    init(path: String) {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            FileHandle.standardError.write("无法打开数据库: \(path)\n".data(using: .utf8)!)
            exit(1)
        }
        db = handle
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA synchronous=NORMAL;")
        exec("PRAGMA busy_timeout=3000;")
        migrate()
    }

    deinit { sqlite3_close(db) }

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func migrate() {
        exec("""
        CREATE TABLE IF NOT EXISTS events(
          id TEXT PRIMARY KEY,
          session_id TEXT NOT NULL,
          project TEXT,
          model TEXT,
          ts REAL NOT NULL,
          input_tokens INTEGER NOT NULL DEFAULT 0,
          output_tokens INTEGER NOT NULL DEFAULT 0,
          cache_read INTEGER NOT NULL DEFAULT 0,
          cache_write INTEGER NOT NULL DEFAULT 0,
          credits REAL NOT NULL DEFAULT 0,
          est_output INTEGER NOT NULL DEFAULT 0,
          duration REAL,
          product TEXT NOT NULL,
          version TEXT,
          user_key TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_events_ts ON events(ts);
        CREATE INDEX IF NOT EXISTS idx_events_user_ts ON events(user_key, ts);
        CREATE INDEX IF NOT EXISTS idx_events_session ON events(session_id);

        CREATE TABLE IF NOT EXISTS files(
          path TEXT PRIMARY KEY,
          offset INTEGER NOT NULL DEFAULT 0,
          last_ts REAL,
          mtime REAL NOT NULL DEFAULT 0,
          size INTEGER NOT NULL DEFAULT 0
        );

        CREATE TABLE IF NOT EXISTS identities(
          user_key TEXT PRIMARY KEY,
          name TEXT,
          email TEXT,
          avatar TEXT,
          product TEXT NOT NULL,
          first_seen REAL NOT NULL,
          last_seen REAL NOT NULL
        );

        CREATE TABLE IF NOT EXISTS identity_windows(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          user_key TEXT NOT NULL,
          product TEXT NOT NULL,
          start REAL NOT NULL,
          end REAL
        );
        CREATE INDEX IF NOT EXISTS idx_windows_product ON identity_windows(product, start);

        CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
        """)
        // 旧库升级：补齐新列
        if !columnExists(table: "events", column: "credits") {
            exec("ALTER TABLE events ADD COLUMN credits REAL NOT NULL DEFAULT 0;")
        }
        if !columnExists(table: "events", column: "est_output") {
            exec("ALTER TABLE events ADD COLUMN est_output INTEGER NOT NULL DEFAULT 0;")
        }
        if !columnExists(table: "events", column: "ctx_ratio") {
            exec("ALTER TABLE events ADD COLUMN ctx_ratio REAL;")
        }
    }

    private func columnExists(table: String, column: String) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 1), String(cString: c) == column { return true }
        }
        return false
    }

    // MARK: - Events

    func insertEvents(_ events: [UsageEvent]) -> Int {
        queue.sync {
            guard !events.isEmpty else { return 0 }
            exec("BEGIN IMMEDIATE;")
            var inserted = 0
            let sql = """
            INSERT OR IGNORE INTO events
            (id, session_id, project, model, ts, input_tokens, output_tokens, cache_read, cache_write, credits, est_output, duration, product, version, user_key, ctx_ratio)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                exec("COMMIT;")
                return 0
            }
            for e in events {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                sqlite3_bind_text(stmt, 1, e.id, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, e.sessionId, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 3, e.project, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 4, e.model, -1, SQLITE_TRANSIENT)
                sqlite3_bind_double(stmt, 5, e.ts.timeIntervalSince1970)
                sqlite3_bind_int64(stmt, 6, Int64(e.inputTokens))
                sqlite3_bind_int64(stmt, 7, Int64(e.outputTokens))
                sqlite3_bind_int64(stmt, 8, Int64(e.cacheRead))
                sqlite3_bind_int64(stmt, 9, Int64(e.cacheWrite))
                sqlite3_bind_double(stmt, 10, e.credits)
                sqlite3_bind_int64(stmt, 11, Int64(e.estOutputTokens))
                if let d = e.duration { sqlite3_bind_double(stmt, 12, d) } else { sqlite3_bind_null(stmt, 12) }
                sqlite3_bind_text(stmt, 13, e.product.rawValue, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 14, e.version, -1, SQLITE_TRANSIENT)
                if let u = e.userKey { sqlite3_bind_text(stmt, 15, u, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 15) }
                if let r = e.ctxRatio { sqlite3_bind_double(stmt, 16, r) } else { sqlite3_bind_null(stmt, 16) }
                if sqlite3_step(stmt) == SQLITE_DONE, sqlite3_changes(db) > 0 { inserted += 1 }
            }
            sqlite3_finalize(stmt)
            exec("COMMIT;")
            return inserted
        }
    }

    func events(from: Date, to: Date? = nil, userKey: String? = nil, limit: Int = 200_000) -> [UsageEvent] {
        queue.sync {
            var sql = """
            SELECT id, session_id, project, model, ts, input_tokens, output_tokens, cache_read, cache_write,
                   credits, est_output, duration, product, version, user_key, ctx_ratio FROM events WHERE ts >= ?
            """
            if to != nil { sql += " AND ts <= ?" }
            if userKey != nil { sql += " AND user_key = ?" }
            sql += " ORDER BY ts ASC LIMIT ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            var idx: Int32 = 1
            sqlite3_bind_double(stmt, idx, from.timeIntervalSince1970); idx += 1
            if let to { sqlite3_bind_double(stmt, idx, to.timeIntervalSince1970); idx += 1 }
            if let userKey { sqlite3_bind_text(stmt, idx, userKey, -1, SQLITE_TRANSIENT); idx += 1 }
            sqlite3_bind_int64(stmt, idx, Int64(limit))

            var result: [UsageEvent] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let product = QoderProduct(rawValue: text(stmt, 12) ?? "") ?? .qoderCN
                result.append(UsageEvent(
                    id: text(stmt, 0) ?? "",
                    sessionId: text(stmt, 1) ?? "",
                    project: text(stmt, 2) ?? "",
                    model: text(stmt, 3) ?? "",
                    ts: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4)),
                    inputTokens: Int(sqlite3_column_int64(stmt, 5)),
                    outputTokens: Int(sqlite3_column_int64(stmt, 6)),
                    cacheRead: Int(sqlite3_column_int64(stmt, 7)),
                    cacheWrite: Int(sqlite3_column_int64(stmt, 8)),
                    credits: sqlite3_column_double(stmt, 9),
                    estOutputTokens: Int(sqlite3_column_int64(stmt, 10)),
                    duration: sqlite3_column_type(stmt, 11) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 11),
                    product: product,
                    userKey: text(stmt, 14),
                    version: text(stmt, 13) ?? "",
                    ctxRatio: sqlite3_column_type(stmt, 15) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 15)
                ))
            }
            return result
        }
    }

    func eventCount() -> Int {
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM events;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
        }
    }

    func earliestEventTs(product: QoderProduct) -> Date? {
        queue.sync {
            var stmt: OpaquePointer?
            let sql = "SELECT MIN(ts) FROM events WHERE product = ?;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, product.rawValue, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_type(stmt, 0) != SQLITE_NULL else { return nil }
            return Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0))
        }
    }

    func reattributeEventsWithoutUser(product: QoderProduct, userKey: String) -> Int {
        queue.sync {
            var stmt: OpaquePointer?
            let sql = "UPDATE events SET user_key = ? WHERE user_key IS NULL AND product = ?;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, userKey, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, product.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
            return Int(sqlite3_changes(db))
        }
    }

    func deleteAllData() {
        queue.sync {
            exec("DELETE FROM events; DELETE FROM files; DELETE FROM identities; DELETE FROM identity_windows; DELETE FROM meta;")
            windowsCache.removeAll()
        }
    }

    /// 该会话最近一条已入库事件的上下文占比（用于延续缓存链）
    func lastCtxRatio(sessionId: String) -> Double? {
        queue.sync {
            var stmt: OpaquePointer?
            let sql = "SELECT ctx_ratio FROM events WHERE session_id = ? AND ctx_ratio IS NOT NULL ORDER BY ts DESC LIMIT 1;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, sessionId, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_type(stmt, 0) != SQLITE_NULL else { return nil }
            return sqlite3_column_double(stmt, 0)
        }
    }

    // MARK: - File states

    func fileState(path: String) -> FileState? {
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT offset, last_ts, mtime, size FROM files WHERE path = ?;", -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, path, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return FileState(
                offset: Int(sqlite3_column_int64(stmt, 0)),
                lastTs: sqlite3_column_type(stmt, 1) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 1),
                mtime: sqlite3_column_double(stmt, 2),
                size: Int(sqlite3_column_int64(stmt, 3))
            )
        }
    }

    func setFileState(path: String, state: FileState) {
        queue.sync {
            var stmt: OpaquePointer?
            let sql = """
            INSERT INTO files(path, offset, last_ts, mtime, size) VALUES(?,?,?,?,?)
            ON CONFLICT(path) DO UPDATE SET offset=excluded.offset, last_ts=excluded.last_ts,
              mtime=excluded.mtime, size=excluded.size;
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, path, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 2, Int64(state.offset))
            if let t = state.lastTs { sqlite3_bind_double(stmt, 3, t) } else { sqlite3_bind_null(stmt, 3) }
            sqlite3_bind_double(stmt, 4, state.mtime)
            sqlite3_bind_int64(stmt, 5, Int64(state.size))
            sqlite3_step(stmt)
        }
    }

    // MARK: - Identities

    func upsertIdentity(_ r: IdentityRecord) {
        queue.sync {
            var stmt: OpaquePointer?
            let sql = """
            INSERT INTO identities(user_key, name, email, avatar, product, first_seen, last_seen)
            VALUES(?,?,?,?,?,?,?)
            ON CONFLICT(user_key) DO UPDATE SET name=excluded.name, email=excluded.email,
              avatar=excluded.avatar, last_seen=excluded.last_seen;
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, r.userKey, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, r.name, -1, SQLITE_TRANSIENT)
            if let e = r.email { sqlite3_bind_text(stmt, 3, e, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 3) }
            if let a = r.avatarURL { sqlite3_bind_text(stmt, 4, a, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 4) }
            sqlite3_bind_text(stmt, 5, r.product.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 6, r.firstSeen.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 7, r.lastSeen.timeIntervalSince1970)
            sqlite3_step(stmt)
        }
    }

    func identities() -> [IdentityRecord] {
        queue.sync {
            var stmt: OpaquePointer?
            let sql = "SELECT user_key, name, email, avatar, product, first_seen, last_seen FROM identities ORDER BY first_seen ASC;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            var result: [IdentityRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                result.append(IdentityRecord(
                    userKey: text(stmt, 0) ?? "",
                    name: text(stmt, 1) ?? "",
                    email: text(stmt, 2),
                    avatarURL: text(stmt, 3),
                    product: QoderProduct(rawValue: text(stmt, 4) ?? "") ?? .qoderCN,
                    firstSeen: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5)),
                    lastSeen: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))
                ))
            }
            return result
        }
    }

    // MARK: - Identity windows

    func windows(for product: QoderProduct) -> [IdentityWindow] {
        queue.sync { windowsLocked(product) }
    }

    private func windowsLocked(_ product: QoderProduct) -> [IdentityWindow] {
        if let cached = windowsCache[product] { return cached }
        var stmt: OpaquePointer?
        let sql = "SELECT user_key, product, start, end FROM identity_windows WHERE product = ? ORDER BY start ASC;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, product.rawValue, -1, SQLITE_TRANSIENT)
        var result: [IdentityWindow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append(IdentityWindow(
                userKey: text(stmt, 0) ?? "",
                product: QoderProduct(rawValue: text(stmt, 1) ?? "") ?? product,
                start: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                end: sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
            ))
        }
        windowsCache[product] = result
        return result
    }

    func openWindow(userKey: String, product: QoderProduct, at: Date) {
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT INTO identity_windows(user_key, product, start, end) VALUES(?,?,?,NULL);", -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_text(stmt, 1, userKey, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, product.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 3, at.timeIntervalSince1970)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
            windowsCache[product] = nil
        }
    }

    func closeOpenWindows(product: QoderProduct, at: Date) {
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "UPDATE identity_windows SET end = ? WHERE product = ? AND end IS NULL;", -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_double(stmt, 1, at.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 2, product.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
            windowsCache[product] = nil
        }
    }

    /// 将时间戳归因到用户：先找覆盖区间，否则取最近的窗口。
    func resolveUserKey(product: QoderProduct, ts: Date) -> String? {
        queue.sync {
            let wins = windowsLocked(product)
            guard !wins.isEmpty else { return nil }
            for w in wins.reversed() {
                if w.start <= ts && (w.end == nil || w.end! >= ts) { return w.userKey }
            }
            var best: IdentityWindow?
            var bestDist = Double.greatestFiniteMagnitude
            for w in wins {
                let d: Double
                if ts < w.start {
                    d = w.start.timeIntervalSince(ts)
                } else if let e = w.end, ts > e {
                    d = ts.timeIntervalSince(e)
                } else {
                    d = 0
                }
                if d < bestDist { bestDist = d; best = w }
            }
            return best?.userKey
        }
    }

    // MARK: - Meta

    func meta(_ key: String) -> String? {
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = ?;", -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return text(stmt, 0)
        }
    }

    func setMeta(_ key: String, _ value: String) {
        queue.sync {
            var stmt: OpaquePointer?
            let sql = "INSERT INTO meta(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, value, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
    }

    // MARK: - helpers

    private func text(_ stmt: OpaquePointer?, _ col: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, col) else { return nil }
        return String(cString: c)
    }
}
