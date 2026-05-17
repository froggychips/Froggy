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
///
/// Issue #58: pipe-lifecycle (spawn/Process/stdin/stdout/waitForExit/
/// terminationHandler race-guard) делегирован `WorkerProcessHost`.
/// Здесь — только MLX-специфика: декодинг событий, AsyncThrowingStream
/// pending-requests by requestId, public surface area.
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

    /// Pipe-lifecycle (issue #58). Lazy чтобы захватить `self` в callback'ах —
    /// `[weak self]` capture в actor init напрямую запрещён Swift 6
    /// (cannot access stored property here in nonisolated initializer).
    /// Lazy откладывает создание до первого доступа, к моменту которого
    /// init уже завершён и self полностью валиден.
    private lazy var host: WorkerProcessHost = WorkerProcessHost(
        workerURL: workerURL,
        args: ["--kv-bits", String(kvCacheBits)] + extraArgs,
        log: Self.log,
        pidStore: pidStore,
        onLine: { [weak self] line in
            guard let self else { return }
            Task { await self.handleLine(line) }
        },
        onExit: { [weak self] pid, status in
            guard let self else { return }
            Task { await self.handleWorkerExit(pid: pid, status: status) }
        }
    )
    private var loadedPath: String?
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
    /// История: были варианты с polling `process.isRunning` и withTaskGroup'ом
    /// поверх AsyncThrowingStream goodbye-event'а — оба имели race-условия
    /// (zombification window, либо вечный hang на stream без `goodbye`).
    /// Финальная реализация — `DispatchSource.makeProcessSource(.exit)`
    /// внутри `WorkerProcessHost.waitForExit`, kernel-level kqueue NOTE_EXIT
    /// без timer'ов и без race на чтении `isRunning`. См. WorkerProcessHost.
    public func unloadModel() async {
        guard let workerPid = host.currentPid() else { return }

        // POI: от shutdown-сигнала до full reap'а worker'а.
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

        let exited = await host.waitForExit(timeout: .seconds(3))
        if !exited {
            await host.sigkill()
        } else {
            graceful = true
        }
        cleanup(reason: "unload")
    }

    public func isLoaded() -> Bool { loadedPath != nil }

    public func currentModelPath() -> String? { loadedPath }

    /// Worker pid — нужен `FrozenPidsStore` recovery, чтобы убрать сирот.
    public func currentWorkerPid() -> Int32? {
        host.currentPid()
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
        do {
            try host.ensureSpawned()
        } catch WorkerProcessHost.WorkerProcessError.workerNotFound(let p) {
            throw MLXSupervisorError.workerNotFound(p)
        } catch WorkerProcessHost.WorkerProcessError.spawnFailed(let r) {
            throw MLXSupervisorError.workerSpawnFailed(r)
        } catch {
            throw MLXSupervisorError.workerSpawnFailed(error.localizedDescription)
        }
    }

    private func sendCommand(_ cmd: MLXWorkerCommand) throws {
        let data = try JSONEncoder().encode(cmd)
        do {
            try host.write(data)
        } catch {
            throw MLXSupervisorError.workerCrashed
        }
    }

    private func registerRequest(id: String) -> AsyncThrowingStream<MLXWorkerEvent, any Error> {
        AsyncThrowingStream { cont in
            self.pendingRequests[id] = cont
        }
    }

    /// Вызывается из `WorkerProcessHost.onLine` для каждой полной строки stdout'а.
    private func handleLine(_ line: Data) {
        guard let event = try? JSONDecoder().decode(MLXWorkerEvent.self, from: line) else { return }
        deliverEvent(event)
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

    /// Host фильтрует terminationHandler-arrival через generation-counter,
    /// но это не покрывает второй race: onExit→Task ждёт в actor queue,
    /// и за это время может выполниться следующий `loadModel` который
    /// уже spawn'нул новый worker. К моменту handleWorkerExit состояние
    /// supervisor'а уже принадлежит новому процессу — cleanup убил бы
    /// pending requests, относящиеся к НЕМУ. Гасим двумя guard-ветками:
    /// * currentPid == nil — `unloadModel` уже сам сделал cleanup, мы здесь
    ///   как post-mortem notification, делать ничего не надо.
    /// * currentPid == newPid (≠ pid) — старый exit, новый процесс уже работает.
    private func handleWorkerExit(pid: Int32, status: Int32) async {
        let currentPid = host.currentPid()
        guard currentPid == nil || currentPid == pid else {
            Self.log.notice("ignoring stale exit pid=\(pid) current=\(currentPid ?? 0)")
            return
        }
        if currentPid == nil {
            Self.log.info("worker exit post-cleanup pid=\(pid) status=\(status)")
            return
        }
        Self.log.warning("worker exited pid=\(pid) status=\(status)")
        // Issue #57: новый worker может иметь другую wire-version. Сбрасываем
        // флаг, чтобы первый mismatch на следующем spawn'е снова залогировался.
        wireVersionMismatchLogged = false
        cleanup(reason: "exit")
    }

    private func cleanup(reason: String) {
        for (_, cont) in pendingRequests {
            cont.finish(throwing: MLXSupervisorError.workerCrashed)
        }
        pendingRequests.removeAll()
        host.cleanup()
        loadedPath = nil
    }
}
