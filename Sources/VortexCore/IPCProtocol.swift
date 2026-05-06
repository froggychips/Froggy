import Foundation

public struct IPCRequest: Codable, Sendable {
    public var cmd: String
    public var prompt: String?
    public var maxTokens: Int?
    public var pid: Int32?
    public var maxChars: Int?
    public var path: String?
    public var accessor: String?

    public init(
        cmd: String,
        prompt: String? = nil,
        maxTokens: Int? = nil,
        pid: Int32? = nil,
        maxChars: Int? = nil,
        path: String? = nil,
        accessor: String? = nil
    ) {
        self.cmd = cmd
        self.prompt = prompt
        self.maxTokens = maxTokens
        self.pid = pid
        self.maxChars = maxChars
        self.path = path
        self.accessor = accessor
    }
}

public struct IPCResponse: Codable, Sendable {
    public var ok: Bool?
    public var error: String?
    public var text: String?
    public var capturing: Bool?
    public var modelLoaded: Bool?
    public var modelPath: String?
    public var memoryPressure: Int?
    public var frozen: Int?
    public var context: String?
    public var snapshots: Int?
    public var lines: [String]?
    public var accessors: [Accessor]?
    public var lastCaptureError: String?
    /// Маркер «это последний chunk в стриме». Для one-shot ответов — true.
    /// Для streaming-промежуточных chunk'ов — false.
    public var final: Bool?

    public init() {}

    public static func failure(_ message: String) -> IPCResponse {
        var r = IPCResponse()
        r.ok = false
        r.error = message
        r.final = true
        return r
    }

    public static func success() -> IPCResponse {
        var r = IPCResponse()
        r.ok = true
        r.final = true
        return r
    }

    /// Описание зарегистрированного Lusha-аксессора.
    public struct Accessor: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }
}

public protocol IPCRequestHandler: Sendable {
    func handle(_ request: IPCRequest) async -> IPCResponse

    /// Опциональный streaming путь: если возвращается non-nil, сервер
    /// будет писать каждый IPCResponse одной JSON-строкой и закроет
    /// соединение после chunk'a с `final == true`.
    /// Дефолтная реализация возвращает nil — handler one-shot.
    func handleStream(_ request: IPCRequest) -> AsyncThrowingStream<IPCResponse, any Error>?
}

extension IPCRequestHandler {
    public func handleStream(_ request: IPCRequest) -> AsyncThrowingStream<IPCResponse, any Error>? {
        nil
    }
}
