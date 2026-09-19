import XCTest
@testable import VortexCore

/// ADR 0017: master switch `freezingEnabled`. Когда выключен — координатор
/// игнорит pressure-эвенты, никаких SIGSTOP'ов. При переключении в false
/// сразу размораживает всё, что было заморожено до этого.
private actor StubVortexForToggle: VortexFreezing {
    private(set) var frozen: Set<Int32> = []
    private(set) var thawCalls: Int = 0
    private(set) var freezeCallsLog: [Int32] = []

    func freezeProcess(pid: Int32) async throws -> Int32 {
        freezeCallsLog.append(pid)
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
    func freezeCalls() -> [Int32] { freezeCallsLog }
}

/// Одноразовый шлагбаум для стабов: стаб зовёт `arrive()` и виснет до
/// `open()`; тест ждёт `arrived()`, делает своё и открывает. `abort()` —
/// watchdog: снимает всех ждущих, чтобы тест упал ассертом, а не завис.
private actor TestGate {
    private var arrivedFlag = false
    private var arrivedWaiters: [CheckedContinuation<Bool, Never>] = []
    private var opened = false
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    /// Стаб: отметить приход и ждать открытия (после `open()` — не ждёт).
    func arrive() async {
        arrivedFlag = true
        resumeArrived(with: true)
        if opened { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            openWaiters.append(c)
        }
    }

    /// Тест: дождаться, пока стаб дойдёт до `arrive()`. false — снято `abort()`.
    func arrived() async -> Bool {
        if arrivedFlag { return true }
        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            arrivedWaiters.append(c)
        }
    }

    /// Тест: отпустить стаб (и все последующие `arrive()`).
    func open() {
        opened = true
        let waiters = openWaiters
        openWaiters.removeAll()
        for w in waiters { w.resume() }
    }

    func abort() {
        resumeArrived(with: false)
        open()
    }

    private func resumeArrived(with value: Bool) {
        let waiters = arrivedWaiters
        arrivedWaiters.removeAll()
        for w in waiters { w.resume(returning: value) }
    }
}

/// Finder, который на lookup'е `gatedBundleId` останавливается на шлагбауме —
/// имитирует медленный NSWorkspace-lookup, чтобы выключить freeze ПОСЕРЕДИНЕ
/// обхода tier'а (между bundleId'ами) детерминированно, а не по таймеру.
private actor GatedToggleFinder: ProcessFinder {
    private let mapping: [String: [Int32]]
    private let gate: TestGate
    private let gatedBundleId: String

    init(_ mapping: [String: [Int32]], gate: TestGate, gatedBundleId: String) {
        self.mapping = mapping
        self.gate = gate
        self.gatedBundleId = gatedBundleId
    }

    func pids(forBundleIds bundleIds: [String]) async -> [Int32] {
        if bundleIds.contains(gatedBundleId) { await gate.arrive() }
        return bundleIds.flatMap { mapping[$0] ?? [] }
    }
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

    /// Off посередине обхода: tier-1 = два bundleId, finder второго висит на
    /// шлагбауме. Первый pid заморожен, затем пользователь выключает freeze
    /// (emergencyThaw), и обход, вернувшись из `finder.pids`, обязан
    /// прерваться — до фикса второй pid оказывался в SIGSTOP уже ПОСЛЕ Off и
    /// сидел там до следующего thaw (review 2026-09-19).
    func testToggleOffDuringTraversalAbortsRemainingFreezes() async throws {
        let src = FakeMemoryPressureSource()
        let monitor = MemoryPressureMonitor(source: src, cooldownSeconds: 0.5)
        let stub = StubVortexForToggle()
        let gate = TestGate()
        let finder = GatedToggleFinder([
            "tier1a.app": [1001],
            "tier1b.app": [1002],
        ], gate: gate, gatedBundleId: "tier1b.app")
        let mlx = MLXSupervisor()
        let coord = VortexCoordinator(
            mlx: mlx,
            vortex: stub,
            monitor: monitor,
            tier1BundleIds: ["tier1a.app", "tier1b.app"],
            tier2BundleIds: [],
            finder: finder,
            gradualThawDelaySeconds: 0.1,
            freezingEnabled: true
        )
        await coord.startMonitoring()

        src.emit(.warning)
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(3))
            await gate.abort()
        }
        let arrived = await gate.arrived()
        watchdog.cancel()
        XCTAssertTrue(arrived, "обход не дошёл до lookup второго bundleId за 3 с")

        // Здесь: 1001 заморожен, обход висит на finder.pids(["tier1b.app"]).
        let frozenMid = await stub.currentlyFrozen()
        XCTAssertEqual(frozenMid, [1001])

        // Off во время обхода: emergencyThaw отпускает 1001 и меняет поколение.
        await coord.setFreezingEnabled(false)
        await gate.open()
        // Обход возвращается из finder и должен прерваться без freezeProcess(1002).
        // Отрицательное утверждение — даём короткое время «отстояться».
        try await Task.sleep(for: .milliseconds(200))

        let frozen = await stub.currentlyFrozen()
        XCTAssertTrue(frozen.isEmpty, "после Off ни один pid не должен остаться в SIGSTOP: \(frozen)")
        let calls = await stub.freezeCalls()
        XCTAssertEqual(calls, [1001], "второй bundleId не должен морозиться после Off: \(calls)")
        let snap = await coord.pressureSnapshot()
        XCTAssertTrue(snap.tier1Frozen.isEmpty)
        await coord.stopMonitoring()
    }
}
