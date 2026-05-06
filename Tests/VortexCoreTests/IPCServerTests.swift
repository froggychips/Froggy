import Darwin
import Foundation
import XCTest
@testable import VortexCore

/// Эхо-handler — возвращает то, что пришло, плюс ok=true.
private struct EchoHandler: IPCRequestHandler {
    func handle(_ request: IPCRequest) async -> IPCResponse {
        var r = IPCResponse()
        r.ok = true
        r.text = request.cmd
        return r
    }
}

final class IPCServerTests: XCTestCase {
    func testStartAcceptHandleStop() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("froggy-ipc-\(UUID()).sock").path
        let server = IPCServer(socketPath: path, handler: EchoHandler())
        try await server.start()
        defer { Task { await server.stop() } }

        // Дождаться готовности сокета.
        try await Task.sleep(for: .milliseconds(50))

        let response = try await Self.sendRequest(
            socketPath: path, request: IPCRequest(cmd: "ping")
        )
        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(response.text, "ping")

        await server.stop()
    }

    /// Подключается к unix-socket, отправляет одну строку JSON, читает одну строку JSON.
    private static func sendRequest(
        socketPath: String, request: IPCRequest
    ) async throws -> IPCResponse {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<IPCResponse, Error>) in
            DispatchQueue.global().async {
                let fd = socket(AF_UNIX, SOCK_STREAM, 0)
                guard fd >= 0 else {
                    cont.resume(throwing: NSError(domain: "ipc", code: 1))
                    return
                }
                defer { close(fd) }

                var addr = sockaddr_un()
                addr.sun_family = sa_family_t(AF_UNIX)
                let bytes = Array(socketPath.utf8)
                let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
                guard bytes.count <= maxLen else {
                    cont.resume(throwing: NSError(domain: "ipc", code: 2))
                    return
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
                if rc < 0 {
                    cont.resume(throwing: NSError(domain: "ipc", code: 3, userInfo: [NSLocalizedDescriptionKey: "connect errno=\(errno)"]))
                    return
                }
                do {
                    var data = try JSONEncoder().encode(request)
                    data.append(0x0A)
                    _ = data.withUnsafeBytes { ptr -> Int in
                        guard let base = ptr.baseAddress else { return 0 }
                        return write(fd, base, ptr.count)
                    }
                    var buf = [UInt8](repeating: 0, count: 4096)
                    var collected = Data()
                    while true {
                        let n = buf.withUnsafeMutableBufferPointer { p in
                            read(fd, p.baseAddress, p.count)
                        }
                        if n <= 0 { break }
                        collected.append(contentsOf: buf.prefix(n))
                        if collected.contains(0x0A) { break }
                    }
                    if let nl = collected.firstIndex(of: 0x0A) {
                        let line = collected.subdata(in: 0..<nl)
                        let resp = try JSONDecoder().decode(IPCResponse.self, from: line)
                        cont.resume(returning: resp)
                    } else {
                        cont.resume(throwing: NSError(domain: "ipc", code: 4, userInfo: [NSLocalizedDescriptionKey: "no newline in response"]))
                    }
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }
}
