import Darwin
import Foundation
import os

public enum IPCServerError: Error, Sendable, CustomStringConvertible {
    case socketCreationFailed(Int32)
    case bindFailed(Int32, path: String)
    case listenFailed(Int32)
    case pathTooLong(String)
    case alreadyRunning(path: String)

    public var description: String {
        switch self {
        case let .socketCreationFailed(e): return "socket() failed: errno=\(e)"
        case let .bindFailed(e, path): return "bind(\(path)) failed: errno=\(e)"
        case let .listenFailed(e): return "listen() failed: errno=\(e)"
        case let .pathTooLong(p): return "socket path too long for sockaddr_un (104 bytes max): \(p)"
        case let .alreadyRunning(p): return "another daemon is already listening on \(p)"
        }
    }
}

/// Unix-domain-socket сервер с line-protocol JSON.
/// One-shot: один JSON-запрос → один JSON-ответ.
/// Streaming: handler возвращает `AsyncThrowingStream`, сервер шлёт несколько
/// JSON-строк, последняя имеет `final == true`.
public actor IPCServer {
    private static let log = Logger(subsystem: "com.froggychips.froggy", category: "ipc")
    /// POI-канал — Instruments автоматически рендерит это в Points of
    /// Interest track'е. Используется для IPC roundtrip overlay'я.
    private static let poi = OSSignposter(subsystem: "com.froggychips.froggy", category: "PointsOfInterest")

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

        // Проверяем, не занят ли уже сокет другим демоном — если можем
        // подключиться, значит кто-то слушает. unlink того файла оторвал бы
        // живой сервер.
        if Self.canConnect(to: socketPath) {
            throw IPCServerError.alreadyRunning(path: socketPath)
        }
        // Stale-сокет (файл есть, но никто не слушает) можно сносить.
        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { throw IPCServerError.socketCreationFailed(errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
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
        chmod(socketPath, 0o600)

        if Darwin.listen(fd, 32) < 0 {
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
            // shutdown() выведет блокирующий accept(2) с EINVAL/ECONNABORTED,
            // иначе detached task будет залипать в ядре до сигнала.
            shutdown(serverFd, SHUT_RDWR)
            close(serverFd)
            serverFd = -1
        }
        unlink(socketPath)
    }

    // MARK: - Helpers

    nonisolated private static func canConnect(to path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard bytes.count <= maxLen else { return false }
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
        return rc == 0
    }

    // MARK: - Accept loop

    private static func acceptLoop(
        fd: Int32, path: String, handler: any IPCRequestHandler
    ) async {
        while !Task.isCancelled {
            var client = sockaddr()
            var len = socklen_t(MemoryLayout<sockaddr>.size)
            let cfd = Darwin.accept(fd, &client, &len)
            if cfd < 0 {
                let e = errno
                if e == EINTR { continue }
                // EBADF/EINVAL — наш собственный shutdown/close.
                // ECONNABORTED — прервал клиент в момент handshake; продолжаем.
                if e == EBADF || e == EINVAL { break }
                if e == ECONNABORTED { continue }
                Self.log.warning("accept failed: errno=\(e)")
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
            // Срезаем все полные строки, что есть в буфере.
            while let nl = buffer.firstIndex(of: 0x0A) {
                // `firstIndex` возвращает индекс относительно текущего
                // startIndex, который у Data после mutations может быть
                // не нулевым. Считаем смещение через distance().
                let endOffset = buffer.distance(from: buffer.startIndex, to: nl)
                let line = Data(buffer.prefix(endOffset))
                buffer.removeSubrange(buffer.startIndex...nl)
                await processLine(line: line, fd: fd, handler: handler)
            }
        }
    }

    private static func processLine(
        line: Data, fd: Int32, handler: any IPCRequestHandler
    ) async {
        guard let req = try? JSONDecoder().decode(IPCRequest.self, from: line) else {
            writeJSONLine(.failure("malformed request"), to: fd)
            return
        }
        // POI: один interval на весь IPC roundtrip — от parse'а до response-write.
        // Streaming запросы тоже укладываются в один interval — от parse до
        // final-chunk'а. В Instruments видно cmd → длительность.
        let poiId = poi.makeSignpostID()
        let poiState = poi.beginInterval("ipc_request", id: poiId, "cmd=\(req.cmd)")
        defer { poi.endInterval("ipc_request", poiState, "cmd=\(req.cmd)") }

        // Streaming-путь, если handler его реализует.
        if let stream = handler.handleStream(req) {
            do {
                for try await chunk in stream {
                    writeJSONLine(chunk, to: fd)
                    if chunk.final == true { return }
                }
                // Stream закончился без явного `final` — отправим завершающий маркер.
                var trailer = IPCResponse()
                trailer.ok = true
                trailer.final = true
                writeJSONLine(trailer, to: fd)
            } catch {
                writeJSONLine(.failure(String(describing: error)), to: fd)
            }
            return
        }
        // One-shot путь.
        let response = await handler.handle(req)
        writeJSONLine(response, to: fd)
    }

    private static func writeJSONLine(_ response: IPCResponse, to fd: Int32) {
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
