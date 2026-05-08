import Foundation
import XCTest
@testable import VortexCore

/// Stub-VortexFreezing — копия из VortexCoordinatorPolicyTests, локальная,
/// чтобы не делать internal-leak.
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

private struct StubFinder: ProcessFinder {
    let mapping: [String: [Int32]]
    func pids(forBundleIds bundleIds: [String]) async -> [Int32] {
        bundleIds.flatMap { mapping[$0] ?? [] }
    }
}

/// Mutable variant — для тестов где pid появляется во время сессии
/// (новый app запущен post-startup'ом).
private actor MutableStubFinder: ProcessFinder {
    private var mapping: [String: [Int32]]
    init(_ initial: [String: [Int32]]) { self.mapping = initial }
    func add(bundleId: String, pid: Int32) {
        mapping[bundleId, default: []].append(pid)
    }
    func pids(forBundleIds bundleIds: [String]) async -> [Int32] {
        bundleIds.flatMap { mapping[$0] ?? [] }
    }
}

final class VortexCoordinatorWorkspaceTests: XCTestCase {
    private func makeCoordinator(
        workspaceSource: any WorkspaceEventSource,
        gradualThaw: TimeInterval = 0.1
    ) -> (VortexCoordinator, FakeMemoryPressureSource, StubVortex) {
        let pressureSrc = FakeMemoryPressureSource()
        let monitor = MemoryPressureMonitor(source: pressureSrc, cooldownSeconds: 0.5)
        let stub = StubVortex()
        let finder = StubFinder(mapping: [
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
            workspaceSource: workspaceSource,
            gradualThawDelaySeconds: gradualThaw
        )
        return (coord, pressureSrc, stub)
    }

    /// `willSleep` → emergency thaw + sleep-gate. Pressure-event'ы во время
    /// sleep'а должны игнорироваться.
    func testWillSleepThawsAllAndGatesPolicy() async throws {
        let ws = FakeWorkspaceEventSource()
        let (coord, pressure, stub) = makeCoordinator(workspaceSource: ws)
        await coord.startMonitoring()
        try await Task.sleep(for: .milliseconds(50))

        // Сначала уходим в warning'е, морозим tier-1.
        pressure.emit(.warning)
        try await Task.sleep(for: .milliseconds(200))
        let frozenBefore = await stub.currentlyFrozen()
        XCTAssertEqual(frozenBefore, [1001, 1002])

        // willSleep → должен размораживать всё.
        ws.emit(.willSleep)
        try await Task.sleep(for: .milliseconds(150))
        let frozenAfterSleep = await stub.currentlyFrozen()
        XCTAssertTrue(frozenAfterSleep.isEmpty,
                      "willSleep должен был сделать emergency thaw")

        // Pressure-event во время sleep'а — игнорируется.
        pressure.emit(.critical)
        try await Task.sleep(for: .milliseconds(200))
        let frozenWhileSleeping = await stub.currentlyFrozen()
        XCTAssertTrue(frozenWhileSleeping.isEmpty,
                      "policy не должен морозить во время sleep'а")

        await coord.stopMonitoring()
    }

    /// `didWake` снимает gate; следующий pressure-event снова применяется.
    func testDidWakeUngatesPolicy() async throws {
        let ws = FakeWorkspaceEventSource()
        let (coord, pressure, stub) = makeCoordinator(workspaceSource: ws)
        await coord.startMonitoring()
        try await Task.sleep(for: .milliseconds(50))

        ws.emit(.willSleep)
        try await Task.sleep(for: .milliseconds(50))
        ws.emit(.didWake)
        try await Task.sleep(for: .milliseconds(50))

        pressure.emit(.warning)
        try await Task.sleep(for: .milliseconds(200))

        let frozen = await stub.currentlyFrozen()
        XCTAssertEqual(frozen, [1001, 1002],
                       "после wake policy должна снова работать")
        await coord.stopMonitoring()
    }

    /// `handleExternalTermination` убирает pid из in-memory tier-set'ов.
    /// Это важно, чтобы snapshot не показывал zombie и thawTier не звала
    /// SIGCONT мёртвому pid'у.
    func testExternalTerminationCleansTierSet() async throws {
        let ws = FakeWorkspaceEventSource()
        let (coord, pressure, _) = makeCoordinator(workspaceSource: ws)
        await coord.startMonitoring()
        try await Task.sleep(for: .milliseconds(50))

        pressure.emit(.warning)
        try await Task.sleep(for: .milliseconds(200))
        let snap1 = await coord.pressureSnapshot()
        XCTAssertEqual(Set(snap1.tier1Frozen), [1001, 1002])

        // Один из frozen pid'ов убили извне — координатор-как-Sink чистит
        // свой in-memory set.
        await coord.handleExternalTermination(pid: 1001)
        let snap2 = await coord.pressureSnapshot()
        XCTAssertEqual(Set(snap2.tier1Frozen), [1002],
                       "pid 1001 должен исчезнуть из tier1Frozen")

        await coord.stopMonitoring()
    }

    /// End-to-end: watcher + coordinator вместе. Frozen pid убили извне —
    /// и FrozenPidsStore чист, и in-memory tier-set чист.
    func testEndToEndExternalKillCleansBoth() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("e2e-\(UUID()).pids")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FrozenPidsStore(fileURL: url)
        await store.add(.init(pid: 1001, executablePath: "/Applications/Tier1.app"))

        let ws = FakeWorkspaceEventSource()
        let (coord, pressure, _) = makeCoordinator(workspaceSource: ws)
        await coord.startMonitoring()
        try await Task.sleep(for: .milliseconds(50))

        // Прогреваем in-memory state координатора.
        pressure.emit(.warning)
        try await Task.sleep(for: .milliseconds(200))

        let watcher = WorkspaceTerminationWatcher(source: ws, pidStore: store, sink: coord)
        await watcher.start()

        ws.emit(.appTerminated(pid: 1001, bundleId: "com.tier1"))
        try await Task.sleep(for: .milliseconds(150))

        // Persisted store cleaned.
        let entries = await store.entries()
        XCTAssertTrue(entries.allSatisfy { $0.pid != 1001 },
                      "запись 1001 должна быть удалена из store")

        // In-memory tier-set cleaned.
        let snap = await coord.pressureSnapshot()
        XCTAssertFalse(snap.tier1Frozen.contains(1001),
                       "pid 1001 не должен оставаться в tier1Frozen")

        await watcher.stop()
        await coord.stopMonitoring()
    }

