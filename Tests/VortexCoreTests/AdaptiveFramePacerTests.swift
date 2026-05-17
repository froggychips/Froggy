import Foundation
import XCTest
@testable import LushaBridge

/// Issue #59: adaptive `FramePacer` под уровень memory pressure.
///
/// Unit-тесты на `VisionActor.adjustPacerForPressure` напрямую — без
/// прогона через VortexCoordinator/MemoryPressureMonitor (debounce-cooldown
/// покрыт собственными `MemoryPressureMonitorTests`).
final class AdaptiveFramePacerTests: XCTestCase {

    /// Базовый interval = 2с, default multipliers 2.0/4.0.
    /// .warning → 4с, .critical → 8с, .normal → обратно 2с.
    func testWarningStretchesInterval() async {
        let vision = VisionActor(
            captureInterval: .seconds(2),
            contextStore: nil,
            warningMultiplier: 2.0,
            criticalMultiplier: 4.0
        )
        let baseBefore = await vision.currentPacerInterval()
        XCTAssertEqual(baseBefore, .seconds(2))

        await vision.adjustPacerForPressure(.warning)
        let warning = await vision.currentPacerInterval()
        XCTAssertEqual(warning, .seconds(4), "warning × 2.0 = 4с")
    }

    func testCriticalStretchesInterval() async {
        let vision = VisionActor(
            captureInterval: .seconds(2),
            contextStore: nil,
            warningMultiplier: 2.0,
            criticalMultiplier: 4.0
        )
        await vision.adjustPacerForPressure(.critical)
        let crit = await vision.currentPacerInterval()
        XCTAssertEqual(crit, .seconds(8), "critical × 4.0 = 8с")
    }

    func testNormalReturnsToBase() async {
        let vision = VisionActor(
            captureInterval: .seconds(2),
            contextStore: nil
        )
        await vision.adjustPacerForPressure(.critical)
        let before = await vision.currentPacerInterval()
        XCTAssertEqual(before, .seconds(8))

        await vision.adjustPacerForPressure(.normal)
        let after = await vision.currentPacerInterval()
        XCTAssertEqual(after, .seconds(2), ".normal возвращает к base captureInterval")
    }

    /// Issue #59 acceptance: «никогда не падает ниже configured min».
    /// Multipliers < 1.0 clamp'ятся в [1.0, ∞) — pacer не ускоряется на pressure.
    func testMultiplierBelowOneIsClampedToOne() async {
        let vision = VisionActor(
            captureInterval: .seconds(2),
            contextStore: nil,
            warningMultiplier: 0.5,   // невалидно — clamp в 1.0
            criticalMultiplier: 0.1   // невалидно — clamp в 1.0
        )
        await vision.adjustPacerForPressure(.warning)
        let warning = await vision.currentPacerInterval()
        XCTAssertEqual(warning, .seconds(2), "warning multiplier <1.0 clamp'нут в 1.0 → base")

        await vision.adjustPacerForPressure(.critical)
        let crit = await vision.currentPacerInterval()
        XCTAssertEqual(crit, .seconds(2), "critical multiplier <1.0 clamp'нут в 1.0 → base")
    }

    /// Кастомные multipliers из config.
    func testCustomMultipliers() async {
        let vision = VisionActor(
            captureInterval: .seconds(1),
            contextStore: nil,
            warningMultiplier: 3.0,
            criticalMultiplier: 10.0
        )
        await vision.adjustPacerForPressure(.warning)
        let warnInt = await vision.currentPacerInterval()
        XCTAssertEqual(warnInt, .seconds(3))
        await vision.adjustPacerForPressure(.critical)
        let critInt = await vision.currentPacerInterval()
        XCTAssertEqual(critInt, .seconds(10))
    }

    /// Идемпотентность: повторный вызов с тем же level — no-op (pacer не
    /// пересоздаётся, last admit window сохраняется).
    func testIdempotentSameLevel() async {
        let vision = VisionActor(
            captureInterval: .seconds(2),
            contextStore: nil
        )
        await vision.adjustPacerForPressure(.warning)
        let first = await vision.currentPacerInterval()
        await vision.adjustPacerForPressure(.warning)
        let second = await vision.currentPacerInterval()
        XCTAssertEqual(first, second)
    }
}
