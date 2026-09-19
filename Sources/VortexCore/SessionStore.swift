import Darwin
import Foundation
import os

public enum SessionStoreError: Error, Sendable, CustomStringConvertible {
    case createFailed(path: String, errno: Int32)

    public var description: String {
        switch self {
        case let .createFailed(path, e):
            let msg = strerror(e).map { String(validatingCString: $0) ?? "" } ?? ""
            return "session file create failed: \(path) errno=\(e) (\(msg))"
        }
    }
}

/// Append-only markdown-файл одной сессии созвона.
/// Путь: ~/Documents/Froggy/Meetings/YYYY-MM-DD_HH-mm-ss.md
/// Каждый финальный сегмент транскрипта флашится немедленно — файл читаемый,
/// даже если демон упадёт посреди созвона.
///
/// Транскрипт — приватные данные. Каталог создаётся `0700`, файл — `0600`
/// через `open(O_CREAT|O_EXCL)`: раньше `createFile` наследовал umask
/// (обычно `0644`) и молча перезаписывал файл с тем же именем, если второй
/// `startCapture` приходил в ту же секунду.
public actor SessionStore {
    private static let log = Logger(subsystem: "com.froggychips.froggy", category: "session-store")

    /// Реально созданный файл. Может отличаться от запрошенного суффиксом
    /// `-N`, если имя было занято (см. `init`).
    public let url: URL
    private let handle: FileHandle
    private let timeFormatter: DateFormatter

    public init(at requestedURL: URL) throws {
        let dir = requestedURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // `attributes:` действует только на создаваемый каталог. Уже
        // существующий `~/Documents/Froggy/Meetings` (создан старой версией
        // с umask-правами) подтягиваем до 0700 best-effort.
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        } catch {
            Self.log.warning("session dir chmod 0700 failed: \(dir.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        // Эксклюзивное создание. Коллизия имени (две сессии в одну секунду,
        // быстрый stop→start) — не перезапись, а следующий свободный суффикс.
        var candidate = requestedURL
        var fd: Int32 = -1
        var lastErrno: Int32 = 0
        for attempt in 0...16 {
            if attempt > 0 {
                let base = requestedURL.deletingPathExtension().lastPathComponent
                let ext = requestedURL.pathExtension
                candidate = dir.appendingPathComponent("\(base)-\(attempt)")
                if !ext.isEmpty { candidate.appendPathExtension(ext) }
            }
            fd = open(candidate.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
            if fd >= 0 { break }
            lastErrno = errno
            if lastErrno != EEXIST { break }
        }
        guard fd >= 0 else {
            throw SessionStoreError.createFailed(path: candidate.path, errno: lastErrno)
        }
        self.handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        self.url = candidate

        let tf = DateFormatter()
        tf.dateFormat = "HH:mm:ss"
        self.timeFormatter = tf

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let header = "# Meeting — \(iso.string(from: Date()))\n\n"
        // `write(contentsOf:)` — Swift-ошибка вместо ObjC-exception legacy `write(_:)`,
        // которое `throws` не ловит (полный диск ронял бы демон).
        try handle.write(contentsOf: Data(header.utf8))
    }

    /// Добавляет финальный сегмент транскрипта.
    public func append(speaker: String, text: String) {
        let ts = timeFormatter.string(from: Date())
        write("**[\(ts)] \(speaker):** \(text)\n\n")
    }

    /// Добавляет именованную секцию (например ## Summary).
    public func appendSection(title: String, content: String) {
        write("\n## \(title)\n\n\(content)\n")
    }

    public func close() {
        do {
            try handle.close()
        } catch {
            Self.log.error("session close failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func write(_ s: String) {
        do {
            try handle.write(contentsOf: Data(s.utf8))
        } catch {
            Self.log.error("session write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Стандартный каталог сессий.
    public static var defaultDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Froggy/Meetings", isDirectory: true)
    }

    /// Стандартный путь для новой сессии в `defaultDirectory`.
    public static func makeURL() -> URL {
        makeURL(in: defaultDirectory)
    }

    /// Путь для новой сессии в произвольном каталоге (тесты, кастомный
    /// `sessionDirectory` у `AudioSupervisor`).
    public static func makeURL(in dir: URL) -> URL {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return dir.appendingPathComponent("\(df.string(from: Date())).md")
    }
}
