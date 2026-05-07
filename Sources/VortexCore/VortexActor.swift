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
/// Phase 4: валидация делегирована `ProcessClassifier` (default-deny по
/// исполняемому пути), и каждое успешное замораживание персистится через
/// `FrozenPidsStore` — на случай, если процесс упадёт раньше, чем доедет
/// до `thawAll`.
public actor VortexActor {
    private static let log = Logger(subsystem: "com.froggychips.froggy", category: "vortex")

    private let classifier: ProcessClassifier
    private let pidStore: FrozenPidsStore?
    private let pageout: PageoutChain?
    private var suspendedPids: Set<Int32> = []

    public init(classifier: ProcessClassifier = ProcessClassifier(),
                pidStore: FrozenPidsStore? = nil,
                pageout: PageoutChain? = nil) {
        self.classifier = classifier
        self.pidStore = pidStore
        self.pageout = pageout
    }

    // MARK: - Memory pressure

    /// Возвращает уровень давления на память в процентах (0-100).
    /// `host_statistics64(HOST_VM_INFO64)` — публичный API, без deprecated sysctl-ключей.
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

        let used = UInt64(stats.active_count)
            + UInt64(stats.wire_count)
            + UInt64(stats.compressor_page_count)
        let total = used + UInt64(stats.free_count) + UInt64(stats.inactive_count)
        guard total > 0 else { return 0 }
        return Int((used * 100) / total)
    }

    // MARK: - Process control

    /// Замораживает процесс (`SIGSTOP`). Бросает `VortexError`, если
    /// `ProcessClassifier` вернул `.forbidden`.
    @discardableResult
    public func freezeProcess(pid: Int32) async throws -> Int32 {
        let verdict = classifier.classify(pid: pid)
        let executablePath: String
        switch verdict {
        case .forbidden(let reason):
            throw VortexError.forbiddenPid(pid: pid, reason: reason)
        case .freezable(let path):
            executablePath = path
        }

        let rc = kill(pid, SIGSTOP)
        if rc != 0 {
            throw VortexError.killFailed(pid: pid, errno: errno)
        }
        suspendedPids.insert(pid)
        await pidStore?.add(.init(pid: pid, executablePath: executablePath))
        Self.log.info("suspended pid=\(pid)")

        // Принудительный pageout: SIGSTOP сам по себе оставляет dirty pages
        // резидентными. Если pageout не сработал — лог-варн, не fail freeze.
        if let pageout {
            let outcome = await pageout.pageout(pid: pid)
            switch outcome {
            case .success(let used):
                Self.log.info("pageout pid=\(pid) ok via \(used.rawValue, privacy: .public)")
            case .skipped(let reason):
                Self.log.info("pageout pid=\(pid) skipped: \(reason, privacy: .public)")
            case .failed(let reason):
                Self.log.warning("pageout pid=\(pid) failed: \(reason, privacy: .public)")
            }
        }
        return pid
    }

    /// Размораживает процесс (`SIGCONT`). Идемпотентно по pidStore.
    public func thawProcess(pid: Int32) async {
        let rc = kill(pid, SIGCONT)
        suspendedPids.remove(pid)
        await pidStore?.remove(pid: pid)
        if rc != 0 {
            Self.log.warning("thaw pid=\(pid) returned errno=\(errno)")
        } else {
            Self.log.info("resumed pid=\(pid)")
        }
    }

    /// Размораживает все ранее остановленные процессы. Идемпотентно.
    /// Сначала шлёт SIGCONT (главное), затем чистит persistent state.
    public func thawAll() async {
        let count = suspendedPids.count
        for pid in suspendedPids {
            _ = kill(pid, SIGCONT)
        }
        suspendedPids.removeAll()
        await pidStore?.clear()
        if count > 0 {
            Self.log.info("thawAll: resumed \(count) processes")
        }
    }

    public func suspendedCount() -> Int { suspendedPids.count }

    /// Реализация требования `VortexFreezing`: проксирует на `PageoutChain`.
    public func pageoutCounters() async -> PageoutCounters? {
        await pageout?.currentCounters()
    }
}
