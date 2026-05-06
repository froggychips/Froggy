import Darwin
import Foundation
import os

/// Persisted список pid'ов, которые daemon SIGSTOP-нул, но ещё не SIGCONT-нул.
/// Файл переживает крах demon'a — на следующем старте `recover()` шлёт
/// SIGCONT каждой записи и чистит файл. Это backstop для случая, когда
/// SIGTERM/краш не дал dispatch-обработчику добежать до thawAll.
public actor FrozenPidsStore {
    private static let log = Logger(subsystem: "com.froggychips.froggy", category: "frozen-pids")

    public struct Entry: Codable, Sendable, Equatable {
        public let pid: Int32
        public let executablePath: String
        public let frozenAt: Date

        public init(pid: Int32, executablePath: String, frozenAt: Date = Date()) {
            self.pid = pid
            self.executablePath = executablePath
            self.frozenAt = frozenAt
        }
    }

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

    public func entries() -> [Entry] {
        load()
    }

    /// Шлёт SIGCONT каждой сохранённой записи и очищает файл.
    /// Вызывать ДО старта capture-цикла на запуске демона.
    /// Возвращает количество восстановленных pids — для логов.
    @discardableResult
    public func recover() -> Int {
        let entries = load()
        guard !entries.isEmpty else { return 0 }
        for entry in entries {
            // Лучше попытаться лишний раз, чем оставить чужой процесс залипшим.
            // ESRCH (процесса уже нет) — нормально, EPERM (чужой пользователь)
            // — тоже не наша забота на recovery-пути.
            _ = kill(entry.pid, SIGCONT)
        }
        Self.log.notice("recovered \(entries.count) frozen pids on startup")
        write([])
        return entries.count
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
            Self.log.error("failed to write frozen.pids: \(error.localizedDescription)")
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
