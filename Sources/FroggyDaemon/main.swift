import Darwin
import Dispatch
import Foundation
import LushaBridge
import VortexCore
import os

private let log = Logger(subsystem: "com.froggychips.froggy", category: "daemon")

@main
struct FroggyDaemon {
    static func main() async {
        log.info("🐸 Froggy Daemon v0.4.0 starting")

        let cli: CLIArgs
        do {
            cli = try CLIArgs.parse(arguments: CommandLine.arguments)
        } catch {
            FileHandle.standardError.write(Data("\(error)\n\n\(CLIArgs.usage)\n".utf8))
            exit(2)
        }

        // Persisted config + CLI/env overrides.
        var config = (try? FroggyConfig.load()) ?? FroggyConfig()
        if let v = cli.modelPath { config.modelPath = v }
        if let v = cli.captureIntervalSeconds { config.captureIntervalSeconds = v }

        // Сначала восстанавливаемся: если предыдущий запуск умер с
        // зависшими SIGSTOP-pids — отпускаем их сейчас.
        let pidStore = FrozenPidsStore()
        let recovered = await pidStore.recover()
        if recovered > 0 {
            log.notice("recovered \(recovered) frozen pids from previous run")
        }

        let vortex = VortexActor(pidStore: pidStore)
        let mlx = MLXActor(memoryLimitBytes: config.gpuMemoryLimitBytes)
        let pressureSource: any MemoryPressureSource = DispatchMemoryPressureSource()
        let monitor = MemoryPressureMonitor(
            source: pressureSource,
            cooldownSeconds: TimeInterval(config.pressureCooldownSeconds)
        )
        let coordinator = VortexCoordinator(
            mlx: mlx,
            vortex: vortex,
            monitor: monitor,
            tier1BundleIds: config.freezeTier1BundleIds,
            tier2BundleIds: config.freezeTier2BundleIds
        )
        await coordinator.startMonitoring()
        let scorer: any SimilarityScorer = config.contextDedupEnabled
            ? JaccardSimilarityScorer()
            : NoopSimilarityScorer()
        let contextStore = ContextStore(
            capacity: config.contextWindowSize,
            scorer: scorer,
            dedupThreshold: config.contextDedupThreshold
        )
        let vision = VisionActor(
            captureInterval: .seconds(config.captureIntervalSeconds),
            redactor: Redactor(),
            contextStore: contextStore,
            frameSimilarityThreshold: config.frameSimilarityThreshold
        )

        let registry = AccessorRegistry()
        await registry.register(OCRAccessor(store: contextStore))
        await registry.register(FrontmostAppAccessor())

        installSignalHandlers(coordinator: coordinator)

        if let modelPath = config.modelPath {
            do {
                try await coordinator.loadModel(modelPath: modelPath)
                log.info("model loaded: \(modelPath, privacy: .public)")
            } catch {
                log.error("model load failed: \(error.localizedDescription, privacy: .public)")
            }
        } else {
            log.notice("no model path configured; daemon runs without LLM")
        }

        let handler = DaemonIPCHandler(
            coordinator: coordinator,
            vortex: vortex,
            vision: vision,
            contextStore: contextStore,
            registry: registry,
            augmenter: PromptAugmenter(maxContextChars: config.contextMaxChars),
            defaultContextChars: config.contextMaxChars
        )
        let ipc = IPCServer(socketPath: config.ipcSocketPath, handler: handler)
        do {
            try await ipc.start()
        } catch {
            log.error("IPC start failed: \(error.localizedDescription, privacy: .public)")
        }

        let captureTask = Task { await vision.startCapture() }
        log.info("🚀 systems online; ipc=\(config.ipcSocketPath, privacy: .public)")

        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                break
            }
            let pressure = await vortex.getMemoryPressure()
            log.info("memory pressure=\(pressure)%")
        }

        captureTask.cancel()
        await coordinator.emergencyThaw()
        await ipc.stop()
    }

    /// Перехватывает SIGINT/SIGTERM. Async-обработчик вызывает
    /// `coordinator.emergencyThaw`, но даже если процесс умрёт раньше — pids
    /// останутся в `frozen.pids` и будут разморожены на следующем старте
    /// через `FrozenPidsStore.recover()`.
    private static func installSignalHandlers(coordinator: VortexCoordinator) {
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler {
                log.notice("signal \(sig) received — shutting down")
                Task {
                    await coordinator.emergencyThaw()
                    exit(0)
                }
            }
            src.resume()
            SignalKeeper.shared.retain(src)
        }
    }
}

