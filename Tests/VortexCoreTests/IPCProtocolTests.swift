import XCTest
@testable import VortexCore

final class IPCProtocolTests: XCTestCase {
    func testRequestRoundTrip() throws {
        let req = IPCRequest(cmd: "generate", prompt: "hello", maxTokens: 50, pid: nil)
        let data = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(IPCRequest.self, from: data)
        XCTAssertEqual(decoded.cmd, "generate")
        XCTAssertEqual(decoded.prompt, "hello")
        XCTAssertEqual(decoded.maxTokens, 50)
        XCTAssertNil(decoded.pid)
    }

    func testResponseFailureFactory() throws {
        let r = IPCResponse.failure("boom")
        XCTAssertEqual(r.ok, false)
        XCTAssertEqual(r.error, "boom")
    }

    func testResponseSuccessFactory() throws {
        let r = IPCResponse.success()
        XCTAssertEqual(r.ok, true)
        XCTAssertNil(r.error)
    }

    func testResponseStatusRoundTrip() throws {
        var r = IPCResponse()
        r.ok = true
        r.capturing = true
        r.modelLoaded = false
        r.memoryPressure = 42
        r.frozen = 3
        let data = try JSONEncoder().encode(r)
        let decoded = try JSONDecoder().decode(IPCResponse.self, from: data)
        XCTAssertEqual(decoded.capturing, true)
        XCTAssertEqual(decoded.memoryPressure, 42)
        XCTAssertEqual(decoded.frozen, 3)
    }

    // EXP-1: фильтр и descriptor-флаг должны переживать JSON-roundtrip,
    // иначе старые/новые клиенты не договорятся.
    func testRequestExperimentalFilterRoundTrip() throws {
        let req = IPCRequest(cmd: "accessors", experimental: true)
        let data = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(IPCRequest.self, from: data)
        XCTAssertEqual(decoded.cmd, "accessors")
        XCTAssertEqual(decoded.experimental, true)
    }

    func testRequestWithoutExperimentalFilterIsNil() throws {
        // Backward-compat: клиенты, не присылающие поле, должны
        // декодироваться в `experimental == nil` (no filter).
        let json = #"{"cmd":"accessors"}"#
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(IPCRequest.self, from: data)
        XCTAssertNil(decoded.experimental)
    }

    func testAccessorDescriptorRoundTripWithExperimentalFlag() throws {
        var r = IPCResponse()
        r.ok = true
        r.accessors = [
            IPCResponse.Accessor(id: "core", name: "Core"),
            IPCResponse.Accessor(id: "exp", name: "Exp", experimental: true),
        ]
        let data = try JSONEncoder().encode(r)
        let decoded = try JSONDecoder().decode(IPCResponse.self, from: data)
        XCTAssertEqual(decoded.accessors?.count, 2)
        XCTAssertNil(decoded.accessors?[0].experimental)
        XCTAssertEqual(decoded.accessors?[1].experimental, true)
    }
}
