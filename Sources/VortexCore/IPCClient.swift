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

/// Клиент к `IPCServer`-у демона. One-shot send + streaming поверх AF_UNIX.
public actor IPCClient {
    public let socketPath: String

    public init(socketPath: String = FroggyConfig.defaultSocketPath) {
        self.socketPath = socketPath
    }

    /// One-shot. Ставит SO_RCVTIMEO/SO_SNDTIMEO на сокет — это гасит баг
    /// «таймаут сработал, но blocking syscall всё ещё держит fd».
    public func send(_ request: IPCRequest, timeout: Duration = .seconds(30)) async throws -> IPCResponse {
        let path = socketPath
        let timeoutSeconds = max(0.1, timeout.toSeconds)
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<IPCResponse, any Error>) in
            Task.detached {
                do {
                    var capturedResponse: IPCResponse?
                    try Self.synchronousSendStream(
                        request: request,
                        socketPath: path,
                        timeoutSeconds: timeoutSeconds
                    ) { response in
                        capturedResponse = response
                        return true // one-shot — после первого ответа всегда выходим
                    }
                    if let r = capturedResponse {
                        cont.resume(returning: r)
                    } else {
                        cont.resume(throwing: IPCClientError.noResponse)
                    }
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Streaming. Возвращает stream `IPCResponse`-ов; каждый — одна
    /// JSON-строка от сервера. Заканчивается, когда приходит chunk с
    /// `final == true`, либо сервер закрывает соединение.
    public nonisolated func sendStream(
        _ request: IPCRequest,
        timeout: Duration = .seconds(300)
    ) -> AsyncThrowingStream<IPCResponse, any Error> {
        let path = socketPath
        let timeoutSeconds = max(0.1, timeout.toSeconds)
        return AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    try Self.synchronousSendStream(
                        request: request,
                        socketPath: path,
                        timeoutSeconds: timeoutSeconds
                    ) { response in
                        continuation.yield(response)
                        return response.final == true
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Convenience

    public func status() async throws -> IPCResponse {
        try await send(IPCRequest(cmd: "status"))
    }

    public func generate(
        prompt: String,
        maxTokens: Int? = nil,
        useContext: Bool? = nil
    ) async throws -> IPCResponse {
        try await send(
            IPCRequest(
                cmd: "generate", prompt: prompt, maxTokens: maxTokens, useContext: useContext
            ),
            timeout: .seconds(300)
        )
    }

    /// Streaming-генерация: stream строк-токенов.
    public nonisolated func generateStream(
        prompt: String,
        maxTokens: Int? = nil,
        useContext: Bool? = nil
    ) -> AsyncThrowingStream<String, any Error> {
        let req = IPCRequest(
            cmd: "generate", prompt: prompt, maxTokens: maxTokens, useContext: useContext
        )
        let upstream = sendStream(req)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await response in upstream {
                        if let text = response.text { continuation.yield(text) }
                        if response.final == true { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func context(maxChars: Int? = nil) async throws -> IPCResponse {
        try await send(IPCRequest(cmd: "context", maxChars: maxChars))
    }

    public func loadModel(path: String) async throws -> IPCResponse {
        try await send(IPCRequest(cmd: "loadModel", path: path), timeout: .seconds(600))
    }

    /// Список зарегистрированных аксессоров. `experimental: true` —
    /// только опытные (target `LushaExperimental`), `false` — только
    /// core (`LushaBridge`), `nil` — все.
    public func accessors(experimental: Bool? = nil) async throws -> IPCResponse {
        try await send(IPCRequest(cmd: "accessors", experimental: experimental))
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

    /// Открывает соединение, отправляет один запрос, читает строку-за-строкой.
    /// Для каждой полученной строки вызывает `onResponse`. Если callback
    /// возвращает true — завершаем (one-shot или final-маркер).
    nonisolated fileprivate static func synchronousSendStream(
        request: IPCRequest,
        socketPath: String,
        timeoutSeconds: Double,
        onResponse: (IPCResponse) -> Bool
    ) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { throw IPCClientError.socketCreation(errno) }
        defer { close(fd) }

        // SO_RCVTIMEO + SO_SNDTIMEO — гарантия, что blocking syscalls
        // не залипнут навсегда, даже если демон умолк.
        let secs = Int(timeoutSeconds)
        let usecs = Int32((timeoutSeconds - Double(secs)) * 1_000_000)
        var tv = timeval(tv_sec: secs, tv_usec: usecs)
        _ = withUnsafePointer(to: &tv) { ptr in
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
        }
        _ = withUnsafePointer(to: &tv) { ptr in
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
        }

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
        var writeErrno: Int32 = 0
        let written = data.withUnsafeBytes { ptr -> Int in
            guard let base = ptr.baseAddress else { return 0 }
            var w = 0
            while w < ptr.count {
                let n = write(fd, base.advanced(by: w), ptr.count - w)
                if n <= 0 { writeErrno = errno; return w }
                w += n
            }
            return w
        }
        if written != data.count { throw IPCClientError.write(writeErrno) }

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while !Task.isCancelled {
            let n = chunk.withUnsafeMutableBufferPointer { ptr -> Int in
                read(fd, ptr.baseAddress, ptr.count)
            }
            if n == 0 { return } // EOF
            if n < 0 { throw IPCClientError.read(errno) }
            buffer.append(contentsOf: chunk.prefix(n))

            while let nl = buffer.firstIndex(of: 0x0A) {
                let endOffset = buffer.distance(from: buffer.startIndex, to: nl)
                let line = Data(buffer.prefix(endOffset))
                buffer.removeSubrange(buffer.startIndex...nl)
                let response: IPCResponse
                do {
                    response = try JSONDecoder().decode(IPCResponse.self, from: line)
                } catch {
                    throw IPCClientError.decode(String(describing: error))
                }
                let stop = onResponse(response)
                if stop { return }
            }
        }
    }
}

private extension Duration {
    var toSeconds: Double {
        let comp = components
        return Double(comp.seconds) + Double(comp.attoseconds) / 1e18
    }
}