/// Хранит `DispatchSourceSignal`, чтобы они не сгорели по ARC.
private final class SignalKeeper: @unchecked Sendable {
    static let shared = SignalKeeper()
    private let lock = NSLock()
    private var sources: [any DispatchSourceSignal] = []

    func retain(_ source: any DispatchSourceSignal) {
        lock.lock(); defer { lock.unlock() }
        sources.append(source)
    }
}

// MARK: - IPC handler

struct DaemonIPCHandler: IPCRequestHandler, Sendable {
    let coordinator: VortexCoordinator
    let vortex: VortexActor
    let vision: VisionActor
    let contextStore: ContextStore
    let registry: AccessorRegistry
    let augmenter: PromptAugmenter
    let defaultContextChars: Int

    /// Если useContext == true, оборачиваем prompt в шаблон с свежим контекстом.
    private func augmentedPrompt(_ prompt: String, useContext: Bool?) async -> String {
        guard useContext == true else { return prompt }
        let context = await contextStore.recentContext(maxChars: defaultContextChars)
        return augmenter.augment(prompt: prompt, context: context)
    }

    func handle(_ request: IPCRequest) async -> IPCResponse {
        switch request.cmd {
        case "status":
            var r = IPCResponse()
            r.ok = true
            r.capturing = await vision.capturing()
            r.modelLoaded = await coordinator.mlx.isLoaded()
            r.modelPath = await coordinator.mlx.currentModelPath()
            r.memoryPressure = await vortex.getMemoryPressure()
            r.frozen = await vortex.suspendedCount()
            r.snapshots = await contextStore.count()
            r.lastCaptureError = await vision.lastCaptureError()
            r.final = true
            return r

        case "generate":
            // One-shot путь оставлен для совместимости. Streaming идёт
            // через handleStream и предпочтительнее для длинных ответов.
            guard let prompt = request.prompt else {
                return .failure("missing 'prompt'")
            }
            let finalPrompt = await augmentedPrompt(prompt, useContext: request.useContext)
            do {
                let text = try await coordinator.generate(
                    prompt: finalPrompt,
                    maxTokens: request.maxTokens ?? 200
                )
                var r = IPCResponse()
                r.ok = true
                r.text = text
                r.final = true
                return r
            } catch {
                return .failure(String(describing: error))
            }

        case "context":
            let maxChars = request.maxChars ?? defaultContextChars
            let text = await contextStore.recentContext(maxChars: maxChars)
            var r = IPCResponse()
            r.ok = true
            r.context = text
            r.snapshots = await contextStore.count()
            r.final = true
            return r

        case "loadModel":
            guard let path = request.path else {
                return .failure("missing 'path'")
            }
            do {
                try await coordinator.loadModel(modelPath: path)
                var r = IPCResponse()
                r.ok = true
                r.modelPath = await coordinator.mlx.currentModelPath()
                r.final = true
                return r
            } catch {
                return .failure(String(describing: error))
            }

        case "unloadModel":
            await coordinator.unloadModel()
            return .success()

        case "accessors":
            let descriptors = await registry.list()
            var r = IPCResponse()
            r.ok = true
            r.accessors = descriptors.map {
                IPCResponse.Accessor(id: $0.id, name: $0.name)
            }
            r.final = true
            return r

        case "snapshot":
            guard let id = request.accessor else {
                return .failure("missing 'accessor'")
            }
            guard let lines = await registry.snapshot(id: id) else {
                return .failure("no accessor with id '\(id)'")
            }
            var r = IPCResponse()
            r.ok = true
            r.lines = lines
            r.final = true
            return r

        case "freeze":
            guard let pid = request.pid else { return .failure("missing 'pid'") }
            do {
                try await vortex.freezeProcess(pid: pid)
                return .success()
            } catch {
                return .failure(String(describing: error))
            }

        case "thawAll":
            await vortex.thawAll()
            return .success()

        case "pressure":
            let snap = await coordinator.pressureSnapshot()
            var r = IPCResponse()
            r.ok = true
            r.pressureLevel = snap.level.rawValue
            r.tier1Frozen = snap.tier1Frozen
            r.tier2Frozen = snap.tier2Frozen
            r.secondsInLevel = snap.secondsInLevel
            r.final = true
            return r

        default:
            return .failure("unknown cmd: \(request.cmd)")
        }
    }

