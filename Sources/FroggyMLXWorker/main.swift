import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import MLXWorkerProtocol
import Tokenizers
import os

/// FroggyMLXWorker — отдельный процесс, держащий ровно одну MLX-модель.
/// Демон спавнит его на `loadModel`, общается через stdin/stdout JSON-line,
/// убивает на `unloadModel` — это единственный надёжный способ вернуть
/// peak unified memory ядру (см. ADR 0008).

@main
struct FroggyMLXWorker {
    static func main() async {
        let log = Logger(subsystem: "com.froggychips.froggy.worker", category: "worker")
        log.notice("worker started pid=\(getpid())")

        let runtime = WorkerRuntime(log: log)
        await runtime.run()
    }
}

actor WorkerRuntime {
    private let log: Logger
    private var container: ModelContainer?
    private var loadedPath: String?
    private var memoryLimitApplied = false

    init(log: Logger) {
        self.log = log
    }

    func run() async {
        // Чтение stdin — отдельный «канал», просто строки.
        let stdin = FileHandle.standardInput
        let stdout = FileHandle.standardOutput

        // Используем построчное чтение через Data-buffer.
        var buffer = Data()
        while true {
            let chunk = stdin.availableData
            if chunk.isEmpty { break } // EOF
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let endOffset = buffer.distance(from: buffer.startIndex, to: nl)
                let line = Data(buffer.prefix(endOffset))
                buffer.removeSubrange(buffer.startIndex...nl)
                guard let cmd = try? JSONDecoder().decode(MLXWorkerCommand.self, from: line) else {
                    Self.write(.init(event: MLXWorkerEvent.error, message: "malformed command"), to: stdout)
                    continue
                }
                await dispatch(cmd, to: stdout)
                if cmd.cmd == MLXWorkerCommand.shutdown {
                    log.notice("worker shutdown ack")
                    Self.write(.init(event: MLXWorkerEvent.goodbye, requestId: cmd.requestId), to: stdout)
                    return
                }
            }
        }
    }

    private func dispatch(_ cmd: MLXWorkerCommand, to stdout: FileHandle) async {
        switch cmd.cmd {
        case MLXWorkerCommand.ping:
            Self.write(.init(event: MLXWorkerEvent.pong, requestId: cmd.requestId), to: stdout)
        case MLXWorkerCommand.load:
            await handleLoad(cmd, to: stdout)
        case MLXWorkerCommand.generate:
            await handleGenerate(cmd, to: stdout)
        case MLXWorkerCommand.shutdown:
            // Ответ goodbye пишем уже в run() после возврата.
            container = nil
            MLX.Memory.clearCache()
        default:
            Self.write(.init(event: MLXWorkerEvent.error, requestId: cmd.requestId, message: "unknown cmd: \(cmd.cmd)"), to: stdout)
        }
    }

    private func handleLoad(_ cmd: MLXWorkerCommand, to stdout: FileHandle) async {
        guard let path = cmd.path else {
            Self.write(.init(event: MLXWorkerEvent.error, requestId: cmd.requestId, message: "missing path"), to: stdout)
            return
        }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              isDir.boolValue
        else {
            Self.write(.init(event: MLXWorkerEvent.error, requestId: cmd.requestId, message: "not a directory: \(url.path)"), to: stdout)
            return
        }

        if !memoryLimitApplied {
            let physical = Int(ProcessInfo.processInfo.physicalMemory)
            MLX.Memory.memoryLimit = max(2 << 30, physical * 6 / 10)
            memoryLimitApplied = true
        }

        do {
            container = try await LLMModelFactory.shared.loadContainer(
                from: url,
                using: #huggingFaceTokenizerLoader()
            )
            loadedPath = url.path
            log.notice("model loaded: \(url.path, privacy: .public)")
            Self.write(.init(event: MLXWorkerEvent.ready, requestId: cmd.requestId, modelPath: url.path), to: stdout)
        } catch {
            Self.write(.init(event: MLXWorkerEvent.error, requestId: cmd.requestId, message: error.localizedDescription), to: stdout)
        }
    }

    private func handleGenerate(_ cmd: MLXWorkerCommand, to stdout: FileHandle) async {
        guard let container else {
            Self.write(.init(event: MLXWorkerEvent.error, requestId: cmd.requestId, message: "model not loaded"), to: stdout)
            return
        }
        guard let prompt = cmd.prompt else {
            Self.write(.init(event: MLXWorkerEvent.error, requestId: cmd.requestId, message: "missing prompt"), to: stdout)
            return
        }
        let maxTokens = cmd.maxTokens ?? 200
        let temperature = Float(cmd.temperature ?? 0.7)

        do {
            let lmInput = try await container.prepare(input: UserInput(prompt: .text(prompt)))
            let params = GenerateParameters(maxTokens: maxTokens, temperature: temperature)
            let stream = try await container.generate(input: lmInput, parameters: params)
            for await event in stream {
                if case let .chunk(text) = event {
                    Self.write(.init(event: MLXWorkerEvent.chunk, requestId: cmd.requestId, text: text), to: stdout)
                }
            }
            Self.write(.init(event: MLXWorkerEvent.done, requestId: cmd.requestId), to: stdout)
        } catch {
            Self.write(.init(event: MLXWorkerEvent.error, requestId: cmd.requestId, message: error.localizedDescription), to: stdout)
        }
    }

    nonisolated private static func write(_ event: MLXWorkerEvent, to fh: FileHandle) {
        guard var data = try? JSONEncoder().encode(event) else { return }
        data.append(0x0A)
        fh.write(data)
    }
}
