import Darwin
import Foundation

public enum IPCClientError: Error, Sendable, CustomStringConvertible {
    case socketCreation(Int32)
    case connect(Int32, path: String)
    case write(Int32)
    case read(Int32)
    case noResponse
    case decode(String)
    case pathTooLong(String)

    public var description: String {
        switch self {
        case let .socketCreation(e): return "socket() failed: errno=\(e)"
        case let .connect(e, p): return "connect(\(p)) failed: errno=\(e)"
        case let .write(e): return "write() failed: errno=\(e)"
        case let .read(e): return "read() failed: errno=\(e)"
        case .noResponse: return "no newline-terminated response from daemon"
        case let .decode(m): return "could not decode response: \(m)"
        case let .pathTooLong(p): return "socket path too long for sockaddr_un: \(p)"
        }
    }
}

/// Клиент к `IPCServer`-у демона. Однократный запрос ↔ один JSON-ответ.
/// Используется MenuBar-приложением и любыми внешними тулзами на Swift.
public actor IPCClient {
    public let socketPath: String

    public init(socketPath: String = FroggyConfig.defaultSocketPath) {
        self.socketPath = socketPath
    }

    public func send(_ request: IPCRequest, timeout: Duration = .seconds(30)) async throws -> IPCResponse {
        let path = socketPath
        return try await withThrowingTaskGroup(of: IPCResponse.self) { group in
            group.addTask {
                try Self.synchronousSend(request: request, socketPath: path)
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw IPCClientError.noResponse
            }
            // Берём первый исход и отменяем оставшийся таск.
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    // MARK: - Convenience

    public func status() async throws -> IPCResponse {
        try await send(IPCRequest(cmd: "status"))
    }

    public func generate(prompt: String, maxTokens: Int? = nil) async throws -> IPCResponse {
        try await send(IPCRequest(cmd: "generate", prompt: prompt, maxTokens: maxTokens))
    }

    public func context(maxChars: Int? = nil) async throws -> IPCResponse {
        try await send(IPCRequest(cmd: "context", maxChars: maxChars))
    }

    public func loadModel(path: String) async throws -> IPCResponse {
        try await send(IPCRequest(cmd: "loadModel", path: path))
    }

    public func accessors() async throws -> IPCResponse {
        try await send(IPCRequest(cmd: "accessors"))
    }

    public func snapshot(accessorId: String) async throws -> IPCResponse {
        try await send(IPCRequest(cmd: "snapshot", accessor: accessorId))
    }

    public func unloadModel() async throws -> IPCResponse {
        try await send(IPCRequest(cmd: "unloadModel"))
    }

    public func freeze(pid: Int32) async throws -> IPCResponse {
        try await send(IPCRequest(cmd: "freeze", pid: pid))
    }

    public func thawAll() async throws -> IPCResponse {
        try await send(IPCRequest(cmd: "thawAll"))
    }

    // MARK: - BSD socket plumbing

    nonisolated private static func synchronousSend(
        request: IPCRequest, socketPath: String
    ) throws -> IPCResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { throw IPCClientError.socketCreation(errno) }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard bytes.count <= maxLen else {
            throw IPCClientError.pathTooLong(socketPath)
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { tp in
            tp.withMemoryRebound(to: CChar.self, capacity: maxLen + 1) { cp in
                for (i, b) in bytes.enumerated() { cp[i] = CChar(b) }
                cp[bytes.count] = 0
            }
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc < 0 { throw IPCClientError.connect(errno, path: socketPath) }

        var data = try JSONEncoder().encode(request)
        data.append(0x0A)
        let written = data.withUnsafeBytes { ptr -> Int in
            guard let base = ptr.baseAddress else { return 0 }
            var w = 0
            while w < ptr.count {
                let n = write(fd, base.advanced(by: w), ptr.count - w)
                if n <= 0 { return w }
                w += n
            }
            return w
        }
        if written != data.count { throw IPCClientError.write(errno) }

        var collected = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while !collected.contains(0x0A) {
            let n = buf.withUnsafeMutableBufferPointer { p in
                read(fd, p.baseAddress, p.count)
            }
            if n == 0 { break }
            if n < 0 { throw IPCClientError.read(errno) }
            collected.append(contentsOf: buf.prefix(n))
        }
        guard let nl = collected.firstIndex(of: 0x0A) else {
            throw IPCClientError.noResponse
        }
        let line = collected.subdata(in: 0..<nl)
        do {
            return try JSONDecoder().decode(IPCResponse.self, from: line)
        } catch {
            throw IPCClientError.decode(String(describing: error))
        }
    }
}
