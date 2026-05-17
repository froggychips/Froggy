import Darwin
import Foundation
import os

/// Issue #58: общий pipe-lifecycle для `MLXSupervisor` / `AudioSupervisor`.
///
/// Раньше каждый supervisor хранил собственные `Process`/`stdinHandle`/
/// `stdoutBuffer` + копипастил `ReadBridge`, `OneShotResolver`,
/// `waitForExit`, `ensureWorkerSpawned`, `handleWorkerExit` race-guard,
/// `sendCommand`. ~150 строк дубля, любое улучшение приходилось делать
/// дважды и ловить регрессии.
///
/// Через `WorkerProcessHost` parent actor хранит экземпляр и взаимодействует
/// с ним через узкий API: `ensureSpawned`/`write`/`waitForExit`/`sigkill`/
/// `cleanup`. Worker-specific логика (декодинг событий, semantics pending
/// continuations, public surface area) остаётся в parent'е — для MLX и
/// Audio она настолько разная (AsyncThrowingStream by requestId vs
/// CheckedContinuation + subscribers), что общая абстракция там лишняя.
///
/// Generation-counter (`spawnGeneration`) фильтрует stale termination
/// handlers: после crash → respawn у нас два Process-объекта на короткое
/// время, и terminationHandler от старого может прилететь уже после того,
/// как parent взял в работу новый. Host доставляет `onExit` только для
/// **актуального** spawn'а; parent не должен дублировать guard.
///
/// Не protocol/не generic class по той же причине, по которой ADR-0008
/// отвергнул supervision tree: один worker per type, наследование без
/// абстракции даёт меньше чем композиция.
public final class WorkerProcessHost: @unchecked Sendable {
    public enum WorkerProcessError: Error, Sendable, CustomStringConvertible {
        case workerNotFound(String)
        case spawnFailed(String)
        case notRunning

        public var description: String {
            switch self {
            case .workerNotFound(let p): return "worker не найден: \(p)"
            case .spawnFailed(let r):    return "spawn failed: \(r)"
            case .notRunning:            return "worker не запущен"
            }
        }
    }

    private let log: Logger
    private let workerURL: URL
    private let args: [String]
    private let pidStore: FrozenPidsStore?
    /// Колбэк на каждую полную строку из stdout (без '\n'). Вызывается из
    /// nonisolated DispatchQueue — parent должен сам hop'нуть в свой actor
    /// (например, через `Task { await self?.deliverLine(line) }`).
    private let onLine: @Sendable (Data) -> Void
    /// Колбэк на актуальный exit'нувшийся spawn. Не вызывается для stale
    /// terminationHandler-ов после respawn'а.
    private let onExit: @Sendable (_ pid: Int32, _ status: Int32) -> Void

    private let lock = NSLock()
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutBuffer = Data()
    /// Увеличивается на каждом успешном `spawn`. Termination handler
    /// сравнивает свой generation с текущим — несовпадение = stale.
    private var spawnGeneration: UInt64 = 0

    public init(
        workerURL: URL,
        args: [String] = [],
        log: Logger,
        pidStore: FrozenPidsStore? = nil,
        onLine: @escaping @Sendable (Data) -> Void,
        onExit: @escaping @Sendable (_ pid: Int32, _ status: Int32) -> Void
    ) {
        self.workerURL = workerURL
        self.args = args
        self.log = log
        self.pidStore = pidStore
        self.onLine = onLine
        self.onExit = onExit
    }

    // MARK: - Public API

