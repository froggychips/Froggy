import Foundation
import XCTest
@testable import VortexCore

/// Тяжёлый бенчмарк: spawn-аем дочерний процесс с 200 MB heap, замораживаем,
/// прогоняем через PageoutChain, замеряем RSS до/после. Под CI такие тесты
/// flaky (jetsam требует реального давления, machVM — entitlement'a),
/// поэтому скип по умолчанию. Включить локально:
///     FROGGY_RUN_PAGEOUT_BENCHMARK=1 swift test --filter PageoutBenchmark
final class PageoutBenchmarkTests: XCTestCase {
    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["FROGGY_RUN_PAGEOUT_BENCHMARK"] == "1" else {
            throw XCTSkip("set FROGGY_RUN_PAGEOUT_BENCHMARK=1 to enable")
        }
    }

    /// Бенчмарк-каркас: spawn ребёнок, freeze + pageout, печатаем delta.
    /// Не делаем строгого assert — pageout под jetsam «работает» только
    /// под реальным давлением.
    func testFreezePageoutShrinksRSS() async throws {
        // 200 MB heap, потом sleep — простая пайплайн через `python3 -c`.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.arguments = ["-c", #"""
        import time
        buf = bytearray(200 * 1024 * 1024)
        for i in range(0, len(buf), 4096):
            buf[i] = i % 256
        time.sleep(60)
        """#]
        try proc.run()
        defer { proc.terminate() }
        try await Task.sleep(for: .seconds(2)) // дать heap прогреться

        let pid = proc.processIdentifier
        let rssBefore = Self.rssBytes(pid: pid)

        let classifier = ProcessClassifier(extraAllowedPrefixes: ["/usr/bin/", "/usr/local/", "/opt/"])
        let chain = PageoutChain(preferred: .jetsam)
        let store = FrozenPidsStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("bench-\(UUID()).pids"))
        let vortex = VortexActor(classifier: classifier, pidStore: store, pageout: chain)

        _ = try await vortex.freezeProcess(pid: pid)
        try await Task.sleep(for: .seconds(5))

        let rssAfter = Self.rssBytes(pid: pid)
        let deltaMB = Double(rssBefore - rssAfter) / 1_048_576.0
        print("[benchmark] pid=\(pid) rss before=\(rssBefore / 1_048_576) MB after=\(rssAfter / 1_048_576) MB Δ=\(deltaMB) MB")

        await vortex.thawProcess(pid: pid)
    }

    /// Берём `ps -o rss= -p <pid>` (KB, как ps делает на macOS).
    private static func rssBytes(pid: Int32) -> Int {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-o", "rss=", "-p", String(pid)]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (Int(raw) ?? 0) * 1024
    }
}
