import AudioWorkerProtocol
import MLXWorkerProtocol
import XCTest
@testable import VortexCore

/// Issue #57: forward-compat для wire-протоколов daemon↔worker / daemon↔клиент.
/// Старый JSON без `apiVersion` обязан декодиться (legacy peer), новые объекты
/// обязаны сериализоваться с `apiVersion = current`. Эти тесты — контракт,
/// который ломается, если кто-то случайно сделает поле required или забудет
/// проставить default в init.
final class WireVersionTests: XCTestCase {

    // MARK: - MLX

    func testMLXCommandDecodesLegacyJSONWithoutApiVersion() throws {
        // Поле осознанно отсутствует — это формат до issue #57.
        let json = #"{"cmd":"load","path":"/m"}"#.data(using: .utf8)!
        let cmd = try JSONDecoder().decode(MLXWorkerCommand.self, from: json)
        XCTAssertEqual(cmd.cmd, MLXWorkerCommand.load)
        XCTAssertEqual(cmd.path, "/m")
        XCTAssertNil(cmd.apiVersion, "legacy JSON без поля → apiVersion=nil")
    }

    func testMLXCommandEncodesCurrentApiVersion() throws {
        let cmd = MLXWorkerCommand(cmd: MLXWorkerCommand.ping, requestId: "r1")
        XCTAssertEqual(cmd.apiVersion, MLXWireVersion.current)
        let data = try JSONEncoder().encode(cmd)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["apiVersion"] as? Int, MLXWireVersion.current)
    }

    func testMLXEventDecodesLegacyJSONWithoutApiVersion() throws {
        let json = #"{"event":"ready","modelPath":"/m"}"#.data(using: .utf8)!
        let ev = try JSONDecoder().decode(MLXWorkerEvent.self, from: json)
        XCTAssertEqual(ev.event, MLXWorkerEvent.ready)
        XCTAssertNil(ev.apiVersion)
    }

    // MARK: - Audio

    func testAudioCommandDecodesLegacyJSONWithoutApiVersion() throws {
        let json = #"{"cmd":"startCapture"}"#.data(using: .utf8)!
        let cmd = try JSONDecoder().decode(AudioWorkerCommand.self, from: json)
        XCTAssertEqual(cmd.cmd, AudioWorkerCommand.startCapture)
        XCTAssertNil(cmd.apiVersion)
    }

    func testAudioCommandEncodesCurrentApiVersion() throws {
        let cmd = AudioWorkerCommand(cmd: AudioWorkerCommand.ping, requestId: "r1")
        XCTAssertEqual(cmd.apiVersion, AudioWireVersion.current)
        let data = try JSONEncoder().encode(cmd)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["apiVersion"] as? Int, AudioWireVersion.current)
    }

    func testAudioEventDecodesLegacyJSONWithoutApiVersion() throws {
        let json = #"{"event":"transcript","text":"hello","speaker":"mic","isFinal":true}"#.data(using: .utf8)!
        let ev = try JSONDecoder().decode(AudioWorkerEvent.self, from: json)
        XCTAssertEqual(ev.event, AudioWorkerEvent.transcript)
        XCTAssertEqual(ev.speaker, "mic")
        XCTAssertNil(ev.apiVersion)
    }

    // MARK: - IPC

    func testIPCRequestDecodesLegacyJSONWithoutApiVersion() throws {
        // Старый клиент шлёт status / generate без apiVersion.
        let json = #"{"cmd":"status"}"#.data(using: .utf8)!
        let req = try JSONDecoder().decode(IPCRequest.self, from: json)
        XCTAssertEqual(req.cmd, "status")
        XCTAssertNil(req.apiVersion)
    }

    func testIPCRequestEncodesCurrentApiVersion() throws {
        let req = IPCRequest(cmd: "status")
        XCTAssertEqual(req.apiVersion, IPCWireVersion.current)
        let data = try JSONEncoder().encode(req)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["apiVersion"] as? Int, IPCWireVersion.current)
    }

    func testIPCResponseDecodesLegacyJSONWithoutApiVersion() throws {
        // Старый daemon отвечает без apiVersion — клиент не должен ломаться.
        let json = #"{"ok":true,"modelLoaded":false}"#.data(using: .utf8)!
        let r = try JSONDecoder().decode(IPCResponse.self, from: json)
        XCTAssertEqual(r.ok, true)
        XCTAssertNil(r.apiVersion)
    }

    func testIPCResponseEncodesCurrentApiVersion() throws {
        let r = IPCResponse.success()
        XCTAssertEqual(r.apiVersion, IPCWireVersion.current)
        let data = try JSONEncoder().encode(r)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["apiVersion"] as? Int, IPCWireVersion.current)
    }

    // MARK: - Сами константы

    /// Anchor-тест: значения current явно зафиксированы. Если кто-то bump'ает
    /// версию — он обязан подумать про обновление обоих peer-ов; этот тест
    /// заставит обновить и его, чтобы оставить bump осознанным.
    func testCurrentVersionsAreOne() {
        XCTAssertEqual(MLXWireVersion.current, 1)
        XCTAssertEqual(AudioWireVersion.current, 1)
        XCTAssertEqual(IPCWireVersion.current, 1)
    }
}
