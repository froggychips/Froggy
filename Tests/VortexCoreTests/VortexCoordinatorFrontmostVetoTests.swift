import Foundation
import XCTest
@testable import VortexCore

/// Stub-VortexFreezing — копия паттерна из VortexCoordinatorPolicyTests,
/// локальная (не делаем internal-leak между test-файлами).
private actor StubVortex: VortexFreezing {
    private(set) var frozen: Set<Int32> = []
    private(set) var thawed: [Int32] = []
    private(set) var freezeCallsLog: [Int32] = []

    func freezeProcess(pid: Int32) async throws -> Int32 {
        freezeCallsLog.append(pid)
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
    func freezeCalls() -> [Int32] { freezeCallsLog }
    func thawCalls() -> [Int32] { thawed }
}

private struct StubFinder: ProcessFinder {
    let mapping: [String: [Int32]]
    func pids(forBundleIds bundleIds: [String]) async -> [Int32] {
        bundleIds.flatMap { mapping[$0] ?? [] }
    }
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

/// Stub, чей `freezeProcess` останавливается на шлагбауме — имитирует
/// долгий SIGSTOP + journal + pageout реального `VortexActor`. Нужен, чтобы
/// сменить frontmost ВО ВРЕМЯ freeze — окно, которое обработчик
/// `frontmostChanged` не видит (pid ещё не в tier-set'е).
private actor GatedStubVortex: VortexFreezing {
    private(set) var frozen: Set<Int32> = []
    private(set) var thawed: [Int32] = []
    private let gate: TestGate

    init(gate: TestGate) { self.gate = gate }

    func freezeProcess(pid: Int32) async throws -> Int32 {
        await gate.arrive()
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
    func thawCalls() -> [Int32] { thawed }
}

/// AD-1 / ADR 0015: frontmost pid не попадает ни в tier-1, ни в tier-2 freeze,
/// даже если его bundleId в allowlist'е.
final class VortexCoordinatorFrontmostVetoTests: XCTestCase {
    private func makeCoordinator(
        workspaceSource: any WorkspaceEventSource,
        gradualThaw: TimeInterval = 0.05,
        tier1Pids: [Int32] = [1001, 1002],
        tier2Pids: [Int32] = [2001, 2002]
    ) -> (VortexCoordinator, FakeMemoryPressureSource, StubVortex) {
        let pressureSrc = FakeMemoryPressureSource()
        let monitor = MemoryPressureMonitor(source: pressureSrc, cooldownSeconds: 0.5)
        let stub = StubVortex()
        let finder = StubFinder(mapping: [
            "tier1.app": tier1Pids,
            "tier2.app": tier2Pids,
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

    /// Seed initial frontmost через `initialFrontmostPid()`. Pressure → warning,
    /// frontmost pid НЕ должен оказаться в tier1Frozen.
    func testInitialFrontmostSeedVetoesTier1() async throws {
        let ws = FakeWorkspaceEventSource(frontmostPid: 1001)
        let (coord, pressure, stub) = makeCoordinator(workspaceSource: ws)
        await coord.startMonitoring()
        try await Task.sleep(for: .milliseconds(50))

        pressure.emit(.warning)
        try await Task.sleep(for: .milliseconds(200))

        let frozen = await stub.currentlyFrozen()
        XCTAssertFalse(frozen.contains(1001),
                       "frontmost pid 1001 не должен быть заморожен через initialFrontmostPid seed")
        XCTAssertTrue(frozen.contains(1002),
                      "не-frontmost tier-1 pid 1002 должен быть заморожен")

        let snap = await coord.pressureSnapshot()
        XCTAssertFalse(snap.tier1Frozen.contains(1001))
        XCTAssertTrue(snap.tier1Frozen.contains(1002))
        await coord.stopMonitoring()
    }

    /// `frontmostChanged` event'ом меняется текущий frontmost; новый pressure-cycle
    /// морозит пред-frontmost'а (теперь не в фокусе) и veto'ит нового.
    func testFrontmostChangedEventUpdatesVeto() async throws {
        let ws = FakeWorkspaceEventSource(frontmostPid: 1001)
        let (coord, pressure, stub) = makeCoordinator(workspaceSource: ws)
        await coord.startMonitoring()
        try await Task.sleep(for: .milliseconds(50))

        // Меняем frontmost ДО pressure-event'а.
        ws.emit(.frontmostChanged(pid: 1002, bundleId: "tier1.app"))
        try await Task.sleep(for: .milliseconds(100))

        pressure.emit(.warning)
        try await Task.sleep(for: .milliseconds(200))

        let frozen = await stub.currentlyFrozen()
        XCTAssertTrue(frozen.contains(1001),
                      "1001 уже не frontmost — должен быть заморожен")
        XCTAssertFalse(frozen.contains(1002),
                       "1002 теперь frontmost — НЕ должен быть заморожен")
        await coord.stopMonitoring()
    }

    /// Frontmost pid в tier-2 allowlist'е тоже veto'ится — критичное свойство:
    /// frontmost-veto работает на оба tier'а одинаково.
    func testFrontmostVetoAppliesToTier2() async throws {
        let ws = FakeWorkspaceEventSource(frontmostPid: 2001)
        let (coord, pressure, stub) = makeCoordinator(workspaceSource: ws)
        await coord.startMonitoring()
        try await Task.sleep(for: .milliseconds(50))

        pressure.emit(.critical)
        try await Task.sleep(for: .milliseconds(200))

        let frozen = await stub.currentlyFrozen()
        XCTAssertFalse(frozen.contains(2001),
                       "frontmost pid в tier-2 allowlist'е не должен быть заморожен")
        XCTAssertTrue(frozen.contains(2002),
                      "не-frontmost tier-2 pid должен быть заморожен")
        // tier-1 морозится полностью — там frontmost pid'а нет.
        XCTAssertTrue(frozen.contains(1001))
        XCTAssertTrue(frozen.contains(1002))
        await coord.stopMonitoring()
    }

    /// `frontmostPid == nil` (login window / lock screen) — veto не применяется,
    /// морозим всё что в allowlist'е. Это deliberate behaviour: на lock-screen
    /// нет «активной набираемой текстом app», freeze безопасен.
    func testNilFrontmostDoesNotVetoAnything() async throws {
        let ws = FakeWorkspaceEventSource(frontmostPid: nil)
        let (coord, pressure, stub) = makeCoordinator(workspaceSource: ws)
        await coord.startMonitoring()
        try await Task.sleep(for: .milliseconds(50))

        pressure.emit(.warning)
        try await Task.sleep(for: .milliseconds(200))

        let frozen = await stub.currentlyFrozen()
        XCTAssertEqual(frozen, [1001, 1002],
                       "при nil frontmost морозим весь tier-1")
        await coord.stopMonitoring()
    }

    /// E2E lite: frontmost меняется во время freeze cycle. Морозим pressure'ом,
    /// потом юзер активирует уже-замороженный pid — coordinator должен
    /// thaw'нуть его моментально (закрывает race-окно).
    func testFrontmostActivatedMidFreezeIsThawed() async throws {
        let ws = FakeWorkspaceEventSource(frontmostPid: 9999) // некий not-in-allowlist pid
        let (coord, pressure, stub) = makeCoordinator(workspaceSource: ws)
        await coord.startMonitoring()
        try await Task.sleep(for: .milliseconds(50))

        // Pressure → warning → морозим весь tier-1 (1001, 1002).
        pressure.emit(.warning)
        try await Task.sleep(for: .milliseconds(200))

        var frozen = await stub.currentlyFrozen()
        XCTAssertEqual(frozen, [1001, 1002])

        // Юзер активирует 1001 — он уже заморожен. Coordinator должен оттаять
        // его сразу же.
        ws.emit(.frontmostChanged(pid: 1001, bundleId: "tier1.app"))
        try await Task.sleep(for: .milliseconds(150))

        frozen = await stub.currentlyFrozen()
        XCTAssertFalse(frozen.contains(1001),
                       "frontmost-activate уже-замороженного pid'а должен мгновенно оттаять его")
        XCTAssertTrue(frozen.contains(1002),
                      "1002 остаётся замороженным")

        let snap = await coord.pressureSnapshot()
        XCTAssertFalse(snap.tier1Frozen.contains(1001))
        await coord.stopMonitoring()
    }

    /// Freeze tier'а не трогает pid frontmost-app, даже если до этого никаких
    /// frontmost-event'ов не приходило (только seed).
    func testFreezeNeverIncludesFrontmostPidInLog() async throws {
        let ws = FakeWorkspaceEventSource(frontmostPid: 1001)
        let (coord, pressure, stub) = makeCoordinator(workspaceSource: ws)
        await coord.startMonitoring()
        try await Task.sleep(for: .milliseconds(50))

        pressure.emit(.critical)
        try await Task.sleep(for: .milliseconds(200))

        let calls = await stub.freezeCalls()
        XCTAssertFalse(calls.contains(1001),
                       "freezeProcess(pid: 1001) не должен быть вызван ни разу")
        await coord.stopMonitoring()
    }

    /// Реальный порядок событий `RealWorkspaceEventSource` при активации:
    /// `.frontmostChanged`, затем `.appActivated`. Под sustained `.warning`
    /// `.appActivated` перезапускает `freezeTier` — и он НЕ должен морозить
    /// только что активированный pid. До фикса порядок был обратным, и каждая
    /// активация tier-1 app давала SIGSTOP → SIGCONT (review 2026-09-19).
    func testRealActivationOrderDoesNotRefreezeActivatedApp() async throws {
        let ws = FakeWorkspaceEventSource(frontmostPid: 9999)
        let (coord, pressure, stub) = makeCoordinator(workspaceSource: ws, tier1Pids: [1001])
        await coord.startMonitoring()
        try await Task.sleep(for: .milliseconds(50))

        pressure.emit(.warning)
        try await Task.sleep(for: .milliseconds(200))
        let frozenBefore = await stub.currentlyFrozen()
        XCTAssertEqual(frozenBefore, [1001])

        // Порядок как у RealWorkspaceEventSource.handleAppNote(.activated).
        ws.emit(.frontmostChanged(pid: 1001, bundleId: "tier1.app"))
        ws.emit(.appActivated(pid: 1001, bundleId: "tier1.app"))
        try await Task.sleep(for: .milliseconds(200))

        let frozenAfter = await stub.currentlyFrozen()
        XCTAssertFalse(frozenAfter.contains(1001),
                       "активированное приложение не должно быть заморожено повторно")
        let calls = await stub.freezeCalls()
        XCTAssertEqual(calls.filter { $0 == 1001 }.count, 1,
                       "после активации freezeProcess(1001) не должен вызываться снова: \(calls)")
        let snap = await coord.pressureSnapshot()
        XCTAssertFalse(snap.tier1Frozen.contains(1001))
        await coord.stopMonitoring()
    }

    /// Frontmost меняется ВО ВРЕМЯ `await freezeProcess` (SIGSTOP уже послан,
    /// pid ещё не в tier-set'е — обработчик `frontmostChanged` его не видит).
    /// После возврата coordinator обязан откатить freeze сам: SIGCONT и не
    /// вставлять pid в tier-set (review 2026-09-19). Синхронизация — через
    /// шлагбаум в стабе, sleep только как watchdog/пейсинг опроса.
    func testFrontmostChangeDuringFreezeIsReverted() async throws {
        let ws = FakeWorkspaceEventSource(frontmostPid: 9999)
        let pressureSrc = FakeMemoryPressureSource()
        let monitor = MemoryPressureMonitor(source: pressureSrc, cooldownSeconds: 0.5)
        let gate = TestGate()
        let stub = GatedStubVortex(gate: gate)
        let finder = StubFinder(mapping: ["tier1.app": [1001]])
        let mlx = MLXSupervisor()
        let coord = VortexCoordinator(
            mlx: mlx,
            vortex: stub,
            monitor: monitor,
            tier1BundleIds: ["tier1.app"],
            tier2BundleIds: [],
            finder: finder,
            workspaceSource: ws,
            gradualThawDelaySeconds: 0.05
        )
        await coord.startMonitoring()

        pressureSrc.emit(.warning)
        // Ждём, пока coordinator войдёт в freezeProcess(1001) и повиснет.
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(3))
            await gate.abort()
        }
        let arrived = await gate.arrived()
        watchdog.cancel()
        XCTAssertTrue(arrived, "coordinator не дошёл до freezeProcess(1001) за 3 с")

        // Пользователь активирует 1001, пока его freeze ещё выполняется.
        ws.emit(.frontmostChanged(pid: 1001, bundleId: "tier1.app"))
        // Coordinator свободен (freezeTier висит на await) — дожидаемся,
        // пока он обработает событие, по наблюдаемому состоянию.
        var frontmostSeen = false
        for _ in 0..<200 {
            let current = await coord._testFrontmostPid()
            if current == 1001 { frontmostSeen = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(frontmostSeen, "frontmostChanged(1001) не обработан за 2 с")

        // Отпускаем freeze — он «завершается» уже при frontmost == 1001.
        await gate.open()
        var reverted = false
        for _ in 0..<200 {
            let thawed = await stub.thawCalls()
            if thawed.contains(1001) { reverted = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(reverted, "ожидали SIGCONT-откат freeze(1001) за 2 с")

        let frozen = await stub.currentlyFrozen()
        XCTAssertFalse(frozen.contains(1001),
                       "freeze должен быть откачен после смены frontmost во время await")
        let snap = await coord.pressureSnapshot()
        XCTAssertFalse(snap.tier1Frozen.contains(1001),
                       "pid не должен попасть в tier-set после отката")
        await coord.stopMonitoring()
    }
}
