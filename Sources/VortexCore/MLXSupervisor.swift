import Darwin
import Foundation
import MLXWorkerProtocol
import os

/// Один элемент rich-потока генерации. `.text` — токен; `.done` — финальные метрики.
public enum GenerateFragment: Sendable {
    case text(String)
    case done(promptTPS: Double?, decodeTPS: Double?, promptTokens: Int?, generatedTokens: Int?)
}

public enum MLXSupervisorError: Error, Sendable, CustomStringConvertible {
    case workerNotFound(String)
    case workerSpawnFailed(String)
    case workerCrashed
    case loadFailed(String)
    case modelNotLoaded
    case generateFailed(String)

    public var description: String {
        switch self {
        case .workerNotFound(let p): return "MLX worker не найден: \(p)"
        case .workerSpawnFailed(let r): return "Не удалось spawn-нуть worker: \(r)"
        case .workerCrashed: return "MLX worker умер во время операции"
        case .loadFailed(let r): return "MLX load failed: \(r)"
        case .modelNotLoaded: return "MLX модель не загружена"
        case .generateFailed(let r): return "MLX generate failed: \(r)"
        }
    }
}

/// Заменяет старый `MLXActor`. Поднимает `FroggyMLXWorker` как отдельный
/// процесс, общается через JSON-line stdin/stdout. На `unloadModel`
/// убивает worker — это единственный надёжный способ вернуть peak unified
/// memory ядру (см. ADR 0008). На крах worker'а — текущие операции
/// получают `.workerCrashed`, `isLoaded()` сбрасывается.
public actor MLXSupervisor {
    private static let log = Logger(subsystem: "com.froggychips.froggy", category: "mlx-supervisor")
    private static let signposter = OSSignposter(subsystem: "com.froggychips.froggy", category: "mlx-supervisor")
    /// POI-канал — Instruments автоматически рендерит это в Points of
    /// Interest track'е без `.instrpkg`. Используется для MLX lifecycle
    /// overlay'я (load/unload/generate).
    private static let poi = OSSignposter(subsystem: "com.froggychips.froggy", category: "PointsOfInterest")

    private let workerURL: URL
    private let memoryLimitBytes: Int
    private let pidStore: FrozenPidsStore?
    /// `--kv-bits` аргумент для worker-process. 16 → без квантизации.
    private let kvCacheBits: Int
    /// Дополнительные аргументы worker'а — нужны интеграционным тестам,
    /// чтобы переключать `FroggyMLXWorkerFake` в режимы `ignore-shutdown`/
    /// `crash-on-generate`.
    private let extraArgs: [String]

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var loadedPath: String?
    private var stdoutBuffer = Data()
    private var pendingRequests: [String: AsyncThrowingStream<MLXWorkerEvent, any Error>.Continuation] = [:]
    /// Issue #57: warning о версии wire-протокола логируется один раз на
    /// жизнь supervisor'а (т.е. одно лог-сообщение на spawn worker'а),
    /// чтобы не флудить лог per-event. Reset'ится при handleWorkerExit.
    private var wireVersionMismatchLogged = false

    public init(
        memoryLimitBytes: Int? = nil,
        workerExecutableURL: URL? = nil,
        pidStore: FrozenPidsStore? = nil,
        kvCacheBits: Int = 8,
        extraArgs: [String] = []
    ) {
        let physical = Int(ProcessInfo.processInfo.physicalMemory)
        self.memoryLimitBytes = memoryLimitBytes ?? max(2 << 30, physical * 6 / 10)
        self.workerURL = workerExecutableURL ?? Self.defaultWorkerURL()
        self.pidStore = pidStore
        self.kvCacheBits = kvCacheBits
        self.extraArgs = extraArgs
    }

    public func currentKVCacheBits() -> Int { kvCacheBits }

    /// Ищем worker рядом с FroggyDaemon: `<exec_dir>/FroggyMLXWorker`.
    /// Если файла нет — ошибка будет на `loadModel`, а не на init.
    public static func defaultWorkerURL() -> URL {
        let execURL = Bundle.main.executableURL
            ?? URL(fileURLWithPath: ProcessInfo.processInfo.arguments.first ?? "/usr/local/libexec/FroggyDaemon")
        return execURL.deletingLastPathComponent().appendingPathComponent("FroggyMLXWorker")
    }

    // MARK: - Public API (mirror старого MLXActor)

    public func loadModel(modelPath: String) async throws {
        let interval = Self.signposter.beginInterval("mlx.load")
        defer { Self.signposter.endInterval("mlx.load", interval) }

        // POI: от spawn'а worker'а до first IPC ack (.ready).
        let poiId = Self.poi.makeSignpostID()
        let poiState = Self.poi.beginInterval("mlx_load", id: poiId, "model_path=\(modelPath)")
        defer { Self.poi.endInterval("mlx_load", poiState) }

        try ensureWorkerSpawned()

        let id = UUID().uuidString
        let stream = registerRequest(id: id)
        try sendCommand(.init(cmd: MLXWorkerCommand.load, path: modelPath, requestId: id))

        for try await event in stream {
            switch event.event {
            case MLXWorkerEvent.ready:
                loadedPath = event.modelPath ?? modelPath
                Self.log.notice("worker загрузил модель: \(modelPath, privacy: .public)")
                return
            case MLXWorkerEvent.error:
                throw MLXSupervisorError.loadFailed(event.message ?? "unknown")
            default:
                continue
            }
        }
        throw MLXSupervisorError.workerCrashed
    }

    /// Graceful shutdown: shutdown-команда → ждём exit kernel-сигналом
    /// до 3 секунд → SIGKILL.
    ///
    /// История: сначала был withTaskGroup'овый wait через AsyncThrowingStream
    /// goodbye-event'а — но stream без `goodbye` никогда не finish'ится, и
    /// ветка `for try await` в group'е продолжала висеть после `cancelAll()`.
    /// Заменили на polling `process.isRunning` с шагом 100мс — работало, но
    /// гонка: между `!p.isRunning` и `kill()` процесс мог зомбифицироваться,
    /// или наоборот polling «промахивался» по короткоживущему окну, и мы
    /// зря ждали до конца timeout'а. Теперь — `DispatchSource.makeProcessSource(.exit)`,
    /// kernel-level kqueue NOTE_EXIT, без timer'ов и без race на чтении
    /// `p.isRunning`.
    public func unloadModel() async {
        guard let p = process else { return }

        // POI: от shutdown-сигнала до full reap'а worker'а.
        let workerPid = p.processIdentifier
        let poiId = Self.poi.makeSignpostID()
        let poiState = Self.poi.beginInterval("mlx_unload", id: poiId, "pid=\(workerPid)")
        var graceful = false
        defer {
            Self.poi.endInterval(
                "mlx_unload",
                poiState,
                "pid=\(workerPid) graceful=\(graceful ? 1 : 0)"
            )
        }

        try? sendCommand(.init(cmd: MLXWorkerCommand.shutdown, requestId: UUID().uuidString))

        let exited = await Self.waitForExit(p, timeout: .seconds(3))
        if !exited {
            kill(p.processIdentifier, SIGKILL)
            // SIGKILL гарантирован kernel'ом, но `waitUntilExit` нужен чтобы
            // дождаться reaping zombie'я и termination handler'а Process'a.
            await Self.waitForReap(p)
        } else {
            graceful = true
        }
        cleanup(reason: "unload")
    }

    /// Реактивное ожидание exit'а worker'а через `DispatchSource(.exit)`.
    /// Возвращает `true` если процесс exit'нулся в пределах timeout'а,
    /// `false` если timeout сработал раньше.
    ///
    /// Race-условие: процесс может exit'нуться между `proc.run()` и моментом
    /// когда мы создаём DispatchSource — kqueue не доставит уже пропущенный
    /// NOTE_EXIT. Закрываем явной проверкой `isRunning` после `activate()`.
    /// Если уже не running — резолвим continuation сразу.
    ///
    /// Continuation вызывается ровно один раз — guard через `OneShotResolver`
    /// (NSLock внутри), иначе и event-handler, и timeout-handler могут оба
    /// попытаться резолвить.
    private static func waitForExit(_ proc: Process, timeout: Duration) async -> Bool {
        // Снимаем pid синхронно — `Process` не Sendable, в @Sendable handler'ы
        // DispatchSource его передавать нельзя; pid (Int32) — Sendable.
        let pid = proc.processIdentifier

        // pid <= 0 — процесс не стартовал или уже reap'нут. Считаем, что exit'нулся.
        guard pid > 0 else { return true }

        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let resolver = OneShotResolver(continuation: cont)
            let queue = DispatchQueue.global(qos: .userInitiated)

            let src = DispatchSource.makeProcessSource(
                identifier: pid,
                eventMask: .exit,
                queue: queue
            )
            src.setEventHandler {
                src.cancel()
                resolver.resolve(true)
            }
            src.activate()

            // Race-guard: процесс мог exit'нуться до того, как kqueue его взял
            // под наблюдение. NOTE_EXIT уже не придёт — проверяем вручную.
            // `isRunning` тут безопасно: handler'ы ещё не escape'нули, мы в
            // том же synchronous flow что и withCheckedContinuation closure.
            if !proc.isRunning {
                src.cancel()
                resolver.resolve(true)
                return
            }

            // Timeout: cancel'им source и резолвим false. resolver гарантирует,
            // что если NOTE_EXIT уже сработал, мы не перезапишем результат.
            let nanos = UInt64(timeout.components.seconds) * 1_000_000_000
                + UInt64(timeout.components.attoseconds / 1_000_000_000)
            queue.asyncAfter(deadline: .now() + .nanoseconds(Int(nanos))) {
                src.cancel()
                resolver.resolve(false)
            }
        }
    }

    /// После SIGKILL kernel убьёт процесс почти мгновенно, но `Process` ещё
    /// не reap'нул zombie'я и не вызвал termination handler. Делаем второй
    /// `waitForExit` без timeout-зависимости — pid точно exit'нется.
    private static func waitForReap(_ proc: Process) async {
        // SIGKILL → exit максимум за 1с, иначе что-то совсем сломано — но
        // даже с timeout'ом cleanup'у безопасно продолжать (kill уже отправлен).
        _ = await waitForExit(proc, timeout: .seconds(1))
    }

    public func isLoaded() -> Bool { loadedPath != nil }

    public func currentModelPath() -> String? { loadedPath }

    /// Worker pid — нужен `FrozenPidsStore` recovery, чтобы убрать сирот.
    public func currentWorkerPid() -> Int32? {
        process?.processIdentifier
    }

    public func generate(prompt: String, maxTokens: Int = 200) async throws -> String {
        var output = ""
        for try await chunk in generateStream(prompt: prompt, maxTokens: maxTokens) {
            output += chunk
        }
        return output
    }

    /// Стриминг только текста — backward-compatible API.
    public nonisolated func generateStream(
        prompt: String,
        maxTokens: Int = 200
    ) -> AsyncThrowingStream<String, any Error> {
        let full = generateStreamFull(prompt: prompt, maxTokens: maxTokens)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await fragment in full {
                        if case .text(let t) = fragment { continuation.yield(t) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Rich-поток: токены как `.text`, финальные метрики как `.done`.
    public nonisolated func generateStreamFull(
        prompt: String,
        maxTokens: Int = 200
    ) -> AsyncThrowingStream<GenerateFragment, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.runGenerate(prompt: prompt, maxTokens: maxTokens, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Private

    private func runGenerate(
        prompt: String,
        maxTokens: Int,
        continuation: AsyncThrowingStream<GenerateFragment, any Error>.Continuation
    ) async throws {
        guard isLoaded() else { throw MLXSupervisorError.modelNotLoaded }

        let poiId = Self.poi.makeSignpostID()
        let poiState = Self.poi.beginInterval(
            "mlx_generate", id: poiId, "max_tokens=\(maxTokens) prompt_chars=\(prompt.count)"
        )
        var chunkCount = 0
        defer {
            Self.poi.endInterval("mlx_generate", poiState, "chunks=\(chunkCount) max_tokens=\(maxTokens)")
        }

        let id = UUID().uuidString
        let stream = registerRequest(id: id)
        try sendCommand(.init(cmd: MLXWorkerCommand.generate, prompt: prompt, maxTokens: maxTokens, requestId: id))

        for try await event in stream {
            switch event.event {
            case MLXWorkerEvent.chunk:
                if let text = event.text {
                    chunkCount += 1
                    continuation.yield(.text(text))
                }
            case MLXWorkerEvent.done:
                if let decode = event.decodeTPS {
                    let ptok = event.promptTokens.map { "\($0)" } ?? "?"
                    let gtok = event.generatedTokens.map { "\($0)" } ?? "?"
                    let pfill = event.promptTPS.map { String(format: "%.1f", $0) } ?? "?"
                    Self.log.notice("generate metrics: prompt=\(ptok)tok prefill=\(pfill)tok/s decode=\(String(format: "%.1f", decode))tok/s output=\(gtok)tok")
                }
                continuation.yield(.done(
                    promptTPS: event.promptTPS,
                    decodeTPS: event.decodeTPS,
                    promptTokens: event.promptTokens,
                    generatedTokens: event.generatedTokens
                ))
                return
            case MLXWorkerEvent.error:
                throw MLXSupervisorError.generateFailed(event.message ?? "unknown")
            default:
                continue
            }
        }
    }

    private func ensureWorkerSpawned() throws {
        if let p = process, p.isRunning { return }
        cleanup(reason: "respawn")

        guard FileManager.default.isExecutableFile(atPath: workerURL.path) else {
            throw MLXSupervisorError.workerNotFound(workerURL.path)
        }

        let proc = Process()
        proc.executableURL = workerURL
        proc.arguments = ["--kv-bits", String(kvCacheBits)] + extraArgs
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = FileHandle.standardError

        // readabilityHandler доставит data в наш actor через nonisolated bridge.
        let bridge = ReadBridge { [weak self] data in
            Task { await self?.feedStdout(data) }
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = { fh in
            bridge.receive(fh.availableData)
        }
        proc.terminationHandler = { p in
            let pid = p.processIdentifier
            let status = p.terminationStatus
            Task { [weak self] in await self?.handleWorkerExit(pid: pid, status: status) }
        }
        do {
            try proc.run()
        } catch {
            throw MLXSupervisorError.workerSpawnFailed(error.localizedDescription)
        }
        process = proc
        stdinHandle = stdinPipe.fileHandleForWriting
        Self.log.notice("worker spawned pid=\(proc.processIdentifier)")

        // Регистрируем pid в frozen.pids — на случай крах демона worker'а
        // отстреливаем boot-recovery'ем.
        if let pidStore {
            let pid = proc.processIdentifier
            let path = workerURL.path
            Task { await pidStore.add(.init(pid: pid, executablePath: path, category: FrozenPidsStore.categoryWorker)) }
        }
    }

    private func sendCommand(_ cmd: MLXWorkerCommand) throws {
        guard let stdin = stdinHandle else { throw MLXSupervisorError.workerCrashed }
        var data = try JSONEncoder().encode(cmd)
        data.append(0x0A)
        stdin.write(data)
    }

    private func registerRequest(id: String) -> AsyncThrowingStream<MLXWorkerEvent, any Error> {
        AsyncThrowingStream { cont in
            self.pendingRequests[id] = cont
        }
    }

    /// Вызывается из nonisolated bridge при поступлении данных из stdout worker'а.
    private func feedStdout(_ data: Data) {
        guard !data.isEmpty else { return }
        stdoutBuffer.append(data)
        while let nl = stdoutBuffer.firstIndex(of: 0x0A) {
            let endOffset = stdoutBuffer.distance(from: stdoutBuffer.startIndex, to: nl)
            let line = Data(stdoutBuffer.prefix(endOffset))
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...nl)
            if let event = try? JSONDecoder().decode(MLXWorkerEvent.self, from: line) {
                deliverEvent(event)
            }
        }
    }

    private func deliverEvent(_ event: MLXWorkerEvent) {
        // Issue #57: проверка wire-version. Worker без поля (legacy) → silent;
        // worker с другим current → warning один раз. Не fatal — может быть
        // ручная подмена `mlxWorkerPath` на чуть отстающий бинарь.
        if let v = event.apiVersion, v != MLXWireVersion.current, !wireVersionMismatchLogged {
            Self.log.warning(
                "MLX wire version mismatch: worker=\(v, privacy: .public) daemon=\(MLXWireVersion.current, privacy: .public) — продолжаем, но проверь mlxWorkerPath"
            )
            wireVersionMismatchLogged = true
        }
        guard let id = event.requestId, let cont = pendingRequests[id] else { return }
        cont.yield(event)
        switch event.event {
        case MLXWorkerEvent.ready,
             MLXWorkerEvent.done,
             MLXWorkerEvent.error,
             MLXWorkerEvent.goodbye,
             MLXWorkerEvent.pong:
            cont.finish()
            pendingRequests.removeValue(forKey: id)
        default:
            break
        }
    }

    private func handleWorkerExit(pid: Int32, status: Int32) async {
        // Issue #57: новый worker может иметь другую wire-version. Сбрасываем
        // флаг, чтобы первый mismatch на следующем spawn'е снова залогировался.
        wireVersionMismatchLogged = false
        // Race-guard: terminationHandler от старого процесса может прийти
        // ПОСЛЕ того, как `unloadModel` уже сделал cleanup и `loadModel`
        // успел spawn'нуть новый worker. В этом случае `process?.processIdentifier`
        // — pid нового, и cleanup'ить его pendingRequests нельзя.
        guard let currentPid = process?.processIdentifier, currentPid == pid else {
            Self.log.notice("ignoring stale terminationHandler pid=\(pid) status=\(status)")
            return
        }
        Self.log.warning("worker exited pid=\(pid) status=\(status)")
        cleanup(reason: "exit")
    }

    private func cleanup(reason: String) {
        for (_, cont) in pendingRequests {
            cont.finish(throwing: MLXSupervisorError.workerCrashed)
        }
        pendingRequests.removeAll()
        stdoutBuffer.removeAll()
        try? stdinHandle?.close()
        stdinHandle = nil
        if let pid = process?.processIdentifier, let pidStore {
            Task { await pidStore.remove(pid: pid) }
        }
        process = nil
        loadedPath = nil
    }
}

/// Маленький мост из nonisolated readabilityHandler в actor через @Sendable
/// closure. Хранит callback и не имеет состояния.
private final class ReadBridge: @unchecked Sendable {
    private let callback: @Sendable (Data) -> Void
    init(_ callback: @escaping @Sendable (Data) -> Void) {
        self.callback = callback
    }
    func receive(_ data: Data) { callback(data) }
}

/// Гарантирует, что `CheckedContinuation` будет резолвлен ровно один раз.
/// `DispatchSource(.exit)` event-handler и timeout-handler оба гонятся за
/// resolve'ом — кто первый, тот и записывает результат. Двойной resume
/// `CheckedContinuation` — это runtime-trap, поэтому guard обязателен.
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
