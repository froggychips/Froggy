import Foundation
import XCTest
@testable import VortexCore

/// Хендлер, который для cmd "stream" эмитит N chunk'ов, последний — с final=true.
private struct StreamingHandler: IPCRequestHandler {
    let chunkCount: Int

    func handle(_ request: IPCRequest) async -> IPCResponse {
        if request.cmd == "ping" {
            var r = IPCResponse(); r.ok = true; r.text = "pong"; r.final = true
            return r
        }
        return .failure("non-streaming handler doesn't know '\(request.cmd)'")
    }

    func handleStream(_ request: IPCRequest) -> AsyncThrowingStream<IPCResponse, any Error>? {
        guard request.cmd == "stream" else { return nil }
        let n = chunkCount
        return AsyncThrowingStream { cont in
            Task {
                for i in 0..<n {
                    var r = IPCResponse()
                    r.ok = true
                    r.text = "chunk-\(i)"
                    r.final = false
                    cont.yield(r)
                }
                var done = IPCResponse()
                done.ok = true
                done.final = true
                cont.yield(done)
                cont.finish()
            }
        }
    }
}

final class IPCStreamingTests: XCTestCase {
    private func runWithServer(_ chunkCount: Int, _ body: (String) async throws -> Void) async throws {
        let path = "/tmp/froggy-s-\(UUID().uuidString.prefix(8)).sock"
        let server = IPCServer(socketPath: path, handler: StreamingHandler(chunkCount: chunkCount))
        try await server.start()
        defer { Task { await server.stop() } }
        try await Task.sleep(for: .milliseconds(50))
        try await body(path)
        await server.stop()
    }

    func testStreamingEmitsAllChunksThenFinal() async throws {
        try await runWithServer(3) { path in
            let client = IPCClient(socketPath: path)
            var collected: [String] = []
            var sawFinal = false
            for try await response in client.sendStream(IPCRequest(cmd: "stream")) {
                if let text = response.text { collected.append(text) }
                if response.final == true { sawFinal = true }
            }
            XCTAssertEqual(collected, ["chunk-0", "chunk-1", "chunk-2"])
            XCTAssertTrue(sawFinal)
        }
    }

    func testOneShotStillWorksOnSameServer() async throws {
        try await runWithServer(1) { path in
            let client = IPCClient(socketPath: path)
            let r = try await client.send(IPCRequest(cmd: "ping"))
            XCTAssertEqual(r.text, "pong")
            XCTAssertEqual(r.final, true)
        }
    }

    func testZeroChunksStreamStillEmitsFinal() async throws {
        try await runWithServer(0) { path in
            let client = IPCClient(socketPath: path)
            var sawFinal = false
            var nonFinalChunks = 0
            for try await response in client.sendStream(IPCRequest(cmd: "stream")) {
                if response.final == true {
                    sawFinal = true
                } else {
                    nonFinalChunks += 1
                }
            }
            XCTAssertTrue(sawFinal)
            XCTAssertEqual(nonFinalChunks, 0)
        }
    }
}
