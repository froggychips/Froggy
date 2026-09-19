import Darwin
import Foundation
import os

/// Событие pipe'а worker-процесса в том порядке, в котором его увидел host.
/// Supervisor'ы гонят эти события через ОДИН `AsyncStream` и один
/// потребляющий `Task` — раньше на каждую строку создавался независимый
/// `Task { await self.handleLine(line) }`, и порядок `chunk, chunk, done`
/// (а также «последние строки → exit») не гарантировался: `done` мог обогнать
/// хвост токенов и закрыть continuation раньше времени.
///
/// `generation` — номер spawn'а, из которого пришло событие. Событие
/// старого процесса может уже лежать в очереди, когда supervisor делает
/// respawn: guard внутри host'а его не остановит, поэтому потребитель
/// сравнивает `generation` с `WorkerProcessHost.currentGeneration()` и
/// отбрасывает чужие.
public enum WorkerPipeEvent: Sendable {
    case line(Data, generation: UInt64)
    case exit(pid: Int32, status: Int32, generation: UInt64)
}

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
/// handlers и stale stdout: после crash → respawn у нас два Process-объекта
/// на короткое время, и terminationHandler / readabilityHandler от старого
/// могут прилететь уже после того, как parent взял в работу новый. Host
/// доставляет `onExit` и `onLine` только для **актуального** spawn'а и
/// помечает каждое событие его generation.
///
/// `onExit` эмитится один раз на spawn и только когда есть ОБА признака:
/// terminationHandler отработал И stdout дошёл до EOF. Иначе pump
/// supervisor'а мог обработать exit, очистить pending-запросы и лишь потом
/// получить поздний `done`/хвост stdout. Страховка — если EOF не пришёл за
/// 500 мс после termination (stdout унаследован кем-то ещё), exit уходит
/// по таймеру.
///
/// Не protocol/не generic class по той же причине, по которой ADR-0008
/// отвергнул supervision tree: один worker per type, наследование без
/// абстракции даёт меньше чем композиция.
public final class WorkerProcessHost: @unchecked Sendable {
    public enum WorkerProcessError: Error, Sendable, CustomStringConvertible {
        case workerNotFound(String)
        case spawnFailed(String)
        case notRunning
        case writeFailed(String)

        public var description: String {
            switch self {
            case .workerNotFound(let p): return "worker не найден: \(p)"
            case .spawnFailed(let r):    return "spawn failed: \(r)"
            case .notRunning:            return "worker не запущен"
            case .writeFailed(let r):    return "write to worker stdin failed: \(r)"
            }
        }
    }

    /// Потолок незавершённой (без `\n`) строки в stdout-буфере. Worker,
    /// который льёт мусор без переводов строки, иначе растил бы буфер демона
    /// без предела. При превышении буфер сбрасывается, worker получает
    /// SIGKILL; exit-путь делает обычный cleanup.
    public static let maxStdoutLineBytes = 4 * 1024 * 1024

    /// Сколько ждать EOF на stdout после terminationHandler'а, прежде чем
    /// эмитить exit без него.
    public static let exitWithoutEOFGrace: DispatchTimeInterval = .milliseconds(500)

    private let log: Logger
    private let workerURL: URL
    private let args: [String]
    private let pidStore: FrozenPidsStore?
    /// Колбэк на каждую полную строку из stdout (без '\n'). Вызывается из
    /// nonisolated DispatchQueue строго последовательно, в порядке pipe'а.
    /// Parent должен передавать строки дальше без переупорядочивания —
    /// например, через `continuation.yield(.line(line, generation: gen))`
    /// в один AsyncStream.
    private let onLine: @Sendable (_ line: Data, _ generation: UInt64) -> Void
    /// Колбэк на актуальный exit'нувшийся spawn: ровно один раз, после EOF
    /// на stdout (или по grace-таймеру). Не вызывается для stale
    /// terminationHandler-ов после respawn'а.
    private let onExit: @Sendable (_ pid: Int32, _ status: Int32, _ generation: UInt64) -> Void

    private let lock = NSLock()
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutBuffer = Data()
    /// Увеличивается на каждом успешном `spawn`. Termination handler и
    /// readability handler сравнивают свой generation с текущим —
    /// несовпадение = stale.
    private var spawnGeneration: UInt64 = 0

