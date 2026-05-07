import XCTest
@testable import VortexCore

/// Stub-VortexFreezing для проверки tier-логики координатора без реального kill().
private actor StubVortex: VortexFreezing {
    private(set) var frozen: Set<Int32> = []
    private(set) var thawed: [Int32] = []

    func freezeProcess(pid: Int32) async throws -> Int32 {
        frozen.insert(pid)
        return pid
    }

    func thawProcess(pid: Int32) async {
        frozen.remove(pid)
        thawed.append(pid)
    }

    func thawAll() async {
        thawed.append(contentsOf: frozen)
        frozen.removeAll()
    }

    func suspendedCount() async -> Int { frozen.count }

    func currentlyFrozen() -> Set<Int32> { frozen }
}

/// Stub-finder: маппит bundle-id → fixed pid.
private struct StubFinder: ProcessFinder {
    let mapping: [String: [Int32]]
    func pids(forBundleIds bundleIds: [String]) async -> [Int32] {
        bundleIds.flatMap { mapping[$0] ?? [] }
    }
}

final class VortexCoordinatorPolicyTests: XCTestCase {
    private func makeCoordinator(
        cooldown: TimeInterval,
        gradualThaw: TimeInterval = 0.1,
        tier1Pids: [Int32] = [1001, 1002],
        tier2Pids: [Int32] = [2001]
    ) -> (VortexCoordinator, FakeMemoryPressureSource, StubVortex) {
        let src = FakeMemoryPressureSource()
        let monitor = MemoryPressureMonitor(source: src, cooldownSeconds: cooldown)
        let stub = StubVortex()
        let finder = StubFinder(mapping: [
            "tier1.app": tier1Pids,
            "tier2.app": tier2Pids,
        ])
        // MLXSupervisor нужен реальный (его не дёргаем), просто чтобы Coordinator проинициализировался.
        let mlx = MLXSupervisor()
        let coord = VortexCoordinator(
            mlx: mlx,
            vortex: stub,
            monitor: monitor,
            tier1BundleIds: ["tier1.app"],
            tier2BundleIds: ["tier2.app"],
            finder: finder,
            gradualThawDelaySeconds: gradualThaw
        )
        return (coord, src, stub)
    }

    func testWarningFreezesTier1Only() async throws {
        let (coord, src, stub) = makeCoordinator(cooldown: 0.5)
        await coord.startMonitoring()
        try await Task.sleep(for: .milliseconds(50)) // дать listenTask старт

        src.emit(.warning)
        try await Task.sleep(for: .milliseconds(200))

        let snap = await coord.pressureSnapshot()
        XCTAssertEqual(snap.level, .warning)
        XCTAssertEqual(Set(snap.tier1Frozen), [1001, 1002])
        XCTAssertTrue(snap.tier2Frozen.isEmpty)
        let frozen = await stub.currentlyFrozen()
        XCTAssertEqual(frozen, [1001, 1002])
        await coord.stopMonitoring()
    }

    func testCriticalFreezesBothTiers() async throws {
        let (coord, src, _) = makeCoordinator(cooldown: 0.5)
        await coord.startMonitoring()
        try await Task.sleep(for: .milliseconds(50))

        src.emit(.critical)
        try await Task.sleep(for: .milliseconds(200))

        let snap = await coord.pressureSnapshot()
        XCTAssertEqual(snap.level, .critical)
        XCTAssertEqual(Set(snap.tier1Frozen), [1001, 1002])
        XCTAssertEqual(Set(snap.tier2Frozen), [2001])
        await coord.stopMonitoring()
    }

    /// Cooldown работает: 0.5s cooldown → через 0.2s нет thaw, через 1.0s — thaw'нулось.
    func testNormalRespectsCooldown() async throws {
        let (coord, src, _) = makeCoordinator(cooldown: 0.5, gradualThaw: 0.05)
        await coord.startMonitoring()
        try await Task.sleep(for: .milliseconds(50))

        src.emit(.warning)
        try await Task.sleep(for: .milliseconds(200))

        // Пока в warning'e
        let inWarn = await coord.pressureSnapshot()
        XCTAssertEqual(inWarn.tier1Frozen.count, 2)

        // Источник говорит normal, но cooldown 0.5s ещё не истёк.
        src.emit(.normal)
        try await Task.sleep(for: .milliseconds(200))
        let earlyNormal = await coord.pressureSnapshot()
        XCTAssertEqual(earlyNormal.tier1Frozen.count, 2,
                       "tier-1 не должен оттаять до конца cooldown'a")

        // Подождать cooldown + gradual thaw
        try await Task.sleep(for: .milliseconds(700))
        let after = await coord.pressureSnapshot()
        XCTAssertEqual(after.level, .normal)
        XCTAssertTrue(after.tier1Frozen.isEmpty, "tier-1 должен оттаять после полного cooldown'a")
        XCTAssertTrue(after.tier2Frozen.isEmpty)
        await coord.stopMonitoring()
    }

    func testUpgradeCancelsPendingThaw() async throws {
        let (coord, src, _) = makeCoordinator(cooldown: 0.3, gradualThaw: 0.5)
        await coord.startMonitoring()
        try await Task.sleep(for: .milliseconds(50))

        src.emit(.critical)
        try await Task.sleep(for: .milliseconds(200))
        let inCrit = await coord.pressureSnapshot()
        XCTAssertEqual(inCrit.tier2Frozen.count, 1)

        // Просим оттепель и тут же поднимаем уровень обратно.
        src.emit(.normal)
        try await Task.sleep(for: .milliseconds(100))
        src.emit(.critical)
        try await Task.sleep(for: .milliseconds(700))

        let final = await coord.pressureSnapshot()
        XCTAssertEqual(final.level, .critical)
        XCTAssertEqual(final.tier1Frozen.count, 2)
        XCTAssertEqual(final.tier2Frozen.count, 1)
        await coord.stopMonitoring()
    }
}