    // MARK: - Bug-3: app-activate под sustained pressure

    /// **Regression test для Bug-3.** Когда pressure держится на `.critical`
    /// и пользователь запускает новый tier-1 app — этот app должен попасть
    /// под freeze без ожидания следующего pressure level change. До fix'а
    /// `applyWorkspaceEvent` обрабатывал только `.frontmostChanged`,
    /// `.appActivated` шёл в `default: break`, freeze никогда не fired
    /// для post-launch'нутого pid'а.
    ///
    /// Сценарий из живой сессии 2026-05-08:
    /// 1. pressure=.critical с 09:27:17 (`secondsInLevel: 3032`)
    /// 2. Telegram (tier-1) запущен ~09:50 — после первого freeze cycle'а
    /// 3. Должен быть заморожен немедленно, не дожидаясь pressure level
    ///    transition (которого не будет — pressure стабилен)
    func testAppActivatedTriggersFreezeUnderSustainedCritical() async throws {
        let pressureSrc = FakeMemoryPressureSource()
        let monitor = MemoryPressureMonitor(source: pressureSrc, cooldownSeconds: 0.5)
        let stub = StubVortex()
        // Изначально tier1.app пуст — стартовый seed без tier-1 pid'ов.
        let finder = MutableStubFinder(["tier1.app": []])
        let mlx = MLXSupervisor()
        let ws = FakeWorkspaceEventSource()
        let coord = VortexCoordinator(
            mlx: mlx,
            vortex: stub,
            monitor: monitor,
            tier1BundleIds: ["tier1.app"],
            tier2BundleIds: ["tier2.app"],
            finder: finder,
            workspaceSource: ws,
            gradualThawDelaySeconds: 0.1
        )
        await coord.startMonitoring()
        try await Task.sleep(for: .milliseconds(50))

        // Прогон: pressure→critical при пустом tier-1 → freezeTier
        // вызывается, но finder возвращает empty → freezeProcess не
        // вызывается. Всё correctно по pre-fix поведению.
        pressureSrc.emit(.critical)
        try await Task.sleep(for: .milliseconds(200))
        let frozenAfterCritical = await stub.currentlyFrozen()
        XCTAssertTrue(frozenAfterCritical.isEmpty,
                      "при пустом finder freeze не fires (sanity)")

        // Новый tier-1 app запущен под sustained .critical. Pre-fix:
        // .appActivated falls в default → freeze не triggers. Post-fix:
        // case .appActivated re-evaluates freezeTier → новый pid frozen.
        await finder.add(bundleId: "tier1.app", pid: 5001)
        ws.emit(.appActivated(pid: 5001, bundleId: "tier1.app"))
        try await Task.sleep(for: .milliseconds(200))

        let frozenAfterActivate = await stub.currentlyFrozen()
        XCTAssertEqual(frozenAfterActivate, [5001],
                       "Bug-3: новый tier-1 pid должен быть frozen на .appActivated при sustained .critical")

        await coord.stopMonitoring()
    }

