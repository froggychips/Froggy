import XCTest
@testable import VortexCore

final class MemoryPressureMonitorTests: XCTestCase {
    func testInitialNormalPublished() async {
        let src = FakeMemoryPressureSource()
        let monitor = MemoryPressureMonitor(source: src, cooldownSeconds: 1)
        await monitor.start()

        var iter = monitor.events.makeAsyncIterator()
        let first = await iter.next()
        XCTAssertEqual(first, .normal)
        await monitor.stop()
    }

    func testEscalationIsImmediate() async {
        let src = FakeMemoryPressureSource()
        let monitor = MemoryPressureMonitor(source: src, cooldownSeconds: 1)
        await monitor.start()
        var iter = monitor.events.makeAsyncIterator()
        _ = await iter.next() // .normal initial

        src.emit(.warning)
        let warning = await iter.next()
        XCTAssertEqual(warning, .warning)

        src.emit(.critical)
        let critical = await iter.next()
        XCTAssertEqual(critical, .critical)

        await monitor.stop()
    }

    /// Понижение должно ждать `cooldownSeconds`. Используем 0.5s в тесте.
    func testDowngradeWaitsForCooldown() async throws {
        let src = FakeMemoryPressureSource()
        let monitor = MemoryPressureMonitor(source: src, cooldownSeconds: 0.5)
        await monitor.start()
        var iter = monitor.events.makeAsyncIterator()
        _ = await iter.next() // .normal

        src.emit(.warning)
        let lvl = await iter.next()
        XCTAssertEqual(lvl, .warning)

        // 30 % cooldown — рано, не должно быть .normal
        src.emit(.normal)
        let earlyCheck = await monitor.currentLevel()
        XCTAssertEqual(earlyCheck, .warning, "downgrade пришёл раньше cooldown")

        // подождать полный cooldown
        try await Task.sleep(for: .seconds(0.7))
        let late = await iter.next()
        XCTAssertEqual(late, .normal)
        await monitor.stop()
    }

    /// Если в окне cooldown'а пришёл upgrade — downgrade отменяется.
    func testUpgradeCancelsPendingDowngrade() async throws {
        let src = FakeMemoryPressureSource()
        let monitor = MemoryPressureMonitor(source: src, cooldownSeconds: 0.5)
        await monitor.start()
        var iter = monitor.events.makeAsyncIterator()
        _ = await iter.next() // normal

        src.emit(.warning)
        let lvl = await iter.next()
        XCTAssertEqual(lvl, .warning)

        // Запросили downgrade…
        src.emit(.normal)
        try await Task.sleep(for: .seconds(0.2))
        // …но за половину cooldown'a поднялось обратно.
        src.emit(.warning)
        try await Task.sleep(for: .seconds(0.7))

        let level = await monitor.currentLevel()
        XCTAssertEqual(level, .warning, "downgrade должен был отмениться upgrade'ом")
        await monitor.stop()
    }

    func testNudgeForcesAtLeastWarning() async throws {
        let src = FakeMemoryPressureSource()
        let monitor = MemoryPressureMonitor(source: src, cooldownSeconds: 0.5)
        await monitor.start()
        var iter = monitor.events.makeAsyncIterator()
        _ = await iter.next() // normal

        await monitor.nudge(.warning, durationSeconds: 0.4)
        let nudged = await iter.next()
        XCTAssertEqual(nudged, .warning)

        // После expiry + cooldown возвращаемся к .normal
        try await Task.sleep(for: .seconds(1.2))
        let after = await monitor.currentLevel()
        XCTAssertEqual(after, .normal)
        await monitor.stop()
    }

    func testNudgeMaxesWithObserved() async throws {
        let src = FakeMemoryPressureSource()
        let monitor = MemoryPressureMonitor(source: src, cooldownSeconds: 0.5)
        await monitor.start()
        var iter = monitor.events.makeAsyncIterator()
        _ = await iter.next()

        // Источник говорит critical — это сильнее warning-nudge, должно стать critical.
        await monitor.nudge(.warning, durationSeconds: 5)
        _ = await iter.next() // .warning от nudge
        src.emit(.critical)
        let level = await iter.next()
        XCTAssertEqual(level, .critical)
        await monitor.stop()
    }
}
