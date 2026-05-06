import Foundation

public struct IPCRequest: Codable, Sendable {
    public var cmd: String
    public var prompt: String?
    public var maxTokens: Int?
    public var pid: Int32?
    public var maxChars: Int?

    public init(
        cmd: String,
        prompt: String? = nil,
        maxTokens: Int? = nil,
        pid: Int32? = nil,
        maxChars: Int? = nil
    ) {
        self.cmd = cmd
        self.prompt = prompt
        self.maxTokens = maxTokens
        self.pid = pid
        self.maxChars = maxChars
    }
}

public struct IPCResponse: Codable, Sendable {
    public var ok: Bool?
    public var error: String?
    public var text: String?
    public var capturing: Bool?
    public var modelLoaded: Bool?
    public var memoryPressure: Int?
    public var frozen: Int?
    public var context: String?
    public var snapshots: Int?

    public init() {}

    public static func failure(_ message: String) -> IPCResponse {
        var r = IPCResponse()
        r.ok = false
        r.error = message
        return r
    }

    public static func success() -> IPCResponse {
        var r = IPCResponse()
        r.ok = true
        return r
    }
}

public protocol IPCRequestHandler: Sendable {
    func handle(_ request: IPCRequest) async -> IPCResponse
}