    public init(
        workerURL: URL,
        args: [String] = [],
        log: Logger,
        pidStore: FrozenPidsStore? = nil,
        onLine: @escaping @Sendable (_ line: Data, _ generation: UInt64) -> Void,
        onExit: @escaping @Sendable (_ pid: Int32, _ status: Int32, _ generation: UInt64) -> Void
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

    /// Номер актуального spawn'а. Потребитель `WorkerPipeEvent` сравнивает
    /// с ним `generation` события и отбрасывает события старых процессов.
    public func currentGeneration() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        return spawnGeneration
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

    /// Запись JSON-line в stdin worker'а. Бросает `.notRunning`, если stdin
    /// уже закрыт cleanup'ом, и `.writeFailed`, если ядро отказало в записи
    /// (EPIPE после смерти worker'а и т.п.).
    ///
    /// Раньше здесь был legacy `FileHandle.write(_:)` — при ошибке он
    /// поднимает ObjC-exception, которое Swift `throws` не ловит, и валил
    /// весь демон, стоило worker'у закрыть stdin раньше termination callback'а.
    /// `SIGPIPE = SIG_IGN` в демоне превращает это в EPIPE, который здесь
    /// становится обычной Swift-ошибкой.
    public func write(_ data: Data) throws {
        let handle: FileHandle? = {
            lock.lock(); defer { lock.unlock() }
            return stdinHandle
        }()
        guard let stdin = handle else { throw WorkerProcessError.notRunning }
        try Self.writeLine(data, to: stdin)
    }

    /// Запись с ограничением по времени — для shutdown-команд. Обычный
    /// `write` синхронный: если worker завис и не читает stdin, pipe
    /// заполняется и запись встаёт навсегда, а SIGKILL-fallback в supervisor'е
    /// не наступает.
    ///
    /// Снимок `stdinHandle` + generation берётся ДО старта: запись уходит
    /// именно в тот процесс, который был актуален на момент вызова, и не
    /// выполняется вовсе, если к моменту записи generation сменился
    /// (cleanup/respawn) — иначе shutdown мог уехать НОВОМУ worker'у.
    /// Сама запись идёт на глобальной очереди, а не на cooperative-потоке,
    /// чтобы зависший `write(2)` не отнимал поток у executor'а.
    ///
    /// Возвращает true, если запись завершилась в окне (успешно или
    /// ошибкой), false — по таймауту. Блокирующую запись отменить нельзя:
    /// по таймауту отпускаем только вызывающего, а сама запись отпустится,
    /// когда SIGKILL закроет pipe (EPIPE). Если stdin уже закрыт — писать
    /// некуда, возвращаем true сразу.
    public func writeWithTimeout(_ data: Data, timeout: Duration) async -> Bool {
        let snapshot: (handle: FileHandle, generation: UInt64)? = {
            lock.lock(); defer { lock.unlock() }
            guard let h = stdinHandle else { return nil }
            return (h, spawnGeneration)
        }()
        guard let snapshot else { return true }

        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let resolver = OneShotResolver(continuation: cont)
            let queue = DispatchQueue.global(qos: .utility)
            queue.async { [weak self] in
                defer { resolver.resolve(true) }
                guard let self else { return }
                self.lock.lock()
                let current = self.spawnGeneration
                self.lock.unlock()
                guard current == snapshot.generation else { return }
                try? Self.writeLine(data, to: snapshot.handle)
            }
            let nanos = UInt64(timeout.components.seconds) * 1_000_000_000
                + UInt64(timeout.components.attoseconds / 1_000_000_000)
            queue.asyncAfter(deadline: .now() + .nanoseconds(Int(nanos))) {
                resolver.resolve(false)
            }
        }
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

    private static func writeLine(_ data: Data, to handle: FileHandle) throws {
        var payload = data
        if payload.last != 0x0A { payload.append(0x0A) }
        do {
            try handle.write(contentsOf: payload)
        } catch {
            throw WorkerProcessError.writeFailed(error.localizedDescription)
        }
    }

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

        // Increment generation ДО установки handler'ов, чтобы им было что
        // зафиксировать в closure. Захватываем generation snapshot —
        // он не Sendable issue, поскольку UInt64 это POD.
        lock.lock()
        spawnGeneration &+= 1
        let myGen = spawnGeneration
        lock.unlock()

        // Объединяет два признака конца процесса — EOF на stdout и
        // terminationHandler — в один `onExit` (см. doc класса).
        let join = ExitJoin()

        // readabilityHandler пушит данные в наш line-splitter, который
        // нарезает по '\n' и зовёт onLine для каждой полной строки.
        // weak self нужен на случай если parent освободил host раньше
        // чем worker отдал последние строки.
        let readHandle = stdoutPipe.fileHandleForReading
        readHandle.readabilityHandler = { [weak self] fh in
            guard let self else {
                fh.readabilityHandler = nil
                return
            }
            let data = fh.availableData
            if data.isEmpty {
                // EOF: worker закрыл stdout (exit или явный close). Без снятия
                // handler'а Foundation зовёт его в цикле с пустыми данными —
                // CPU-спин до cleanup'а. Остаток без '\n' доставляем как строку,
                // и только ПОСЛЕ этого отмечаем EOF — чтобы exit не обогнал хвост.
                fh.readabilityHandler = nil
                self.flushStdoutTail(generation: myGen)
                if let exit = join.markEOF() {
                    self.emitExit(pid: exit.pid, status: exit.status, generation: myGen)
                }
                return
            }
            self.feedStdout(data, generation: myGen)
        }

        proc.terminationHandler = { [weak self] p in
            guard let self else { return }
            let pid = p.processIdentifier
            let status = p.terminationStatus
            if let exit = join.markExit(pid: pid, status: status) {
                // EOF уже был — можно эмитить сразу.
                self.emitExit(pid: exit.pid, status: exit.status, generation: myGen)
                return
            }
            // EOF ещё не пришёл: обычно он прилетает следом, как только pipe
            // вычитан. Страховка на случай унаследованного stdout.
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + Self.exitWithoutEOFGrace
            ) { [weak self] in
                guard let self, let exit = join.forceEmit() else { return }
                self.log.notice("worker pid=\(exit.pid, privacy: .public) exited without stdout EOF within grace — emitting exit")
                self.emitExit(pid: exit.pid, status: exit.status, generation: myGen)
            }
        }

