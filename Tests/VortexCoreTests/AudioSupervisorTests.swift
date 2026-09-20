import Foundation
import XCTest
@testable import VortexCore

/// Тесты AudioSupervisor через python-fake-worker.
/// Паттерн: тот же что в MLXSupervisorTests — подменяем executable скриптом.
final class AudioSupervisorTests: XCTestCase {
    private var scriptURL: URL!
    /// Временный каталог сессий — раньше тесты писали markdown в реальный
    /// `~/Documents/Froggy/Meetings`.
    private var sessionDir: URL!
    /// `discordPid`, на который fake-worker сначала шлёт transcript-маркер
    /// `speaker: "fake-start"` (handshake «startCapture получен»), затем
    /// держит паузу 0,5 с и только потом отвечает `ready` — окно для теста
    /// «stop во время start».
    private static let slowReadyPid: Int32 = 777

    private func makeSupervisor() -> AudioSupervisor {
        AudioSupervisor(workerExecutableURL: scriptURL, sessionDirectory: sessionDir)
    }

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("froggy-audio-fake-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        scriptURL = dir.appendingPathComponent("FakeAudioWorker")
        sessionDir = dir.appendingPathComponent("Meetings", isDirectory: true)

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
                if cmd.get("discordPid") == 777:
                    emit({"event": "transcript", "text": "start received", "isFinal": False, "speaker": "fake-start"})
                    time.sleep(0.5)
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
        let supervisor = makeSupervisor()
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
        let supervisor = makeSupervisor()
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
        let supervisor = makeSupervisor()
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

    /// Конец записи закрывает поток транскрипта. Финальность сегмента концом
    /// стрима не является, и пока `stopCapture` не завершал подписки,
    /// `froggy listen-stream` висел после остановки — в том числе когда её
    /// инициировал другой клиент.
    func testStopCaptureFinishesTranscriptStream() async throws {
        let supervisor = makeSupervisor()
        try await supervisor.startCapture(discordPid: nil)
        let (stream, _) = await supervisor.subscribeToTranscripts()

        let finished: Bool = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in stream {}
                return true
            }
            group.addTask {
                try await Task.sleep(for: .seconds(3))
                return false
            }
            await supervisor.stopCapture()
            let first = try await group.next() ?? false
            group.cancelAll()
            return first
        }

        XCTAssertTrue(finished, "stopCapture должен завершать поток транскрипта")
        await supervisor.shutdown()
    }

    /// `stopCapture` во время pending `startCapture` раньше был no-op
    /// (`capturing == false`), и микрофон оставался включённым. Теперь
    /// остановка откладывается и выполняется по возвращении `ready`.
    /// Handshake вместо sleep: подписываемся на transcript'ы ДО старта и
    /// ждём маркер `fake-start` — он уходит из fake сразу по получении
    /// `startCapture`, за 0,5 с до `ready`.
    func testStopDuringStartCancelsCapture() async throws {
        let supervisor = makeSupervisor()
        let (stream, subID) = await supervisor.subscribeToTranscripts()
        let startTask = Task { try await supervisor.startCapture(discordPid: Self.slowReadyPid) }

        let sawMarker: Bool = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await event in stream where event.speaker == "fake-start" { return true }
                return false
            }
            group.addTask {
                try await Task.sleep(for: .seconds(3))
                return false
            }
            let first = try await group.next() ?? false
            group.cancelAll()
            return first
        }
        XCTAssertTrue(sawMarker, "fake должен подтвердить получение startCapture маркером")
        await supervisor.unsubscribe(id: subID)

        await supervisor.stopCapture()
        try await startTask.value
        let capturing = await supervisor.isCapturing()
        XCTAssertFalse(capturing, "stop во время start должен отменить захват")
        let url = await supervisor.sessionURL()
        XCTAssertNil(url, "сессия не должна открываться для отменённого захвата")
        await supervisor.shutdown()
    }

    /// Второй `startCapture`, пока первый ждёт `ready`, — явный отказ, а не
    /// второе ожидание на общих флагах.
    func testSecondStartWhileFirstPendingThrows() async throws {
        let supervisor = makeSupervisor()
        let (stream, subID) = await supervisor.subscribeToTranscripts()
        let startTask = Task { try await supervisor.startCapture(discordPid: Self.slowReadyPid) }
        for await event in stream where event.speaker == "fake-start" { break }
        await supervisor.unsubscribe(id: subID)

        do {
            try await supervisor.startCapture(discordPid: nil)
            XCTFail("ожидали startInProgress")
        } catch let e as AudioSupervisorError {
            if case .startInProgress = e {} else { XCTFail("unexpected: \(e)") }
        }
        try await startTask.value
        await supervisor.shutdown()
    }

    // MARK: - SessionStore

    /// Коллизия имени — не перезапись: второй `SessionStore` по тому же URL
    /// получает суффикс `-1`, оба файла существуют. Раньше `createFile`
    /// молча затирал первую сессию при двух стартах в одну секунду.
    func testSessionStoreCollisionGetsSuffix() async throws {
        let fixed = sessionDir.appendingPathComponent("2026-09-19_10-00-00.md")
        let first = try SessionStore(at: fixed)
        let second = try SessionStore(at: fixed)
        XCTAssertEqual(first.url, fixed)
        XCTAssertEqual(second.url.lastPathComponent, "2026-09-19_10-00-00-1.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.url.path))
        await first.close()
        await second.close()
    }

    /// Транскрипт — приватные данные: файл сессии создаётся с `0600`,
    /// каталог — с `0700`.
    func testSessionFileIsPrivate() async throws {
        let supervisor = makeSupervisor()
        try await supervisor.startCapture(discordPid: nil)
        let url = await supervisor.sessionURL()
        let fileURL = try XCTUnwrap(url)
        let fileAttrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual((fileAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let dirAttrs = try FileManager.default.attributesOfItem(atPath: fileURL.deletingLastPathComponent().path)
        XCTAssertEqual((dirAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        await supervisor.shutdown()
    }

    func testSessionURLAvailableAfterStart() async throws {
        let supervisor = makeSupervisor()
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
