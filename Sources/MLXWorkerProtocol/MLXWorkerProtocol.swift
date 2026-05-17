import Foundation

/// Wire-protocol версия для daemon↔FroggyMLXWorker (issue #57, ADR-0003).
/// Bump при breaking-изменении формата команд или событий. Не bump'ить
/// при добавлении опциональных полей — Codable forward-compat покрывает их
/// сам через `decodeIfPresent`. Mismatch определяется на consumer-стороне
/// (`MLXSupervisor`) и логируется как warning, не fatal — для сценария
/// «новый daemon + старый ручной worker через `mlxWorkerPath`».
public enum MLXWireVersion {
    public static let current: Int = 1
}

/// Команда от демона к `FroggyMLXWorker`. Одна JSON-строка на stdin.
public struct MLXWorkerCommand: Codable, Sendable {
    public var cmd: String
    public var path: String?
    public var prompt: String?
    public var maxTokens: Int?
    public var temperature: Double?
    /// Биты KV-cache квантизации: 16 (без квантизации), 8, 4. Передаётся
    /// также CLI-флагом `--kv-bits`, и команда per-request переопределяет
    /// дефолт worker'a.
    public var kvBits: Int?
    public var requestId: String?
    /// См. `MLXWireVersion`. Опциональный для backwards-compat: старые
    /// клиенты без поля декодятся (через `decodeIfPresent` в Codable),
    /// новые при создании получают `current` по дефолту.
    public var apiVersion: Int?

    public init(
        cmd: String,
        path: String? = nil,
        prompt: String? = nil,
        maxTokens: Int? = nil,
        temperature: Double? = nil,
        kvBits: Int? = nil,
        requestId: String? = nil,
        apiVersion: Int? = MLXWireVersion.current
    ) {
        self.cmd = cmd
        self.path = path
        self.prompt = prompt
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.kvBits = kvBits
        self.requestId = requestId
        self.apiVersion = apiVersion
    }

    public static let load = "load"
    public static let generate = "generate"
    public static let shutdown = "shutdown"
    public static let ping = "ping"
}

/// Событие от worker'а к демону. Одна JSON-строка на stdout.
public struct MLXWorkerEvent: Codable, Sendable {
    public var event: String
    public var requestId: String?
    /// Только для `chunk`.
    public var text: String?
    /// Только для `error`.
    public var message: String?
    /// Для `done` — путь модели после `load`-ack.
    public var modelPath: String?
    /// Для `done` после generate — метрики из GenerateCompletionInfo.
    public var promptTPS: Double?
    public var decodeTPS: Double?
    public var promptTokens: Int?
    public var generatedTokens: Int?
    /// См. `MLXWireVersion`. Опциональное; legacy worker'ы шлют nil.
    public var apiVersion: Int?

    public init(
        event: String,
        requestId: String? = nil,
        text: String? = nil,
        message: String? = nil,
        modelPath: String? = nil,
        promptTPS: Double? = nil,
        decodeTPS: Double? = nil,
        promptTokens: Int? = nil,
        generatedTokens: Int? = nil,
        apiVersion: Int? = MLXWireVersion.current
    ) {
        self.event = event
        self.requestId = requestId
        self.text = text
        self.message = message
        self.modelPath = modelPath
        self.promptTPS = promptTPS
        self.decodeTPS = decodeTPS
        self.promptTokens = promptTokens
        self.generatedTokens = generatedTokens
        self.apiVersion = apiVersion
    }

    public static let ready = "ready"
    public static let error = "error"
    public static let chunk = "chunk"
    public static let done = "done"
    public static let goodbye = "goodbye"
    public static let pong = "pong"
}
