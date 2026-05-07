import Darwin
import Foundation
import MLXWorkerProtocol
import os

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

    private let workerURL: URL
    private let memoryLimitBytes: Int
    private let pidStore: FrozenPidsStore?

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var loadedPath: String?
    private var stdoutBuffer = Data()
    private var pendingRequests: [String: AsyncThrowingStream<MLXWorkerEvent, any Error>.Continuation] = [:]

    public init(
        memoryLimitBytes: Int? = nil,
        workerExecutableURL: URL? = nil,
        pidStore: FrozenPidsStore? = nil
    ) {
        let physical = Int(ProcessInfo.processInfo.physicalMemory)
        self.memoryLimitBytes = memoryLimitBytes ?? max(2 << 30, physical * 6 / 10)
        self.workerURL = workerExecutableURL ?? Self.defaultWorkerURL()
        self.pidStore = pidStore
    }

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

    /// Graceful shutdown: shutdown-команда → ждём goodbye до 3 секунд →
    /// SIGKILL. После выхода peak memory worker'а возвращается ядру.
    public func unloadModel() async {
        guard let p = process else { return }

        // Отправим shutdown best-effort.
        let id = UUID().uuidString
        let stream = registerRequest(id: id)
        try? sendCommand(.init(cmd: MLXWorkerCommand.shutdown, requestId: id))

        // Ждём goodbye до 3 секунд параллельно с тайм-аутом.
        let waitTask = Task {
            for try await event in stream where event.event == MLXWorkerEvent.goodbye {
                return
            }
        }
        let timeout = Task {
            try? await Task.sleep(for: .seconds(3))
        }
        _ = await Task<Void, Never>.detached {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { _ = try? await waitTask.value }
                group.addTask { _ = await timeout.value }
                _ = await group.next()
                group.cancelAll()
            }
        }.value

        if p.isRunning {
            kill(p.processIdentifier, SIGKILL)
            p.waitUntilExit()
        }
        cleanup(reason: "unload")
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

    public nonisolated func generateStream(
        prompt: String,
        maxTokens: Int = 200
    ) -> AsyncThrowingStream<String, any Error> {
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
        continuation: AsyncThrowingStream<String, any Error>.Continuation
    ) async throws {
        guard isLoaded() else { throw MLXSupervisorError.modelNotLoaded }

        let id = UUID().uuidString
        let stream = registerRequest(id: id)
        try sendCommand(.init(cmd: MLXWorkerCommand.generate, prompt: prompt, maxTokens: maxTokens, requestId: id))

        for try await event in stream {
            switch event.event {
            case MLXWorkerEvent.chunk:
                if let text = event.text { continuation.yield(text) }
            case MLXWorkerEvent.done:
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
            Task { [weak self] in await self?.handleWorkerExit(status: p.terminationStatus) }
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

    private func handleWorkerExit(status: Int32) async {
        Self.log.warning("worker exited status=\(status)")
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