    /// `.appActivated` под `.normal` НЕ морозит — re-evaluation срабатывает
    /// только когда давление выше `.normal`.
    func testAppActivatedUnderNormalDoesNotFreeze() async throws {
        let pressureSrc = FakeMemoryPressureSource()
        let monitor = MemoryPressureMonitor(source: pressureSrc, cooldownSeconds: 0.5)
        let stub = StubVortex()
        let finder = MutableStubFinder(["tier1.app": []])
        let mlx = MLXSupervisor()
        let ws = FakeWorkspaceEventSource()
        let coord = VortexCoordinator(
            mlx: mlx,
            vortex: stub,
            monitor: monitor,
            tier1BundleIds: ["tier1.app"],
            tier2BundleIds: ["tier2.app"],
            finder: finder,
            workspaceSource: ws
        )
        await coord.startMonitoring()
        try await Task.sleep(for: .milliseconds(50))

        await finder.add(bundleId: "tier1.app", pid: 5002)
        ws.emit(.appActivated(pid: 5002, bundleId: "tier1.app"))
        try await Task.sleep(for: .milliseconds(150))

        let frozen = await stub.currentlyFrozen()
        XCTAssertTrue(frozen.isEmpty,
                      "под .normal новый tier-1 app не должен морозиться")
        await coord.stopMonitoring()
    }

    /// `.appActivated` для tier-2 bundle под `.warning` НЕ морозит
    /// (tier-2 требует `.critical`). Под `.critical` — морозит.
    func testAppActivatedTier2RespectsCriticalThreshold() async throws {
        let pressureSrc = FakeMemoryPressureSource()
        let monitor = MemoryPressureMonitor(source: pressureSrc, cooldownSeconds: 0.5)
        let stub = StubVortex()
        let finder = MutableStubFinder([:])
        let mlx = MLXSupervisor()
        let ws = FakeWorkspaceEventSource()
        let coord = VortexCoordinator(
            mlx: mlx,
            vortex: stub,
            monitor: monitor,
            tier1BundleIds: ["tier1.app"],
            tier2BundleIds: ["tier2.app"],
            finder: finder,
            workspaceSource: ws,
            gradualThawDelaySeconds: 0.1
        )
        await coord.startMonitoring()
        try await Task.sleep(for: .milliseconds(50))

        // Pressure .warning. Tier-2 app запускается — НЕ должен морозиться
        // (tier-2 требует .critical).
        pressureSrc.emit(.warning)
        try await Task.sleep(for: .milliseconds(150))

        await finder.add(bundleId: "tier2.app", pid: 6001)
        ws.emit(.appActivated(pid: 6001, bundleId: "tier2.app"))
        try await Task.sleep(for: .milliseconds(150))

        let frozenAtWarning = await stub.currentlyFrozen()
        XCTAssertTrue(frozenAtWarning.isEmpty,
                      "tier-2 не должен морозиться под .warning")

        // Pressure эскалирует до .critical. Тот же tier-2 app — должен
        // быть заморожен через `applyPolicy(.critical)` path (level
        // change triggers freezeTier).
        pressureSrc.emit(.critical)
        try await Task.sleep(for: .milliseconds(200))

        let frozenAtCritical = await stub.currentlyFrozen()
        XCTAssertEqual(frozenAtCritical, [6001],
                       "tier-2 морозится на .critical")
        await coord.stopMonitoring()
    }
}