    /// Streaming-путь: только для команды `generate`. Каждый chunk
    /// токена идёт в свой IPCResponse, последний — с `final: true`.
    func handleStream(_ request: IPCRequest) -> AsyncThrowingStream<IPCResponse, any Error>? {
        guard request.cmd == "generate" else { return nil }
        // Если prompt отсутствует — обработаем через one-shot путь, чтобы
        // не дублировать логику ошибок.
        guard request.prompt != nil else { return nil }

        let userPrompt = request.prompt!
        let maxTokens = request.maxTokens ?? 200
        let coordinator = self.coordinator
        let useContext = request.useContext
        let handlerSelf = self

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let prompt = await handlerSelf.augmentedPrompt(userPrompt, useContext: useContext)
                    let mlxStream = await coordinator.mlx.generateStream(
                        prompt: prompt, maxTokens: maxTokens
                    )
                    for try await chunk in mlxStream {
                        var r = IPCResponse()
                        r.ok = true
                        r.text = chunk
                        r.final = false
                        continuation.yield(r)
                    }
                    var done = IPCResponse()
                    done.ok = true
                    done.final = true
                    continuation.yield(done)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - CLI

struct CLIArgs: Sendable {
    var modelPath: String?
    var captureIntervalSeconds: Int?

    static let usage = """
    Usage: FroggyDaemon [--model-path <path>] [--capture-interval <seconds>]

    Configuration is loaded from ~/Library/Application Support/Froggy/config.json
    if present. CLI flags and env vars override fields in that file.

    Environment:
      FROGGY_MODEL_PATH        absolute path to local MLX model directory
      FROGGY_CAPTURE_INTERVAL  seconds between OCR cycles (default 2)
    """

    enum ParseError: Error, CustomStringConvertible {
        case missingValue(String)
        case unknownFlag(String)
        case invalidInt(String)

        var description: String {
            switch self {
            case let .missingValue(flag): return "Flag \(flag) requires a value"
            case let .unknownFlag(flag): return "Unknown flag: \(flag)"
            case let .invalidInt(value): return "Expected integer, got: \(value)"
            }
        }
    }

    static func parse(arguments: [String]) throws -> CLIArgs {
        var cli = CLIArgs()
        let env = ProcessInfo.processInfo.environment
        cli.modelPath = env["FROGGY_MODEL_PATH"]
        if let raw = env["FROGGY_CAPTURE_INTERVAL"], let v = Int(raw) {
            cli.captureIntervalSeconds = v
        }

        var i = 1
        while i < arguments.count {
            let arg = arguments[i]
            switch arg {
            case "--model-path":
                guard i + 1 < arguments.count else { throw ParseError.missingValue(arg) }
                cli.modelPath = arguments[i + 1]
                i += 2
            case "--capture-interval":
                guard i + 1 < arguments.count else { throw ParseError.missingValue(arg) }
                guard let v = Int(arguments[i + 1]) else {
                    throw ParseError.invalidInt(arguments[i + 1])
                }
                cli.captureIntervalSeconds = v
                i += 2
            case "--help", "-h":
                print(Self.usage)
                exit(0)
            default:
                throw ParseError.unknownFlag(arg)
            }
        }
        return cli
    }
}
