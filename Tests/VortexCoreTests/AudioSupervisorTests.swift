import Foundation
import XCTest
@testable import VortexCore

/// Тесты AudioSupervisor через python-fake-worker.
/// Паттерн: тот же что в MLXSupervisorTests — подменяем executable скриптом.
final class AudioSupervisorTests: XCTestCase {
    private var scriptURL: URL!

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("froggy-audio-fake-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        scriptURL = dir.appendingPathComponent("FakeAudioWorker")

        let script = #"""
        #!/usr/bin/env python3
        import sys, json, threading, time
        sys.stdout = open(sys.stdout.fileno(), 'w', buffering=1)

        def emit(obj):
            print(json.dumps(obj), flush=True)

        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                cmd = json.loads(line)
            except Exception:
                continue
            rid = cmd.get("requestId")
            c = cmd.get("cmd")
            if c == "ping":
                emit({"event": "pong", "requestId": rid})
            elif c == "startCapture":
                emit({"event": "ready", "requestId": rid})
                def send_transcripts():
                    time.sleep(0.05)
                    emit({"event": "transcript", "text": "partial text", "isFinal": False, "speaker": "mic"})
                    time.sleep(0.05)
                    emit({"event": "transcript", "text": "final text", "isFinal": True, "speaker": "mic"})
                threading.Thread(target=send_transcripts, daemon=True).start()
            elif c == "stopCapture":
                emit({"event": "goodbye", "requestId": rid})
            elif c == "shutdown":
                emit({"event": "goodbye", "requestId": rid})
                sys.exit(0)
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

    // MARK: - Tests

    func testWorkerNotFoundError() async {
        let bogus = URL(fileURLWithPath: "/tmp/no-such-audio-worker-\(UUID()).bin")
        let supervisor = AudioSupervisor(workerExecutableURL: bogus)
        do {
            try await supervisor.startCapture(discordPid: nil)
            XCTFail("expected workerNotFound")
        } catch let e as AudioSupervisorError {
            if case .workerNotFound = e { return }
            XCTFail("unexpected: \(e)")
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }

    func testStartCaptureAndIsCapturing() async throws {
        let supervisor = AudioSupervisor(workerExecutableURL: scriptURL)
        let beforeStart = await supervisor.isCapturing()
        XCTAssertFalse(beforeStart)
        try await supervisor.startCapture(discordPid: nil)
        let afterStart = await supervisor.isCapturing()
        XCTAssertTrue(afterStart)
        await supervisor.shutdown()
        let afterShutdown = await supervisor.isCapturing()
        XCTAssertFalse(afterShutdown)
    }

    func testTranscriptBroadcast() async throws {
        let supervisor = AudioSupervisor(workerExecutableURL: scriptURL)
        try await supervisor.startCapture(discordPid: nil)

        let (stream, subID) = await supervisor.subscribeToTranscripts()

        // Собираем события — гонка: либо получаем final-событие, либо таймаут 3с.
        let received: [AudioSupervisor.TranscriptEvent] = try await withThrowingTaskGroup(
            of: [AudioSupervisor.TranscriptEvent].self
        ) { group in
            group.addTask {
                var events: [AudioSupervisor.TranscriptEvent] = []
                for await event in stream {
                    events.append(event)
                    if event.isFinal { break }
                }
                return events
            }
            group.addTask {
                try await Task.sleep(for: .seconds(3))
                return []
            }
            let first = try await group.next() ?? []
            group.cancelAll()
            return first
        }
        await supervisor.unsubscribe(id: subID)

        XCTAssertFalse(received.isEmpty, "ожидались transcript-события")
        let partial = received.first(where: { !$0.isFinal })
        let final_ = received.first(where: { $0.isFinal })
        XCTAssertNotNil(partial, "ожидался partial transcript")
        XCTAssertNotNil(final_, "ожидался final transcript")
        XCTAssertEqual(final_?.text, "final text")
        XCTAssertEqual(final_?.speaker, "mic")

        await supervisor.shutdown()
    }

    func testStopCaptureDoesNotKillWorker() async throws {
        let supervisor = AudioSupervisor(workerExecutableURL: scriptURL)
        try await supervisor.startCapture(discordPid: nil)
        let capturingBefore = await supervisor.isCapturing()
        XCTAssertTrue(capturingBefore)
        await supervisor.stopCapture()
        let capturingAfterStop = await supervisor.isCapturing()
        XCTAssertFalse(capturingAfterStop)
        // Worker жив — можно стартовать снова
        try await supervisor.startCapture(discordPid: nil)
        let capturingAfterRestart = await supervisor.isCapturing()
        XCTAssertTrue(capturingAfterRestart)
        await supervisor.shutdown()
    }

    func testSessionURLAvailableAfterStart() async throws {
        let supervisor = AudioSupervisor(workerExecutableURL: scriptURL)
        let urlBefore = await supervisor.sessionURL()
        XCTAssertNil(urlBefore, "до старта sessionURL должен быть nil")
        try await supervisor.startCapture(discordPid: nil)
        let url = await supervisor.sessionURL()
        XCTAssertNotNil(url, "после startCapture должен быть sessionURL")
        if let url {
            XCTAssertTrue(url.lastPathComponent.hasSuffix(".md"))
        }
        await supervisor.shutdown()
        if let url {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                          "markdown-файл сессии должен существовать после shutdown")
        }
    }
}
