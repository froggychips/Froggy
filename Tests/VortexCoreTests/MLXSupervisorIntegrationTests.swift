import Foundation
import XCTest
@testable import VortexCore

/// Pipe-lifecycle тесты supervisor↔worker. Используют `FroggyMLXWorkerFake` —
/// Swift-бинарь, понимающий тот же JSON-line протокол, что реальный worker,
/// но без MLX-зависимостей. Это закрывает Mem-3.1 (отложенный долг от Mem-3).
final class MLXSupervisorIntegrationTests: XCTestCase {
    private var fakeWorkerURL: URL!

    override func setUpWithError() throws {
        guard let url = Self.findFakeWorker() else {
            // Если bin'арь не собран — попробуем собрать. swift test не
            // build'ит executable target'ы автоматически.
            try Self.buildFakeWorker()
            guard let url = Self.findFakeWorker() else {
                throw XCTSkip("FroggyMLXWorkerFake не найден после swift build — пропускаем")
            }
            fakeWorkerURL = url
            return
        }
        fakeWorkerURL = url
    }

    /// Happy path: load → ready, unload → goodbye + exit. После unload
    /// supervisor.isLoaded() == false и worker pid не существует.
    func testHappyPathLoadAndUnload() async throws {
        let supervisor = MLXSupervisor(workerExecutableURL: fakeWorkerURL)

        try await supervisor.loadModel(modelPath: "/tmp/fake-model")
        let loaded = await supervisor.isLoaded()
        XCTAssertTrue(loaded)

        let pid = await supervisor.currentWorkerPid()
        XCTAssertNotNil(pid)

        await supervisor.unloadModel()
        let stillLoaded = await supervisor.isLoaded()
        XCTAssertFalse(stillLoaded)
        let pidAfter = await supervisor.currentWorkerPid()
        XCTAssertNil(pidAfter)
    }

    /// generate стримит несколько chunk'ов. fake worker эмитит «tok0…tok4 » + done.
    func testGenerateStreamsChunks() async throws {
        let supervisor = MLXSupervisor(workerExecutableURL: fakeWorkerURL)
        try await supervisor.loadModel(modelPath: "/tmp/fake-model")
        defer { Task { await supervisor.unloadModel() } }

        var collected: [String] = []
        for try await chunk in supervisor.generateStream(prompt: "hi", maxTokens: 5) {
            collected.append(chunk)
        }
        XCTAssertGreaterThanOrEqual(collected.count, 1, "ожидали хотя бы 1 chunk")
        XCTAssertTrue(collected.joined().contains("tok"), "ожидали fake-токены, получили: \(collected)")
    }

    /// fake worker в режиме `ignore-shutdown` не отвечает на `shutdown`.
    /// Supervisor должен подождать timeout (3s) и SIGKILL'ить процесс.
    /// Тест ставит timeout 10 c — если повисло, что-то с SIGKILL не так.
    func testShutdownTimeoutForcesSIGKILL() async throws {
        let supervisor = MLXSupervisor(
            workerExecutableURL: fakeWorkerURL,
            extraArgs: ["--mode", "ignore-shutdown"]
        )
        try await supervisor.loadModel(modelPath: "/tmp/fake-model")

        let started = Date()
        let unloadTask = Task { await supervisor.unloadModel() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await unloadTask.value }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "unloadModel застряло"])
            }
            try await group.next()
            group.cancelAll()
        }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 10, "unload должен укладываться в timeout+epsilon")
        let stillLoaded = await supervisor.isLoaded()
        XCTAssertFalse(stillLoaded)
    }

    /// fake worker в режиме `crash-on-generate` exit'ится сразу при generate.
    /// pending continuation должен получить .workerCrashed, isLoaded → false.
    func testWorkerCrashYieldsContinuationError() async throws {
        let supervisor = MLXSupervisor(
            workerExecutableURL: fakeWorkerURL,
            extraArgs: ["--mode", "crash-on-generate"]
        )
        try await supervisor.loadModel(modelPath: "/tmp/fake-model")

        do {
            for try await _ in supervisor.generateStream(prompt: "boom", maxTokens: 5) {}
            XCTFail("ожидали ошибку, получили завершение stream'а")
        } catch let e as MLXSupervisorError {
            switch e {
            case .workerCrashed, .generateFailed: break
            default: XCTFail("ожидали workerCrashed/generateFailed, получили \(e)")
            }
        }
        // Дать terminationHandler'у время сработать
        try? await Task.sleep(for: .milliseconds(200))
        let loaded = await supervisor.isLoaded()
        XCTAssertFalse(loaded, "после краха worker'а isLoaded должен сброситься")
    }

    /// 10 циклов load/unload. Цель — убедиться, что supervisor не утекает
    /// state'ом из старого process'a (pendingRequests, stdoutBuffer, и т.п.).
    /// Проверяем по мягкой эвристике: после 10 циклов pid должен быть nil
    /// (ничего не висит) и нет hang'а.
    func testRapidLoadUnloadDoesNotHang() async throws {
        let supervisor = MLXSupervisor(workerExecutableURL: fakeWorkerURL)

        for i in 0..<10 {
            try await supervisor.loadModel(modelPath: "/tmp/fake-\(i)")
            await supervisor.unloadModel()
        }
        let pid = await supervisor.currentWorkerPid()
        XCTAssertNil(pid, "после 10 циклов worker не должен оставаться")
        let loaded = await supervisor.isLoaded()
        XCTAssertFalse(loaded)
    }

    // MARK: - Helpers

    private static func findFakeWorker() -> URL? {
        let cwd = FileManager.default.currentDirectoryPath
        let candidates = [
            "\(cwd)/.build/debug/FroggyMLXWorkerFake",
            "\(cwd)/.build/release/FroggyMLXWorkerFake",
            "\(cwd)/.build/arm64-apple-macosx/debug/FroggyMLXWorkerFake",
            "\(cwd)/.build/arm64-apple-macosx/release/FroggyMLXWorkerFake",
        ]
        for c in candidates {
            if FileManager.default.isExecutableFile(atPath: c) {
                return URL(fileURLWithPath: c)
            }
        }
        return nil
    }

    private static func buildFakeWorker() throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["swift", "build", "--product", "FroggyMLXWorkerFake"]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
    }
}
