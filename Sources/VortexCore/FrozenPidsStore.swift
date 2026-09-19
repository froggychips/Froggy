import Darwin
import Darwin.libproc
import Foundation
import os

/// Persisted список pid'ов, которые daemon SIGSTOP-нул, но ещё не SIGCONT-нул.
/// Файл переживает крах demon'a — на следующем старте `recover()` шлёт
/// SIGCONT каждой записи и чистит файл. Это backstop для случая, когда
/// SIGTERM/краш не дал dispatch-обработчику добежать до thawAll.
///
/// Ревью 2026-09-19: pid сам по себе не идентифицирует процесс — после краша
/// и тем более после перезагрузки тот же номер может достаться IDE или
/// терминалу пользователя, и recovery послал бы ему SIGCONT (а записи
/// воркеров — SIGKILL). Поэтому запись несёт секунду старта процесса
/// (`proc_bsdinfo.pbi_start_tvsec`) и путь бинаря, а `recover()` проверяет
/// обе перед сигналом.
public actor FrozenPidsStore {
    private static let log = Logger(subsystem: "com.froggychips.froggy", category: "frozen-pids")

    public struct Entry: Codable, Sendable, Equatable {
        public let pid: Int32
        public let executablePath: String
        public let frozenAt: Date
        /// `nil` — это «обычный» SIGSTOP-процесс (Slack/Spotify/...), recover
        /// шлёт ему SIGCONT. `"worker"` — наш собственный `FroggyMLXWorker`,
        /// recover убивает его SIGKILL'ом. См. ADR 0008.
        public let category: String?
        /// Секунда старта процесса на момент записи. Вместе с pid однозначно
        /// задаёт экземпляр процесса. `nil` — запись старого формата или
        /// `proc_pidinfo` отказал; тогда recover опирается только на путь бинаря.
        public let startTime: UInt64?

        public init(pid: Int32, executablePath: String, frozenAt: Date = Date(),
                    category: String? = nil, startTime: UInt64? = nil) {
            self.pid = pid
            self.executablePath = executablePath
            self.frozenAt = frozenAt
            self.category = category
            self.startTime = startTime ?? FrozenPidsStore.processStartTime(pid: pid)
        }
    }

    /// Итог boot-recovery: сколько записей получили SIGCONT, сколько воркеров —
    /// SIGKILL, сколько пропущено из-за несовпадения идентичности процесса.
    public struct RecoveryReport: Sendable, Equatable {
        public var thawed: Int
        public var killed: Int
        public var skipped: Int
        public var total: Int { thawed + killed + skipped }

        public init(thawed: Int = 0, killed: Int = 0, skipped: Int = 0) {
            self.thawed = thawed
            self.killed = killed
            self.skipped = skipped
        }
    }

    public static let categoryWorker = "worker"

    private let fileURL: URL

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let dir = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Froggy", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            self.fileURL = dir.appendingPathComponent("frozen.pids")
        }
    }

    public func add(_ entry: Entry) {
        var entries = load()
        entries.removeAll { $0.pid == entry.pid }
        entries.append(entry)
        write(entries)
    }

    public func remove(pid: Int32) {
        var entries = load()
        let before = entries.count
        entries.removeAll { $0.pid == pid }
        if entries.count != before {
            write(entries)
        }
    }

    public func clear() {
        write([])
    }

    /// Снимает только записи замороженных приложений (`category == nil`).
    /// Записи воркеров остаются: воркеры при `thawAll` не умирают, и их
    /// recovery-запись должна это пережить — иначе после краша демона
    /// во время долгой MLX-операции о старом воркере никто не узнает.
    public func clearFrozen() {
        var entries = load()
        let before = entries.count
        entries.removeAll { $0.category == nil }
        if entries.count != before {
            write(entries)
        }
    }

    public func entries() -> [Entry] {
        load()
    }

    /// Boot-recovery. Для обычных записей шлём SIGCONT, для записей с
    /// `category == "worker"` — SIGKILL (если worker сирота, убиваем его
    /// насовсем — модель в его адресном пространстве уже не нужна).
    /// Записи, чей pid уже принадлежит другому процессу (или процесса нет),
    /// пропускаются без сигнала. Файл очищается полностью.
    /// Возвращает количество обработанных записей (включая пропущенные).
    @discardableResult
    public func recover() -> Int {
        recoverDetailed().total
    }

    /// То же, что `recover()`, но с разбивкой по исходам — для логов и тестов.
    public func recoverDetailed() -> RecoveryReport {
        let entries = load()
        guard !entries.isEmpty else { return RecoveryReport() }
        var report = RecoveryReport()
        for entry in entries {
            guard Self.isSameProcess(entry) else {
                report.skipped += 1
                Self.log.notice("recover: pid=\(entry.pid) is not the process we froze (exited or pid reused) — skipping")
                continue
            }
            if entry.category == Self.categoryWorker {
                _ = kill(entry.pid, SIGKILL)
                report.killed += 1
            } else {
                _ = kill(entry.pid, SIGCONT)
                report.thawed += 1
            }
        }
        Self.log.notice("recovered \(report.thawed) frozen pids + killed \(report.killed) worker pids, skipped \(report.skipped) on startup")
        write([])
        return report
    }

    // MARK: - Идентичность процесса

    /// Секунда старта процесса (`proc_bsdinfo.pbi_start_tvsec`) через
    /// `proc_pidinfo(PROC_PIDTBSDINFO)`. `nil` — процесса нет или доступ закрыт.
    nonisolated public static func processStartTime(pid: Int32) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let written = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard written == size else { return nil }
        return info.pbi_start_tvsec
    }

    /// Тот ли это процесс, который мы морозили. `kill(pid, 0)` — жив ли вообще
    /// (ESRCH → нет; EPERM → жив, но чужого UID — наш сигнал всё равно не
    /// пройдёт). Дальше — время старта (если записано) и путь бинаря. Если
    /// проверить нечем (ни времени, ни пути), считаем несовпадением: лучше
    /// оставить один процесс остановленным до ручного `froggy thaw`, чем
    /// послать SIGCONT/SIGKILL чужому.
    nonisolated static func isSameProcess(_ entry: Entry) -> Bool {
        guard kill(entry.pid, 0) == 0 else { return false }
        var verified = false
        if let recorded = entry.startTime {
            guard let current = processStartTime(pid: entry.pid), current == recorded else {
                return false
            }
            verified = true
        }
        if let path = ProcessClassifier.executablePath(pid: entry.pid) {
            guard path == entry.executablePath else { return false }
            verified = true
        }
        return verified
    }

    // MARK: - IO

    private func load() -> [Entry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder.iso.decode([Entry].self, from: data)) ?? []
    }

    private func write(_ entries: [Entry]) {
        do {
            let data = try JSONEncoder.iso.encode(entries)
            try data.write(to: fileURL, options: [.atomic])
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: fileURL.path
            )
        } catch {
            Self.log.error("failed to write frozen.pids: \(error.localizedDescription, privacy: .private)")
        }
    }
}

extension JSONDecoder {
    static let iso: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

extension JSONEncoder {
    static let iso: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
}