        do {
            try proc.run()
        } catch {
            readHandle.readabilityHandler = nil
            throw WorkerProcessError.spawnFailed(error.localizedDescription)
        }

        lock.lock()
        self.process = proc
        self.stdinHandle = stdinPipe.fileHandleForWriting
        lock.unlock()

        log.notice("worker spawned pid=\(proc.processIdentifier, privacy: .public) gen=\(myGen, privacy: .public)")

        if let pidStore {
            let pid = proc.processIdentifier
            let path = workerURL.path
            Task { await pidStore.add(.init(pid: pid, executablePath: path, category: FrozenPidsStore.categoryWorker)) }
        }
    }

    /// Единственная точка выдачи `onExit`. Stale-generation (после respawn'а)
    /// отбрасывается здесь; потребитель дополнительно сравнивает
    /// `generation` события с `currentGeneration()`.
    private func emitExit(pid: Int32, status: Int32, generation: UInt64) {
        lock.lock()
        let currentGen = spawnGeneration
        lock.unlock()
        guard currentGen == generation else {
            // Это exit от старого процесса, после respawn'а. Игнорим, чтобы
            // не дёргать parent.onExit лишний раз.
            log.notice("ignoring stale termination pid=\(pid, privacy: .public) status=\(status, privacy: .public) gen=\(generation) current=\(currentGen)")
            return
        }
        onExit(pid, status, generation)
    }

    private func feedStdout(_ data: Data, generation: UInt64) {
        guard !data.isEmpty else { return }
        var lines: [Data] = []
        var overflowPid: Int32?
        lock.lock()
        guard generation == spawnGeneration else {
            // Хвост stdout старого процесса после respawn'а — не смешиваем
            // его с буфером нового.
            lock.unlock()
            return
        }
        stdoutBuffer.append(data)
        while let nl = stdoutBuffer.firstIndex(of: 0x0A) {
            let endOffset = stdoutBuffer.distance(from: stdoutBuffer.startIndex, to: nl)
            let line = Data(stdoutBuffer.prefix(endOffset))
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...nl)
            lines.append(line)
        }
        if stdoutBuffer.count > Self.maxStdoutLineBytes {
            stdoutBuffer.removeAll()
            overflowPid = process?.processIdentifier
        }
        lock.unlock()
        // Вызов onLine — НЕ под lock. Parent попытается hop'нуть в свой actor,
        // там может быть await — нельзя держать NSLock через await.
        for line in lines { onLine(line, generation) }
        if let overflowPid {
            log.error("worker pid=\(overflowPid, privacy: .public) stdout line exceeded \(Self.maxStdoutLineBytes) bytes without newline — killing")
            kill(overflowPid, SIGKILL)
        }
    }

    /// EOF на stdout: остаток буфера без завершающего '\n' отдаём как
    /// последнюю строку. Только для актуального generation.
    private func flushStdoutTail(generation: UInt64) {
        lock.lock()
        guard generation == spawnGeneration else {
            lock.unlock()
            return
        }
        let tail = stdoutBuffer
        stdoutBuffer.removeAll()
        lock.unlock()
        if !tail.isEmpty { onLine(tail, generation) }
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

/// Per-spawn объединение «terminationHandler отработал» и «stdout дошёл до
/// EOF» в один exit. Оба события приходят с разных очередей; `emitted`
/// гарантирует, что `onExit` уйдёт ровно один раз — в том числе когда
/// grace-таймер и поздний EOF гонятся за выдачей.
private final class ExitJoin: @unchecked Sendable {
    struct Exit { let pid: Int32; let status: Int32 }

    private let lock = NSLock()
    private var sawEOF = false
    private var exit: Exit?
    private var emitted = false

    /// EOF на stdout. Возвращает exit для выдачи, если termination уже был.
    func markEOF() -> Exit? {
        lock.lock(); defer { lock.unlock() }
        sawEOF = true
        return takeIfReady()
    }

    /// terminationHandler. Возвращает exit для выдачи, если EOF уже был.
    func markExit(pid: Int32, status: Int32) -> Exit? {
        lock.lock(); defer { lock.unlock() }
        exit = Exit(pid: pid, status: status)
        return takeIfReady()
    }

    /// Grace-таймер: выдать exit без EOF, если ещё не выдан.
    func forceEmit() -> Exit? {
        lock.lock(); defer { lock.unlock() }
        guard let exit, !emitted else { return nil }
        emitted = true
        return exit
    }

    private func takeIfReady() -> Exit? {
        guard sawEOF, let exit, !emitted else { return nil }
        emitted = true
        return exit
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
