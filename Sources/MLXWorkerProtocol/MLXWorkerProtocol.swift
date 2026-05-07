import Foundation

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

    public init(
        cmd: String,
        path: String? = nil,
        prompt: String? = nil,
        maxTokens: Int? = nil,
        temperature: Double? = nil,
        kvBits: Int? = nil,
        requestId: String? = nil
    ) {
        self.cmd = cmd
        self.path = path
        self.prompt = prompt
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.kvBits = kvBits
        self.requestId = requestId
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

    public init(
        event: String,
        requestId: String? = nil,
        text: String? = nil,
        message: String? = nil,
        modelPath: String? = nil
    ) {
        self.event = event
        self.requestId = requestId
        self.text = text
        self.message = message
        self.modelPath = modelPath
    }

    public static let ready = "ready"
    public static let error = "error"
    public static let chunk = "chunk"
    public static let done = "done"
    public static let goodbye = "goodbye"
    public static let pong = "pong"
}
