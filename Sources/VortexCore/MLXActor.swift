import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import Tokenizers
import os

public enum MLXActorError: Error, Sendable, CustomStringConvertible {
    case modelNotLoaded
    case loadFailed(String)

    public var description: String {
        switch self {
        case .modelNotLoaded: return "MLX model is not loaded"
        case let .loadFailed(reason): return "MLX load failed: \(reason)"
        }
    }
}

/// MLX-инференс на Apple Silicon. Все мутации `container` — через actor.
public actor MLXActor {
    private static let log = Logger(subsystem: "com.froggychips.froggy", category: "mlx")
    private static let signposter = OSSignposter(subsystem: "com.froggychips.froggy", category: "mlx")

    private var container: ModelContainer?
    private var loadedModelPath: String?
    private var memoryLimitApplied = false
    private let memoryLimitBytes: Int

    /// - Parameter memoryLimitBytes: верхняя граница GPU-памяти в байтах.
    ///   По умолчанию 60% physical RAM, чтобы оставить место системе.
    public init(memoryLimitBytes: Int? = nil) {
        let physical = Int(ProcessInfo.processInfo.physicalMemory)
        self.memoryLimitBytes = memoryLimitBytes ?? max(2 << 30, physical * 6 / 10)
        // Не трогаем `MLX.Memory.memoryLimit` в init — это тянет MLX
        // runtime, и в parallel-xctest без metallib падает с "library not
        // found". Применим лимит непосредственно перед `loadContainer`.
    }

    /// Загрузка модели из локальной директории (HuggingFace-репо в формате MLX).
    public func loadModel(modelPath: String) async throws {
        let interval = Self.signposter.beginInterval("loadModel")
        defer { Self.signposter.endInterval("loadModel", interval) }

        if !memoryLimitApplied {
            MLX.Memory.memoryLimit = memoryLimitBytes
            memoryLimitApplied = true
        }

        let url = URL(fileURLWithPath: modelPath, isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              isDir.boolValue
        else {
            throw MLXActorError.loadFailed("not a directory: \(url.path)")
        }
        do {
            self.container = try await LLMModelFactory.shared.loadContainer(
                from: url,
                using: #huggingFaceTokenizerLoader()
            )
            self.loadedModelPath = url.path
            Self.log.info("loaded model at \(url.path, privacy: .public)")
        } catch {
            throw MLXActorError.loadFailed(error.localizedDescription)
        }
    }

    public func unloadModel() {
        container = nil
        loadedModelPath = nil
        MLX.Memory.clearCache()
    }

    public func isLoaded() -> Bool { container != nil }

    public func currentModelPath() -> String? { loadedModelPath }

    /// Сгенерировать полный ответ (one-shot). Бросает `MLXActorError.modelNotLoaded`,
    /// если `loadModel` не вызывался.
    public func generate(prompt: String, maxTokens: Int = 200) async throws -> String {
        var output = ""
        for try await chunk in generateStream(prompt: prompt, maxTokens: maxTokens) {
            output += chunk
        }
        return output
    }

    /// Streaming-вариант: возвращает `AsyncThrowingStream`, в который
    /// токены попадают по мере генерации. Отмена внешней Task → прерывание.
    public nonisolated func generateStream(
        prompt: String,
        maxTokens: Int = 200
    ) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.runGeneration(
                        prompt: prompt,
                        maxTokens: maxTokens,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runGeneration(
        prompt: String,
        maxTokens: Int,
        continuation: AsyncThrowingStream<String, any Error>.Continuation
    ) async throws {
        guard let container else { throw MLXActorError.modelNotLoaded }
        let interval = Self.signposter.beginInterval("generate")
        defer { Self.signposter.endInterval("generate", interval) }

        let lmInput = try await container.prepare(
            input: UserInput(prompt: .text(prompt))
        )
        let params = GenerateParameters(maxTokens: maxTokens, temperature: 0.7)
        let stream = try await container.generate(input: lmInput, parameters: params)

        for await event in stream {
            if Task.isCancelled { break }
            if case let .chunk(text) = event {
                continuation.yield(text)
            }
        }
    }
}
