import Foundation
import XCTest
@testable import VortexCore

/// Тесты supervisor'а через подмену worker-executable'a простым shell-скриптом,
/// который понимает наш JSON-line протокол. Реальный MLX в xctest не грузим.
final class MLXSupervisorTests: XCTestCase {
    private var scriptURL: URL!

    override func setUpWithError() throws {
        // Скрипт-«fake worker»: принимает {"cmd":"ping"} → отвечает pong с тем же requestId.
        // Принимает shutdown → goodbye + exit. Игнорирует load (не нужен для теста).
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("froggy-fake-worker-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        scriptURL = dir.appendingPathComponent("FakeWorker")

        let script = #"""
        #!/usr/bin/env python3
        import sys, json
        sys.stdout = open(sys.stdout.fileno(), 'w', buffering=1)
        for line in sys.stdin:
            try:
                cmd = json.loads(line)
            except Exception:
                continue
            rid = cmd.get("requestId")
            if cmd.get("cmd") == "ping":
                print(json.dumps({"event": "pong", "requestId": rid}), flush=True)
            elif cmd.get("cmd") == "shutdown":
                print(json.dumps({"event": "goodbye", "requestId": rid}), flush=True)
                break
        """#
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        var attrs = try FileManager.default.attributesOfItem(atPath: scriptURL.path)
        attrs[.posixPermissions] = NSNumber(value: 0o755)
        try FileManager.default.setAttributes(attrs, ofItemAtPath: scriptURL.path)
    }

    override func tearDownWithError() throws {
        if let url = scriptURL {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
    }

    // testSpawnAndShutdown намеренно не делается здесь — pipe-lifecycle
    // супервайзера завязан на ready/goodbye и таймауты, и мокать его
    // через python-скрипт ненадёжно (висит на блокирующем чтении stdin).
    // Полноценный интеграционный тест supervisor'а — следом, в Mem-3.1.

    func testWorkerNotFoundIsExplicitError() async {
        let bogus = URL(fileURLWithPath: "/var/folders/missing-\(UUID()).bin")
        let supervisor = MLXSupervisor(workerExecutableURL: bogus)
        do {
            try await supervisor.loadModel(modelPath: "/x")
            XCTFail("expected workerNotFound")
        } catch let e as MLXSupervisorError {
            if case .workerNotFound = e { return }
            XCTFail("unexpected: \(e)")
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }
}
