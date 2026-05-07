import Foundation
import SQLite3
import os

/// Persistent телеметрия freeze-событий. Хранит RSS до/после freeze,
/// recovery time после thaw, использованную pageout-стратегию.
/// Mem-5 этап 1: только запись. Ranking-overlay (выбор tier'ов на основе
/// медиан) пойдёт отдельным PR'ом, когда данных накопится.
public actor FreezeStatsStore {
    private static let log = Logger(subsystem: "com.froggychips.froggy", category: "freeze-stats")

    public struct Event: Sendable, Codable, Equatable {
        public let timestamp: Date
        public let bundleId: String
        public let pid: Int32
        public let rssBefore: Int
        public let rssAfter: Int
        public let pageoutStrategy: String?
        public let recoveryMs: Int?

        public init(
            timestamp: Date = Date(),
            bundleId: String,
            pid: Int32,
            rssBefore: Int,
            rssAfter: Int,
            pageoutStrategy: String? = nil,
            recoveryMs: Int? = nil
        ) {
            self.timestamp = timestamp
            self.bundleId = bundleId
            self.pid = pid
            self.rssBefore = rssBefore
            self.rssAfter = rssAfter
            self.pageoutStrategy = pageoutStrategy
            self.recoveryMs = recoveryMs
        }
    }

    public struct AggregatedStats: Sendable, Codable, Equatable {
        public let bundleId: String
        public let medianFreedBytes: Int
        public let medianRecoveryMs: Int?
        public let sampleCount: Int
    }

    public enum StoreError: Error, Sendable, CustomStringConvertible {
        case openFailed(Int32)
        case prepareFailed(String)
        case stepFailed(String)

        public var description: String {
            switch self {
            case let .openFailed(c): return "sqlite3_open_v2 failed: \(c)"
            case let .prepareFailed(m): return "prepare failed: \(m)"
            case let .stepFailed(m): return "step failed: \(m)"
            }
        }
    }

    private static let schemaVersion: Int32 = 1
    private let dbPath: String
    private var db: OpaquePointer?

    public init(fileURL: URL? = nil) {
        if let url = fileURL {
            self.dbPath = url.path
        } else {
            let dir = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Froggy", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            self.dbPath = dir.appendingPathComponent("freeze_stats.sqlite").path
        }
    }

    /// Открывает БД и запускает миграции. Вызывать сразу после init.
    /// Отдельно от init, потому что init на actor синхронный, а sqlite open
    /// требует actor-isolated mutation `db`.
    public func openAndMigrate() throws {
        try open()
        try setPosixPermissions()
        try migrate()
    }

    /// Закрыть БД. Вызвать перед уничтожением — на actor нельзя из deinit.
    public func close() {
        if let db {
            sqlite3_close_v2(db)
            self.db = nil
        }
    }

    // MARK: - Public API

    public func record(_ event: Event) throws {
        let sql = """
            INSERT INTO events
                (ts, bundle_id, pid, rss_before, rss_after, pageout_strategy, recovery_ms)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.prepareFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_double(stmt, 1, event.timestamp.timeIntervalSince1970)
        // SQLITE_TRANSIENT — sqlite сам копирует строку, нам не нужно держать буфер.
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = event.bundleId.withCString { sqlite3_bind_text(stmt, 2, $0, -1, SQLITE_TRANSIENT) }
        sqlite3_bind_int(stmt, 3, event.pid)
        sqlite3_bind_int64(stmt, 4, sqlite3_int64(event.rssBefore))
        sqlite3_bind_int64(stmt, 5, sqlite3_int64(event.rssAfter))
        if let strategy = event.pageoutStrategy {
            _ = strategy.withCString { sqlite3_bind_text(stmt, 6, $0, -1, SQLITE_TRANSIENT) }
        } else {
            sqlite3_bind_null(stmt, 6)
        }
        if let ms = event.recoveryMs {
            sqlite3_bind_int(stmt, 7, Int32(ms))
        } else {
            sqlite3_bind_null(stmt, 7)
        }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StoreError.stepFailed(lastErrorMessage())
        }
    }

    /// Топ-N bundle_id по медиане `rss_before - rss_after` за последние
    /// `daysBack` дней.
    public func topByMedianFreed(limit: Int = 10, daysBack: Int = 7) throws -> [AggregatedStats] {
        // SQLite не имеет встроенного MEDIAN — считаем в памяти после
        // выборки. Для типичного 7-дневного окна это сотни-тысячи строк,
        // что окей.
        let sql = """
            SELECT bundle_id, rss_before, rss_after, recovery_ms
              FROM events
             WHERE ts >= ?;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.prepareFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(stmt) }

        let cutoff = Date().addingTimeInterval(-Double(daysBack) * 86_400).timeIntervalSince1970
        sqlite3_bind_double(stmt, 1, cutoff)

        var perBundle: [String: (freed: [Int], recovery: [Int])] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let bidPtr = sqlite3_column_text(stmt, 0) else { continue }
            let bundleId = String(cString: bidPtr)
            let rssBefore = Int(sqlite3_column_int64(stmt, 1))
            let rssAfter = Int(sqlite3_column_int64(stmt, 2))
            let freed = max(0, rssBefore - rssAfter)
            let recoveryType = sqlite3_column_type(stmt, 3)
            let recoveryMs: Int? = (recoveryType == SQLITE_NULL) ? nil : Int(sqlite3_column_int(stmt, 3))

            var entry = perBundle[bundleId] ?? ([], [])
            entry.freed.append(freed)
            if let r = recoveryMs { entry.recovery.append(r) }
            perBundle[bundleId] = entry
        }

        let aggregated: [AggregatedStats] = perBundle.map { (bid, vals) in
            AggregatedStats(
                bundleId: bid,
                medianFreedBytes: Self.median(vals.freed),
                medianRecoveryMs: vals.recovery.isEmpty ? nil : Self.median(vals.recovery),
                sampleCount: vals.freed.count
            )
        }
        return aggregated
            .sorted { $0.medianFreedBytes > $1.medianFreedBytes }
            .prefix(limit)
            .map { $0 }
    }

    public func count() throws -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM events;", -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.prepareFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw StoreError.stepFailed(lastErrorMessage())
        }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// Полная очистка таблицы — для тестов.
    public func clear() throws {
        guard sqlite3_exec(db, "DELETE FROM events;", nil, nil, nil) == SQLITE_OK else {
            throw StoreError.stepFailed(lastErrorMessage())
        }
    }

    // MARK: - Private

    private func open() throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(dbPath, &db, flags, nil)
        guard rc == SQLITE_OK, let d = db else {
            sqlite3_close_v2(db)
            throw StoreError.openFailed(rc)
        }
        self.db = d
    }

    private func setPosixPermissions() throws {
        // 0600 — пишем только владелец.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: dbPath
        )
    }

    private func migrate() throws {
        var current: Int32 = 0
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                current = sqlite3_column_int(stmt, 0)
            }
            sqlite3_finalize(stmt)
        }

        if current < 1 {
            try exec("""
                CREATE TABLE IF NOT EXISTS events (
                    id              INTEGER PRIMARY KEY AUTOINCREMENT,
                    ts              REAL    NOT NULL,
                    bundle_id       TEXT    NOT NULL,
                    pid             INTEGER NOT NULL,
                    rss_before      INTEGER NOT NULL,
                    rss_after       INTEGER NOT NULL,
                    pageout_strategy TEXT,
                    recovery_ms     INTEGER
                );
                """)
            try exec("CREATE INDEX IF NOT EXISTS idx_events_bundle ON events(bundle_id);")
            try exec("CREATE INDEX IF NOT EXISTS idx_events_ts ON events(ts);")
            try exec("PRAGMA user_version = \(Self.schemaVersion);")
            Self.log.notice("freeze_stats schema migrated to v1 at \(self.dbPath, privacy: .public)")
        }
    }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "rc=\(rc)"
            sqlite3_free(err)
            throw StoreError.stepFailed(msg)
        }
    }

    private func lastErrorMessage() -> String {
        guard let raw = sqlite3_errmsg(db) else { return "?" }
        return String(cString: raw)
    }

    private static func median(_ values: [Int]) -> Int {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let n = sorted.count
        if n % 2 == 1 { return sorted[n / 2] }
        return (sorted[n / 2 - 1] + sorted[n / 2]) / 2
    }
}
