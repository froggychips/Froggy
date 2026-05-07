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
}
