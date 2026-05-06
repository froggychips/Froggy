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
        log.info("🐸 Froggy Daemon v0.2.0 starting")

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

        let vortex = VortexActor()
        let mlx = MLXActor(memoryLimitBytes: config.gpuMemoryLimitBytes)
        let coordinator = VortexCoordinator(
            mlx: mlx, vortex: vortex, freezeBundleIds: config.freezeBundleIds
        )
        let contextStore = ContextStore(capacity: config.contextWindowSize)
        let vision = VisionActor(
            captureInterval: .seconds(config.captureIntervalSeconds),
            redactor: Redactor(),
            contextStore: contextStore,
            frameSimilarityThreshold: config.frameSimilarityThreshold
        )

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

    /// Перехватывает SIGINT/SIGTERM и через координатор размораживает процессы.
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
    let defaultContextChars: Int

    func handle(_ request: IPCRequest) async -> IPCResponse {
        switch request.cmd {
        case "status":
            var r = IPCResponse()
            r.ok = true
            r.capturing = await vision.capturing()
            r.modelLoaded = await coordinator.mlx.isLoaded()
            r.memoryPressure = await vortex.getMemoryPressure()
            r.frozen = await vortex.suspendedCount()
            r.snapshots = await contextStore.count()
            return r

        case "generate":
            guard let prompt = request.prompt else {
                return .failure("missing 'prompt'")
            }
            do {
                let text = try await coordinator.generate(
                    prompt: prompt,
                    maxTokens: request.maxTokens ?? 200
                )
                var r = IPCResponse()
                r.ok = true
                r.text = text
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

        default:
            return .failure("unknown cmd: \(request.cmd)")
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
