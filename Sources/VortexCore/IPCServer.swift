import Darwin
import Foundation
import os

public enum IPCServerError: Error, Sendable, CustomStringConvertible {
    case socketCreationFailed(Int32)
    case bindFailed(Int32, path: String)
    case listenFailed(Int32)
    case pathTooLong(String)

    public var description: String {
        switch self {
        case let .socketCreationFailed(e): return "socket() failed: errno=\(e)"
        case let .bindFailed(e, path): return "bind(\(path)) failed: errno=\(e)"
        case let .listenFailed(e): return "listen() failed: errno=\(e)"
        case let .pathTooLong(p): return "socket path too long for sockaddr_un (104 bytes max): \(p)"
        }
    }
}

/// Unix-domain-socket сервер с line-protocol JSON.
/// Каждая строка от клиента — `IPCRequest`, ответ — одна строка `IPCResponse` + `\n`.
public actor IPCServer {
    private static let log = Logger(subsystem: "com.froggychips.froggy", category: "ipc")

    private let socketPath: String
    private let handler: any IPCRequestHandler
    private var serverFd: Int32 = -1
    private var acceptTask: Task<Void, Never>?

    public init(socketPath: String, handler: any IPCRequestHandler) {
        self.socketPath = socketPath
        self.handler = handler
    }

    /// Открывает сокет и запускает accept-цикл в отдельной Task.
    /// Метод неблокирующий — возвращается сразу.
    public func start() throws {
        guard serverFd < 0 else { return }
        // Снести stale-сокет если есть.
        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { throw IPCServerError.socketCreationFailed(errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        // sun_path — фиксированный массив 104 байта (включая \0).
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard pathBytes.count <= maxLen else {
            close(fd)
            throw IPCServerError.pathTooLong(socketPath)
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
            tuplePtr.withMemoryRebound(to: CChar.self, capacity: maxLen + 1) { cp in
                for (i, b) in pathBytes.enumerated() { cp[i] = CChar(b) }
                cp[pathBytes.count] = 0
            }
        }

        let bindRC = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if bindRC < 0 {
            let e = errno
            close(fd)
            throw IPCServerError.bindFailed(e, path: socketPath)
        }
        // Только владелец может разговаривать с сокетом.
        chmod(socketPath, 0o600)

        if Darwin.listen(fd, 8) < 0 {
            let e = errno
            close(fd)
            throw IPCServerError.listenFailed(e)
        }

        serverFd = fd
        let path = socketPath
        let h = handler
        acceptTask = Task.detached { [fd] in
            await IPCServer.acceptLoop(fd: fd, path: path, handler: h)
        }
        Self.log.info("listening on \(path, privacy: .public)")
    }

    public func stop() {
        acceptTask?.cancel()
        if serverFd >= 0 {
            close(serverFd)
            serverFd = -1
        }
        unlink(socketPath)
    }

    // MARK: - Private (nonisolated, чтобы крутиться в detached Task)

    private static func acceptLoop(
        fd: Int32, path: String, handler: any IPCRequestHandler
    ) async {
        while !Task.isCancelled {
            var client = sockaddr()
            var len = socklen_t(MemoryLayout<sockaddr>.size)
            let cfd = Darwin.accept(fd, &client, &len)
            if cfd < 0 {
                if errno == EINTR { continue }
                if errno == EBADF { break } // socket closed
                Self.log.warning("accept failed: errno=\(errno)")
                break
            }
            let h = handler
            Task.detached {
                await IPCServer.handleConnection(fd: cfd, handler: h)
            }
        }
        Self.log.info("accept loop exited")
    }

    private static func handleConnection(fd: Int32, handler: any IPCRequestHandler) async {
        defer { close(fd) }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while !Task.isCancelled {
            let n = chunk.withUnsafeMutableBufferPointer { ptr -> Int in
                read(fd, ptr.baseAddress, ptr.count)
            }
            if n <= 0 { return }
            buffer.append(contentsOf: chunk.prefix(n))
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: 0..<nl)
                buffer.removeSubrange(0...nl)
                await processLine(line: line, fd: fd, handler: handler)
            }
        }
    }

    private static func processLine(
        line: Data, fd: Int32, handler: any IPCRequestHandler
    ) async {
        let response: IPCResponse
        if let req = try? JSONDecoder().decode(IPCRequest.self, from: line) {
            response = await handler.handle(req)
        } else {
            response = .failure("malformed request")
        }
        guard var data = try? JSONEncoder().encode(response) else { return }
        data.append(0x0A)
        _ = data.withUnsafeBytes { ptr -> Int in
            guard let base = ptr.baseAddress else { return 0 }
            var written = 0
            while written < ptr.count {
                let w = write(fd, base.advanced(by: written), ptr.count - written)
                if w <= 0 { return written }
                written += w
            }
            return written
        }
    }
}
