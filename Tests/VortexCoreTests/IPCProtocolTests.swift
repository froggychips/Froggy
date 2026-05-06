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
}
