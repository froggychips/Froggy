import Darwin
import Dispatch
import Foundation
import MLXWorkerProtocol

/// Тестовый-двойник `FroggyMLXWorker`. Понимает тот же JSON-line протокол,
/// но без MLX-зависимостей. Поведение управляется CLI-флагом `--mode`:
///
/// - `happy` (по умолчанию) — на load → ready через 50 мс,
///   на generate → 5 fake chunks по 10 мс + done, на shutdown → goodbye + exit.
/// - `ignore-shutdown` — игнорит shutdown (тест SIGKILL-fallback в supervisor).
/// - `crash-on-generate` — exit с ненулевым кодом сразу как пришёл generate
///   (тест .workerCrashed в pending continuation).
///
/// Чтение stdin — non-blocking через `FileHandle.readabilityHandler`.
/// Это и был баг с предыдущим python-stub'ом: его блокирующий `for line in
/// sys.stdin` тащил supervisor в зависание.

@main
struct FroggyMLXWorkerFake {
    static func main() {
        let mode = parseMode()
        let writer = LineWriter(handle: FileHandle.standardOutput)
        let runtime = FakeRuntime(mode: mode, writer: writer)
        runtime.start()
        // Главный thread ждёт на dispatch_main — handler работает на фоновой очереди.
        dispatchMain()
    }

    static func parseMode() -> FakeMode {
        let argv = CommandLine.arguments
        var i = 1
        while i < argv.count {
            if argv[i] == "--mode", i + 1 < argv.count {
                return FakeMode(rawValue: argv[i + 1]) ?? .happy
            }
            i += 1
        }
        return .happy
    }
}

enum FakeMode: String {
    case happy = "happy"
    case ignoreShutdown = "ignore-shutdown"
    case crashOnGenerate = "crash-on-generate"
}

/// Безопасная запись в stdout: одна JSON-строка + `\n` под локом.
final class LineWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle

    init(handle: FileHandle) { self.handle = handle }

    func emit(_ event: MLXWorkerEvent) {
        guard var data = try? JSONEncoder().encode(event) else { return }
        data.append(0x0A)
        lock.lock(); defer { lock.unlock() }
        handle.write(data)
    }
}

final class FakeRuntime: @unchecked Sendable {
    private let mode: FakeMode
    private let writer: LineWriter
    private let handle: FileHandle = .standardInput
    private let queue = DispatchQueue(label: "fake.worker.io", qos: .userInitiated)
    private var buffer = Data()

    init(mode: FakeMode, writer: LineWriter) {
        self.mode = mode
        self.writer = writer
    }

    func start() {
        handle.readabilityHandler = { [weak self] fh in
            let chunk = fh.availableData
            if chunk.isEmpty {
                // EOF — supervisor закрыл pipe. Грациозно выходим.
                self?.handle.readabilityHandler = nil
                exit(0)
            }
            self?.queue.async { self?.feed(chunk) }
        }
    }

    private func feed(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let endOffset = buffer.distance(from: buffer.startIndex, to: nl)
            let line = Data(buffer.prefix(endOffset))
            buffer.removeSubrange(buffer.startIndex...nl)
            handle(line: line)
        }
    }

    private func handle(line: Data) {
        guard let cmd = try? JSONDecoder().decode(MLXWorkerCommand.self, from: line) else {
            writer.emit(.init(event: MLXWorkerEvent.error, message: "fake: malformed command"))
            return
        }
        switch cmd.cmd {
        case MLXWorkerCommand.ping:
            writer.emit(.init(event: MLXWorkerEvent.pong, requestId: cmd.requestId))

        case MLXWorkerCommand.load:
            queue.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
                self?.writer.emit(.init(
                    event: MLXWorkerEvent.ready,
                    requestId: cmd.requestId,
                    modelPath: cmd.path
                ))
            }

        case MLXWorkerCommand.generate:
            if mode == .crashOnGenerate {
                // Грубо имитируем краш: рвём pipe и exit'имся.
                exit(EXIT_FAILURE)
            }
            // 5 fake chunks с задержкой 10 мс между ними, потом done.
            for i in 0..<5 {
                queue.asyncAfter(deadline: .now() + .milliseconds(10 * (i + 1))) { [weak self] in
                    self?.writer.emit(.init(
                        event: MLXWorkerEvent.chunk,
                        requestId: cmd.requestId,
                        text: "tok\(i) "
                    ))
                }
            }
            queue.asyncAfter(deadline: .now() + .milliseconds(60)) { [weak self] in
                self?.writer.emit(.init(event: MLXWorkerEvent.done, requestId: cmd.requestId))
            }

        case MLXWorkerCommand.shutdown:
            if mode == .ignoreShutdown {
                // Молча игнорим — supervisor должен сделать SIGKILL по таймауту.
                return
            }
            writer.emit(.init(event: MLXWorkerEvent.goodbye, requestId: cmd.requestId))
            queue.asyncAfter(deadline: .now() + .milliseconds(20)) { exit(0) }

        default:
            writer.emit(.init(
                event: MLXWorkerEvent.error,
                requestId: cmd.requestId,
                message: "fake: unknown cmd \(cmd.cmd)"
            ))
        }
    }
}
