import XCTest
@testable import LushaBridge

/// Интеграционные тесты pacing'а на уровне VisionActor: проверяем, что
/// внутренний `FramePacer` действительно подключён к pipeline'у и что
/// инжекция fake-clock через test seam работает.
///
/// SCStream здесь не дёргается — мы не запускаем capture loop. Тестируем
/// pacer-gate через `_admitForTest()` seam, имитируя несколько frame
/// arrivals с разной частотой.
final class VisionActorPacingTests: XCTestCase {

    private final class FakeClock: @unchecked Sendable {
        private let lock = NSLock()
        private var instant: ContinuousClock.Instant
        init() { self.instant = ContinuousClock.now }
        func now() -> ContinuousClock.Instant {
            lock.lock(); defer { lock.unlock() }
            return instant
        }
        func advance(by duration: Duration) {
            lock.lock(); defer { lock.unlock() }
            instant = instant.advanced(by: duration)
        }
    }

    /// 10 frames через 100ms при captureInterval=1s — pacer admitted ≤ 2.
    /// Воспроизводит acceptance-criteria FCP-1 на actor-уровне.
    func testActorAdmitsBoundedFramesUnderInterval() async {
        let clock = FakeClock()
        let v = VisionActor(captureInterval: .seconds(1))
        await v._setPacerClock(now: { clock.now() })

        var admitted = 0
        if await v._admitForTest() { admitted += 1 }
        for _ in 0..<9 {
            clock.advance(by: .milliseconds(100))
            if await v._admitForTest() { admitted += 1 }
        }

        XCTAssertLessThanOrEqual(admitted, 2,
            "Burst 10 frames @100ms / interval=1s → ≤2 admitted, got \(admitted)")
        XCTAssertGreaterThanOrEqual(admitted, 1)
    }

    /// captureInterval = 0 → pacer не throttle'ит.
    func testZeroIntervalAllowsAllFrames() async {
        let clock = FakeClock()
        let v = VisionActor(captureInterval: .zero)
        await v._setPacerClock(now: { clock.now() })

        var admitted = 0
        for _ in 0..<50 {
            if await v._admitForTest() { admitted += 1 }
        }
        XCTAssertEqual(admitted, 50)
    }

    /// Frame после long idle — admitted сразу.
    func testFrameAfterLongIdleAdmittedImmediately() async {
        let clock = FakeClock()
        let v = VisionActor(captureInterval: .seconds(1))
        await v._setPacerClock(now: { clock.now() })

        let first = await v._admitForTest()
        XCTAssertTrue(first)

        clock.advance(by: .seconds(60))
        let afterIdle = await v._admitForTest()
        XCTAssertTrue(afterIdle)
    }
}