    public func isRunning() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return process?.isRunning == true
    }

    public func currentPid() -> Int32? {
        lock.lock(); defer { lock.unlock() }
        return process?.processIdentifier
    }

    /// Идемпотентный spawn: если процесс уже жив — no-op. Если умер —
    /// сначала cleanup, потом новый spawn (новый generation).
    public func ensureSpawned() throws {
        lock.lock()
        if process?.isRunning == true {
            lock.unlock()
            return
        }
        lock.unlock()
        try respawn()
    }

    /// Запись JSON-line в stdin worker'а. Возвращает throw если stdin закрыт.
    public func write(_ data: Data) throws {
        let handle: FileHandle? = {
            lock.lock(); defer { lock.unlock() }
            return stdinHandle
        }()
        guard let stdin = handle else { throw WorkerProcessError.notRunning }
        var payload = data
        if payload.last != 0x0A { payload.append(0x0A) }
        stdin.write(payload)
    }

    /// Ждёт exit актуального процесса до `timeout`. Возвращает true если
    /// процесс exit'нулся в окне, false если timeout сработал раньше.
    ///
    /// История race-условий: prima'рная реализация была через polling
    /// `process.isRunning` — гонка с zombification. Теперь kernel-level
    /// `DispatchSource(.exit)` + `OneShotResolver` (lock-guarded continuation
    /// resume) против double-resolve между event-handler'ом и timeout-веткой.
    public func waitForExit(timeout: Duration) async -> Bool {
        let pid = currentPid() ?? 0
        guard pid > 0 else { return true }
        return await Self.waitForExit(pid: pid, isRunningProbe: { [weak self] in
            self?.isRunning() ?? false
        }, timeout: timeout)
    }

    /// SIGKILL + wait until reaped. Безопасно вызывать после waitForExit-false.
    public func sigkill() async {
        let pid = currentPid() ?? 0
        guard pid > 0 else { return }
        kill(pid, SIGKILL)
        // SIGKILL → exit максимум за 1с. Если что-то пошло совсем не так —
        // cleanup всё равно безопасно продолжать, kill уже отправлен.
        _ = await Self.waitForExit(pid: pid, isRunningProbe: { [weak self] in
            self?.isRunning() ?? false
        }, timeout: .seconds(1))
    }

    /// Закрывает stdin, обнуляет process. Не убивает worker — это делается
    /// явно через `sigkill` или graceful через worker-specific shutdown
    /// командой + `waitForExit`.
    public func cleanup() {
        let toRemove: Int32?
        lock.lock()
        toRemove = process?.processIdentifier
        try? stdinHandle?.close()
        stdinHandle = nil
        stdoutBuffer.removeAll()
        process = nil
        lock.unlock()
        if let pid = toRemove, let pidStore {
            Task { await pidStore.remove(pid: pid) }
        }
    }

    // MARK: - Spawn internals

    private func respawn() throws {
        // Drop предыдущего state'а перед новым spawn'ом, чтобы не оставлять
        // висящий FileHandle / Process-объект.
        cleanup()

        guard FileManager.default.isExecutableFile(atPath: workerURL.path) else {
            throw WorkerProcessError.workerNotFound(workerURL.path)
        }

        let proc = Process()
        proc.executableURL = workerURL
        proc.arguments = args
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = FileHandle.standardError

        // readabilityHandler пушит данные в наш line-splitter, который
        // нарезает по '\n' и зовёт onLine для каждой полной строки.
        // weak self нужен на случай если parent освободил host раньше
        // чем worker отдал последние строки.
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            guard let self else { return }
            self.feedStdout(fh.availableData)
        }

        // Increment generation ДО proc.run, чтобы terminationHandler'у было
        // что зафиксировать в closure. Захватываем generation snapshot —
        // он не Sendable issue, поскольку UInt64 это POD.
        lock.lock()
        spawnGeneration &+= 1
        let myGen = spawnGeneration
        lock.unlock()

        proc.terminationHandler = { [weak self] p in
            guard let self else { return }
            let pid = p.processIdentifier
            let status = p.terminationStatus
            self.lock.lock()
            let currentGen = self.spawnGeneration
            self.lock.unlock()
            guard currentGen == myGen else {
                // Это terminationHandler от старого процесса, после respawn'а.
                // Игнорим, чтобы не дёргать parent.onExit лишний раз.
                self.log.notice("ignoring stale termination pid=\(pid, privacy: .public) status=\(status, privacy: .public) gen=\(myGen) current=\(currentGen)")
                return
            }
            self.onExit(pid, status)
        }

        do {
            try proc.run()
        } catch {
            throw WorkerProcessError.spawnFailed(error.localizedDescription)
        }

        lock.lock()
        self.process = proc
        self.stdinHandle = stdinPipe.fileHandleForWriting
        lock.unlock()

        log.notice("worker spawned pid=\(proc.processIdentifier, privacy: .public)")

        if let pidStore {
            let pid = proc.processIdentifier
            let path = workerURL.path
            Task { await pidStore.add(.init(pid: pid, executablePath: path, category: FrozenPidsStore.categoryWorker)) }
        }
    }

    private func feedStdout(_ data: Data) {
        guard !data.isEmpty else { return }
        var lines: [Data] = []
        lock.lock()
        stdoutBuffer.append(data)
        while let nl = stdoutBuffer.firstIndex(of: 0x0A) {
            let endOffset = stdoutBuffer.distance(from: stdoutBuffer.startIndex, to: nl)
            let line = Data(stdoutBuffer.prefix(endOffset))
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...nl)
            lines.append(line)
        }
        lock.unlock()
        // Вызов onLine — НЕ под lock. Parent попытается hop'нуть в свой actor,
        // там может быть await — нельзя держать NSLock через await.
        for line in lines { onLine(line) }
    }

    // MARK: - Static waitForExit (DispatchSource(.exit) + OneShotResolver)

    /// Реактивное ожидание exit'а через `DispatchSource(.exit)`. Если процесс
    /// уже мёртв до того, как kqueue его взял — `isRunningProbe` ловит это
    /// синхронно и резолвит сразу (NOTE_EXIT уже пропущен).
    private static func waitForExit(
        pid: Int32,
        isRunningProbe: @escaping @Sendable () -> Bool,
        timeout: Duration
    ) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let resolver = OneShotResolver(continuation: cont)
            let queue = DispatchQueue.global(qos: .userInitiated)
            let src = DispatchSource.makeProcessSource(
                identifier: pid, eventMask: .exit, queue: queue
            )
            src.setEventHandler {
                src.cancel()
                resolver.resolve(true)
            }
            src.activate()
            // Race-guard: процесс мог exit'нуться до setup'а kqueue.
            if !isRunningProbe() {
                src.cancel()
                resolver.resolve(true)
                return
            }
            let nanos = UInt64(timeout.components.seconds) * 1_000_000_000
                + UInt64(timeout.components.attoseconds / 1_000_000_000)
            queue.asyncAfter(deadline: .now() + .nanoseconds(Int(nanos))) {
                src.cancel()
                resolver.resolve(false)
            }
        }
    }
}

/// Гарантирует, что `CheckedContinuation<Bool, Never>` будет резолвлен ровно
/// один раз. `DispatchSource(.exit)` event-handler и timeout-handler гонятся
/// за resolve'ом — double `continuation.resume` это runtime-trap.
private final class OneShotResolver: @unchecked Sendable {
    private let lock = NSLock()
    private var resolved = false
    private let continuation: CheckedContinuation<Bool, Never>

    init(continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resolve(_ value: Bool) {
        lock.lock()
        let wasResolved = resolved
        if !wasResolved { resolved = true }
        lock.unlock()
        guard !wasResolved else { return }
        continuation.resume(returning: value)
    }
}
