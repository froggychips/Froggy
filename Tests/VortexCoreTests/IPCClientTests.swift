import Foundation
import XCTest
@testable import VortexCore

private struct CountingHandler: IPCRequestHandler {
    func handle(_ request: IPCRequest) async -> IPCResponse {
        var r = IPCResponse()
        switch request.cmd {
        case "status":
            r.ok = true
            r.modelLoaded = true
            r.modelPath = "/echo/path"
            return r
        case "loadModel":
            guard let path = request.path else { return .failure("missing path") }
            r.ok = true
            r.modelPath = path
            return r
        case "accessors":
            r.ok = true
            r.accessors = [.init(id: "ocr", name: "Screen OCR")]
            return r
        case "snapshot":
            r.ok = true
            r.lines = ["snap-of-\(request.accessor ?? "")"]
            return r
        default:
            return .failure("unknown cmd: \(request.cmd)")
        }
    }
}

final class IPCClientTests: XCTestCase {
    private func runWithServer(_ body: (String) async throws -> Void) async throws {
        // sockaddr_un.sun_path is 104 bytes on Darwin, so /tmp + short uuid stays well under.
        let path = "/tmp/froggy-c-\(UUID().uuidString.prefix(8)).sock"
        let server = IPCServer(socketPath: path, handler: CountingHandler())
        try await server.start()
        defer { Task { await server.stop() } }
        try await Task.sleep(for: .milliseconds(50))
        try await body(path)
        await server.stop()
    }

    func testStatusRoundTrip() async throws {
        try await runWithServer { path in
            let client = IPCClient(socketPath: path)
            let r = try await client.status()
            XCTAssertEqual(r.ok, true)
            XCTAssertEqual(r.modelLoaded, true)
            XCTAssertEqual(r.modelPath, "/echo/path")
        }
    }

    func testLoadModelEchoesPath() async throws {
        try await runWithServer { path in
            let client = IPCClient(socketPath: path)
            let r = try await client.loadModel(path: "/Users/me/models/x")
            XCTAssertEqual(r.ok, true)
            XCTAssertEqual(r.modelPath, "/Users/me/models/x")
        }
    }

    func testAccessorsAndSnapshot() async throws {
        try await runWithServer { path in
            let client = IPCClient(socketPath: path)
            let list = try await client.accessors()
            XCTAssertEqual(list.accessors?.count, 1)
            XCTAssertEqual(list.accessors?.first?.id, "ocr")

            let snap = try await client.snapshot(accessorId: "ocr")
            XCTAssertEqual(snap.lines, ["snap-of-ocr"])
        }
    }

    func testUnknownCommandReturnsFailure() async throws {
        try await runWithServer { path in
            let client = IPCClient(socketPath: path)
            let r = try await client.send(IPCRequest(cmd: "nope"))
            XCTAssertEqual(r.ok, false)
            XCTAssertNotNil(r.error)
        }
    }

    func testConnectFailsForMissingSocket() async {
        let client = IPCClient(socketPath: "/tmp/froggy-does-not-exist-\(UUID()).sock")
        do {
            _ = try await client.status()
            XCTFail("should have thrown")
        } catch is IPCClientError {
            // ok
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }
}
