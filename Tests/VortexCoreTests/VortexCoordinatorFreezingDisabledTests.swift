import XCTest
@testable import VortexCore

/// ADR 0017: master switch `freezingEnabled`. Когда выключен — координатор
/// игнорит pressure-эвенты, никаких SIGSTOP'ов. При переключении в false
/// сразу размораживает всё, что было заморожено до этого.
private actor StubVortexForToggle: VortexFreezing {
    private(set) var frozen: Set<Int32> = []
    private(set) var thawCalls: Int = 0

    func freezeProcess(pid: Int32) async throws -> Int32 {
        frozen.insert(pid)
        return pid
    }

    func thawProcess(pid: Int32) async {
        frozen.remove(pid)
    }

    func thawAll() async {
        thawCalls += 1
        frozen.removeAll()
    }

    func suspendedCount() async -> Int { frozen.count }
    func currentlyFrozen() -> Set<Int32> { frozen }
}

private struct ToggleFinder: ProcessFinder {
    let mapping: [String: [Int32]]
    func pids(forBundleIds bundleIds: [String]) async -> [Int32] {
        bundleIds.flatMap { mapping[$0] ?? [] }
    }
}

final class VortexCoordinatorFreezingDisabledTests: XCTestCase {
    private func makeCoordinator(
        freezingEnabled: Bool
    ) -> (VortexCoordinator, FakeMemoryPressureSource, StubVortexForToggle) {
        let src = FakeMemoryPressureSource()
        let monitor = MemoryPressureMonitor(source: src, cooldownSeconds: 0.5)
        let stub = StubVortexForToggle()
        let finder = ToggleFinder(mapping: [
            "tier1.app": [1001, 1002],
            "tier2.app": [2001],
        ])
        let mlx = MLXSupervisor()
        let coord = VortexCoordinator(
            mlx: mlx,
            vortex: stub,
            monitor: monitor,
            tier1BundleIds: ["tier1.app"],
            tier2BundleIds: ["tier2.app"],
            finder: finder,
            gradualThawDelaySeconds: 0.1,
            freezingEnabled: freezingEnabled
        )
        return (coord, src, stub)
    }

    /// Базовый кейс: при freezingEnabled=false `.critical` не приводит ни
    /// к одному freezeProcess. Это инвариант, без которого ADR 0017 ломается.
    func testCriticalIgnoredWhenFreezingDisabled() async throws {
        let (coord, src, stub) = makeCoordinator(freezingEnabled: false)
        await coord.startMonitoring()
        try await Task.sleep(for: .milliseconds(50))

        src.emit(.critical)
        try await Task.sleep(for: .milliseconds(200))

        let snap = await coord.pressureSnapshot()
        XCTAssertTrue(snap.tier1Frozen.isEmpty, "tier1 не должен морозиться при freezingEnabled=false")
        XCTAssertTrue(snap.tier2Frozen.isEmpty, "tier2 не должен морозиться при freezingEnabled=false")
        let frozen = await stub.currentlyFrozen()
        XCTAssertTrue(frozen.isEmpty, "ни одного pid не должно быть в SIGSTOP")
        await coord.stopMonitoring()
    }

    /// Переключение Active → Paused в живую: сначала зафризили tier1+tier2
    /// через .critical, потом setFreezingEnabled(false) → emergencyThaw,
    /// все pid отпущены. Это ровно тот сценарий, что MenuBar Off ожидает.
    func testToggleOffEmergencyThawsCurrentlyFrozen() async throws {
        let (coord, src, stub) = makeCoordinator(freezingEnabled: true)
        await coord.startMonitoring()
        try await Task.sleep(for: .milliseconds(50))

        src.emit(.critical)
        try await Task.sleep(for: .milliseconds(200))

        let snapBefore = await coord.pressureSnapshot()
        XCTAssertFalse(snapBefore.tier1Frozen.isEmpty)
        XCTAssertFalse(snapBefore.tier2Frozen.isEmpty)

        await coord.setFreezingEnabled(false)
        try await Task.sleep(for: .milliseconds(50))

        let snapAfter = await coord.pressureSnapshot()
        XCTAssertTrue(snapAfter.tier1Frozen.isEmpty, "tier1 должен быть thawed после Off")
        XCTAssertTrue(snapAfter.tier2Frozen.isEmpty, "tier2 должен быть thawed после Off")
        let frozen = await stub.currentlyFrozen()
        XCTAssertTrue(frozen.isEmpty)
        let isEnabled = await coord.isFreezingEnabled()
        XCTAssertFalse(isEnabled)
        await coord.stopMonitoring()
    }

    /// После Off новые pressure-эвенты больше ничего не морозят — пока On
    /// не вернут. Защита от регрессии «забыли проверить freezingEnabled
    /// в applyPolicy после toggle».
    func testNewPressureEventsAfterOffStayIgnored() async throws {
        let (coord, src, stub) = makeCoordinator(freezingEnabled: true)
        await coord.startMonitoring()
        try await Task.sleep(for: .milliseconds(50))

        await coord.setFreezingEnabled(false)

        src.emit(.warning)
        try await Task.sleep(for: .milliseconds(150))
        src.emit(.critical)
        try await Task.sleep(for: .milliseconds(150))

        let snap = await coord.pressureSnapshot()
        XCTAssertTrue(snap.tier1Frozen.isEmpty)
        XCTAssertTrue(snap.tier2Frozen.isEmpty)
        let frozen = await stub.currentlyFrozen()
        XCTAssertTrue(frozen.isEmpty)
        await coord.stopMonitoring()
    }
}
