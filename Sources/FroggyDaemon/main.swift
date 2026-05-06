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
        log.info("🐸 Froggy Daemon v0.1.0 starting")

        let cfg: Config
        do {
            cfg = try Config.parse(arguments: CommandLine.arguments)
        } catch {
            FileHandle.standardError.write(Data("\(error)\n\n\(Config.usage)\n".utf8))
            exit(2)
        }

        let vision = VisionActor(captureInterval: .seconds(cfg.captureIntervalSeconds))
        let vortex = VortexActor()
        let mlx = MLXActor()

        // Корректный shutdown: SIGSTOP-нутые процессы должны быть отпущены.
        installSignalHandlers(vortex: vortex)

        if let modelPath = cfg.modelPath {
            do {
                try await mlx.loadModel(modelPath: modelPath)
                log.info("model loaded: \(modelPath, privacy: .public)")
            } catch {
                log.error("model load failed: \(error.localizedDescription, privacy: .public)")
            }
        } else {
            log.notice("no --model-path / FROGGY_MODEL_PATH provided; running without LLM")
        }

        let captureTask = Task {
            await vision.startCapture()
        }

        log.info("🚀 systems online")

        // Главный мониторинг-цикл. Кооперативно прерывается по cancel у task.
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
        await vortex.thawAll()
    }

    /// Перехватывает SIGINT/SIGTERM и гарантированно размораживает процессы.
    /// БЕЗ этого SIGSTOP-нутые процессы остались бы зависшими навсегда.
    private static func installSignalHandlers(vortex: VortexActor) {
        for sig in [SIGINT, SIGTERM] {
            // SIG_IGN, чтобы дефолтный обработчик не убил нас раньше DispatchSource.
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler {
                log.notice("signal \(sig) received — shutting down")
                Task {
                    await vortex.thawAll()
                    exit(0)
                }
            }
            src.resume()
            // Удерживаем источник до конца жизни процесса.
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

// MARK: - CLI / Config

struct Config: Sendable {
    var modelPath: String?
    var captureIntervalSeconds: Int = 2

    static let usage = """
    Usage: FroggyDaemon [--model-path <path>] [--capture-interval <seconds>]

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

    static func parse(arguments: [String]) throws -> Config {
        var cfg = Config()
        let env = ProcessInfo.processInfo.environment
        cfg.modelPath = env["FROGGY_MODEL_PATH"]
        if let raw = env["FROGGY_CAPTURE_INTERVAL"], let v = Int(raw) {
            cfg.captureIntervalSeconds = v
        }

        var i = 1
        while i < arguments.count {
            let arg = arguments[i]
            switch arg {
            case "--model-path":
                guard i + 1 < arguments.count else { throw ParseError.missingValue(arg) }
                cfg.modelPath = arguments[i + 1]
                i += 2
            case "--capture-interval":
                guard i + 1 < arguments.count else { throw ParseError.missingValue(arg) }
                guard let v = Int(arguments[i + 1]) else {
                    throw ParseError.invalidInt(arguments[i + 1])
                }
                cfg.captureIntervalSeconds = v
                i += 2
            case "--help", "-h":
                print(Self.usage)
                exit(0)
            default:
                throw ParseError.unknownFlag(arg)
            }
        }
        return cfg
    }
}
