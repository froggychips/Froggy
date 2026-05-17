import Darwin
import Foundation
import os

/// Issue #63: структурный audit-trail freeze/thaw/pageout операций.
///
/// Запись — одна JSON-line на операцию, файл — один на день
/// (`audit-YYYY-MM-DD.log` в `~/Library/Application Support/Froggy/audit/`).
/// Retention 30 дней по дефолту (по аналогии с `FROGGY_SRE_MAX_AGE_DAYS`):
/// на init старые файлы удаляются, либо явно через `pruneOldLogs`.
///
/// Зачем не `os.Logger`: unified log хорош для real-time debugging, но плох
/// для post-mortem reconstruction'ов («почему мой VS Code завис в субботу
/// днём?»). Файл с retention'ом + структурный формат → grep / jq / parse
/// сторонним скриптом без entitlement'а на private-data в log stream'е.
public actor AuditLog {
    public static let log = Logger(subsystem: "com.froggychips.froggy", category: "audit")

    /// Запись в audit-логе. Поля минимальные — full path / cmdline в
    /// system log при необходимости, audit держит структурную сводку.
    public struct Record: Codable, Sendable {
        public let ts: String          // ISO-8601 с миллисекундами
        public let op: String          // freeze | thaw | thawAll | pageout
        public let pid: Int32?
        public let bundleId: String?
        public let tier: String?       // "1" | "2" | "manual" | nil
        public let reason: String      // pressure_warning | pressure_critical | manual | boot_recovery | emergency_sleep | …
        public let outcome: String?    // ok | failed:msg | skipped:reason | nil

        public init(
            ts: String,
            op: String,
            pid: Int32? = nil,
            bundleId: String? = nil,
            tier: String? = nil,
            reason: String,
            outcome: String? = nil
        ) {
            self.ts = ts
            self.op = op
            self.pid = pid
            self.bundleId = bundleId
            self.tier = tier
            self.reason = reason
            self.outcome = outcome
        }
    }

    private let dir: URL
    private let maxAgeDays: Int
    private let calendar: Calendar
    /// Открытый file handle для текущего дня. Переоткрывается на смене дня.
    private var currentHandle: FileHandle?
    /// `YYYY-MM-DD` суффикс файла, под который сейчас открыт `currentHandle`.
    private var currentDay: String?

    public init(
        directory: URL? = nil,
        maxAgeDays: Int = 30,
        calendar: Calendar = .current
    ) {
        self.dir = directory ?? Self.defaultDirectory
        self.maxAgeDays = maxAgeDays
        self.calendar = calendar
    }

    public static var defaultDirectory: URL {
        FroggyConfig.supportDirectory.appendingPathComponent("audit", isDirectory: true)
    }

    /// Создаёт директорию (mode 0700) и вычищает файлы старше `maxAgeDays`.
    /// Вызывать один раз при старте daemon'а.
    public func setUp() async {
        do {
            try FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            Self.log.error("audit setUp: создание директории failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        await pruneOldLogs()
    }

    /// Записывает одну строку JSON в файл сегодняшнего дня. Append-only,
    /// no fsync — потеря последней секунды записей при kernel panic
    /// допустима для audit-trail'а (это не транзакционный журнал).
    public func record(_ rec: Record) async {
        let day = Self.dayKey(rec.ts, calendar: calendar) ?? Self.today(calendar: calendar)
        rotateIfNeeded(toDay: day)
        guard let handle = currentHandle else { return }

        do {
            var data = try JSONEncoder().encode(rec)
            data.append(0x0A)
            try handle.write(contentsOf: data)
        } catch {
            Self.log.error("audit write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Helper для распространённого case'а: построить Record с
    /// `ts = now()` и записать.
    public func record(
        op: String,
        pid: Int32? = nil,
        bundleId: String? = nil,
        tier: String? = nil,
        reason: String,
        outcome: String? = nil
    ) async {
        await record(Record(
            ts: Self.nowISO(),
            op: op,
            pid: pid,
            bundleId: bundleId,
            tier: tier,
            reason: reason,
            outcome: outcome
        ))
    }

    /// Закрывает текущий handle. Вызывать на shutdown daemon'а — без этого
    /// при kernel panic'е последние writes (buffered) могут потеряться.
    public func close() {
        try? currentHandle?.close()
        currentHandle = nil
        currentDay = nil
    }

    /// Прочитать последние N записей. Если `day` задан — только из этого
    /// файла; иначе — из последнего по дате (текущего). Используется CLI
    /// `froggy audit`.
    public func tail(limit: Int = 50, day: String? = nil) async -> [Record] {
        let url: URL
        if let day {
            url = dir.appendingPathComponent("audit-\(day).log")
        } else {
            guard let latest = Self.latestLogFile(in: dir) else { return [] }
            url = latest
        }
        return Self.readTail(url: url, limit: limit)
    }

    /// Удаляет файлы старше `maxAgeDays`. Не критично — overhead малый
    /// (директория обычно содержит ≤30 файлов). Вызывается в `setUp`.
    public func pruneOldLogs() async {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-TimeInterval(maxAgeDays * 86_400))
        var removed = 0
        for url in files where url.lastPathComponent.hasPrefix("audit-") && url.pathExtension == "log" {
            guard let attrs = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  let mtime = attrs.contentModificationDate,
                  mtime < cutoff else { continue }
            try? FileManager.default.removeItem(at: url)
            removed += 1
        }
        if removed > 0 {
            Self.log.info("audit prune: removed \(removed, privacy: .public) old files older than \(self.maxAgeDays, privacy: .public)d")
        }
    }

    // MARK: - Internals

    private func rotateIfNeeded(toDay day: String) {
        if currentDay == day, currentHandle != nil { return }
        try? currentHandle?.close()
        currentHandle = nil
        currentDay = nil

        let url = dir.appendingPathComponent("audit-\(day).log")
        // Создаём с mode 0600 если нет — иначе open() даст уже существующий fd.
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(
                atPath: url.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
        }
        guard let h = try? FileHandle(forWritingTo: url) else {
            Self.log.error("audit: не открылся handle на \(url.path, privacy: .public)")
            return
        }
        // Seek to end — append-only поведение даже если файл существовал.
        do { try h.seekToEnd() } catch {
            Self.log.error("audit seekToEnd failed: \(error.localizedDescription, privacy: .public)")
        }
        currentHandle = h
        currentDay = day
    }

    // MARK: - Static helpers

    nonisolated public static func nowISO() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }

    nonisolated public static func today(calendar: Calendar = .current) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: Date())
        return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }

    /// Извлекает `YYYY-MM-DD` из ISO-8601 timestamp'а. nil — если не парсится.
    nonisolated public static func dayKey(_ iso: String, calendar: Calendar = .current) -> String? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let d = f.date(from: iso) else { return nil }
        let comps = calendar.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }

    nonisolated private static func latestLogFile(in dir: URL) -> URL? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return nil }
        let logs = files.filter { $0.lastPathComponent.hasPrefix("audit-") && $0.pathExtension == "log" }
        return logs
            .compactMap { url -> (URL, Date)? in
                guard let attrs = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                      let mtime = attrs.contentModificationDate else { return nil }
                return (url, mtime)
            }
            .max(by: { $0.1 < $1.1 })?
            .0
    }

    /// Простой tail: читаем весь файл (audit log обычно < 100K записей в день),
    /// парсим line-by-line, возвращаем последние `limit`. Если нужен более
    /// эффективный tail — `Process(launchPath: "/usr/bin/tail")` будет
    /// быстрее, но не работает для CI / sandboxed.
    nonisolated public static func readTail(url: URL, limit: Int) -> [Record] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let tail = lines.suffix(limit)
        let decoder = JSONDecoder()
        return tail.compactMap { line in
            try? decoder.decode(Record.self, from: Data(line.utf8))
        }
    }
}
