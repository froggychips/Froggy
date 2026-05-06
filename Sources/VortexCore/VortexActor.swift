import Darwin
import Foundation
import os

public enum VortexError: Error, Sendable, CustomStringConvertible {
    case forbiddenPid(pid: Int32, reason: String)
    case killFailed(pid: Int32, errno: Int32)

    public var description: String {
        switch self {
        case let .forbiddenPid(pid, reason):
            return "Refusing to signal pid \(pid): \(reason)"
        case let .killFailed(pid, errno):
            let msg = strerror(errno).map { String(validatingCString: $0) ?? "" } ?? ""
            return "kill(\(pid)) failed: errno=\(errno) (\(msg))"
        }
    }
}

/// Управление процессами и ресурсами на Apple Silicon.
/// Все мутации `suspendedPids` идут через actor — гарантирует sendability.
public actor VortexActor {
    private static let log = Logger(subsystem: "com.froggychips.froggy", category: "vortex")

    /// Bundle IDs / executable names, которые запрещено когда-либо приостанавливать.
    /// Остановка любого из них приведёт к зависанию или потере сессии пользователя.
    private static let forbiddenExecutables: Set<String> = [
        "launchd", "kernel_task", "WindowServer", "loginwindow",
        "coreaudiod", "cfprefsd", "logd", "diskarbitrationd",
        "powerd", "watchdogd", "configd", "notifyd",
        "UserEventAgent", "distnoted", "syslogd",
    ]

    private var suspendedPids: Set<Int32> = []

    public init() {}

    // MARK: - Memory pressure

    /// Возвращает уровень давления на память в процентах (0-100), где 100 = занята вся физическая память.
    /// Использует `host_statistics64(HOST_VM_INFO64)` — публичный API, без устаревших sysctl-ключей.
    public func getMemoryPressure() -> Int {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(host, HOST_VM_INFO64, intPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            Self.log.error("host_statistics64 failed: \(result)")
            return 0
        }

        // "Used" приближаем как active + wired + compressed страницы.
        let used = UInt64(stats.active_count)
            + UInt64(stats.wire_count)
            + UInt64(stats.compressor_page_count)
        let total = used + UInt64(stats.free_count) + UInt64(stats.inactive_count)
        guard total > 0 else { return 0 }
        return Int((used * 100) / total)
    }

    // MARK: - Process control

    /// Замораживает процесс (`SIGSTOP`). Бросает `VortexError`, если pid в blacklist
    /// либо не принадлежит текущему пользователю.
    @discardableResult
    public func freezeProcess(pid: Int32) throws -> Int32 {
        try validate(pid: pid)
        let rc = kill(pid, SIGSTOP)
        if rc != 0 {
            throw VortexError.killFailed(pid: pid, errno: errno)
        }
        suspendedPids.insert(pid)
        Self.log.info("suspended pid=\(pid)")
        return pid
    }

    /// Размораживает процесс (`SIGCONT`). Не бросает, если процесс уже не существует —
    /// лишь снимает его с учёта.
    public func thawProcess(pid: Int32) {
        let rc = kill(pid, SIGCONT)
        suspendedPids.remove(pid)
        if rc != 0 {
            Self.log.warning("thaw pid=\(pid) returned errno=\(errno)")
        } else {
            Self.log.info("resumed pid=\(pid)")
        }
    }

    /// Размораживает все ранее остановленные процессы. Идемпотентно.
    /// ВАЖНО: вызывать из обработчика SIGINT/SIGTERM в `FroggyDaemon`.
    public func thawAll() {
        for pid in suspendedPids {
            _ = kill(pid, SIGCONT)
        }
        let count = suspendedPids.count
        suspendedPids.removeAll()
        if count > 0 {
            Self.log.info("thawAll: resumed \(count) processes")
        }
    }

    public func suspendedCount() -> Int { suspendedPids.count }

    // MARK: - Validation

    private func validate(pid: Int32) throws {
        guard pid > 100 else {
            throw VortexError.forbiddenPid(pid: pid, reason: "system pid (<=100)")
        }
        guard pid != getpid() else {
            throw VortexError.forbiddenPid(pid: pid, reason: "self")
        }
        // Свой ли это пользователь? proc_pidinfo требует приватных API,
        // используем kill(pid, 0) — он вернёт EPERM, если EUID не наш.
        if kill(pid, 0) != 0 {
            if errno == EPERM {
                throw VortexError.forbiddenPid(pid: pid, reason: "different EUID")
            }
            if errno == ESRCH {
                throw VortexError.forbiddenPid(pid: pid, reason: "no such process")
            }
        }
        if let name = Self.executableName(forPid: pid),
           Self.forbiddenExecutables.contains(name)
        {
            throw VortexError.forbiddenPid(pid: pid, reason: "system executable: \(name)")
        }
    }

    /// Возвращает имя исполняемого файла процесса через `proc_name` (BSD libproc).
    /// nil, если процесс недоступен.
    nonisolated private static func executableName(forPid pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 1024)
        let size = proc_name(pid, &buffer, UInt32(buffer.count))
        guard size > 0 else { return nil }
        return String(cString: buffer)
    }
}

// `proc_name` объявлен в <libproc.h> — импортируем через bridging.
@_silgen_name("proc_name")
private func proc_name(_ pid: Int32, _ buffer: UnsafeMutablePointer<CChar>, _ buffersize: UInt32) -> Int32
