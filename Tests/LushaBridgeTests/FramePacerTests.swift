import XCTest
@testable import LushaBridge

/// Тесты внутреннего pacer'а (FCP-1, ADR 0011).
///
/// Не дёргают SCStream / OCR — pacer изолирован от capture pipeline'а
/// специально для дешёвой проверки временной логики. Time source —
/// fake-instant: стартуем от `ContinuousClock.now`, двигаем вручную.
final class FramePacerTests: XCTestCase {

    // MARK: - Helpers

    /// Fake clock: shared mutable instant. Все вызовы pacer'а читают
    /// текущее значение, тест двигает его руками. NSLock — потому что
    /// closure captured by pacer должна быть `@Sendable`.
    private final class FakeClock: @unchecked Sendable {
        private let lock = NSLock()
        private var instant: ContinuousClock.Instant
        init() {
            self.instant = ContinuousClock.now
        }
        func now() -> ContinuousClock.Instant {
            lock.lock(); defer { lock.unlock() }
            return instant
        }
        func advance(by duration: Duration) {
            lock.lock(); defer { lock.unlock() }
            instant = instant.advanced(by: duration)
        }
    }

    private func makePacer(
        interval: Duration,
        clock: FakeClock
    ) -> FramePacer {
        FramePacer(interval: interval, now: { clock.now() })
    }

    // MARK: - Спецификация FCP-1

    /// Основной кейс из ADR: SCStream шлёт быстрее, чем captureInterval.
    /// Симулируем 10 frames через 100ms при interval=1s → должно быть
    /// admitted ровно 1 (первый), плюс возможно 1 на boundary'е окна.
    func testThrottlesBurstFramesUnderInterval() {
        let clock = FakeClock()
        var pacer = makePacer(interval: .seconds(1), clock: clock)

        var admitted = 0
        // Frame 0 — t=0 (мгновенно после старта).
        if pacer.shouldAdmit() { admitted += 1 }
        // Frame 1..9 — каждые 100ms, итого до t=900ms.
        for _ in 0..<9 {
            clock.advance(by: .milliseconds(100))
            if pacer.shouldAdmit() { admitted += 1 }
        }

        XCTAssertLessThanOrEqual(
            admitted, 2,
            "FCP-1: 10 frames @100ms при interval=1s → ≤2 admitted, got \(admitted)"
        )
        XCTAssertGreaterThanOrEqual(
            admitted, 1,
            "Хотя бы первый frame должен пройти"
        )
    }

    /// Edge: interval == .zero → throttle отключён, все кадры проходят.
    func testZeroIntervalAdmitsAllFrames() {
        let clock = FakeClock()
        var pacer = makePacer(interval: .zero, clock: clock)

        var admitted = 0
        for _ in 0..<100 {
            // Время не двигаем сознательно — даже без advance pacer
            // должен пропускать каждый кадр (throttle off).
            if pacer.shouldAdmit() { admitted += 1 }
        }
        XCTAssertEqual(admitted, 100, "interval=.zero — все frames должны проходить")
    }

    /// Edge: один frame после long-idle (≫ interval) — проходит без задержки.
    func testFrameAfterLongIdleAdmits() {
        let clock = FakeClock()
        var pacer = makePacer(interval: .seconds(1), clock: clock)

        // Первый кадр — admitted.
        XCTAssertTrue(pacer.shouldAdmit())

        // Long idle — 30 секунд тишины.
        clock.advance(by: .seconds(30))

        // Очередной кадр должен быть admitted сразу — никакого «отдыха»
        // или backlog'а: pacer не накапливает долг.
        XCTAssertTrue(
            pacer.shouldAdmit(),
            "После long-idle pacer обязан пропустить frame без задержки"
        )

        // И сразу после — снова burst: должен дропнуть.
        clock.advance(by: .milliseconds(100))
        XCTAssertFalse(
            pacer.shouldAdmit(),
            "Сразу после admitted-кадра окно должно быть закрыто"
        )
    }

    /// На границе окна (ровно `interval` после прошлого admit'а) кадр
    /// проходит — иначе при regular-rate consumer'е (точно matching SCStream)
    /// мы бы дропали каждый второй.
    func testFrameExactlyAtIntervalBoundaryAdmits() {
        let clock = FakeClock()
        var pacer = makePacer(interval: .seconds(1), clock: clock)

        XCTAssertTrue(pacer.shouldAdmit())
        clock.advance(by: .seconds(1))
        XCTAssertTrue(
            pacer.shouldAdmit(),
            "Frame ровно через interval должен быть admitted (>= interval)"
        )
    }

    /// Регулярный rate ровно на interval: ни одного дропа.
    func testRegularRateAtIntervalAllAdmitted() {
        let clock = FakeClock()
        var pacer = makePacer(interval: .seconds(1), clock: clock)

        var admitted = 0
        if pacer.shouldAdmit() { admitted += 1 }
        for _ in 0..<5 {
            clock.advance(by: .seconds(1))
            if pacer.shouldAdmit() { admitted += 1 }
        }
        XCTAssertEqual(admitted, 6)
    }

    /// Защита от clock skew: pacer использует `ContinuousClock` —
    /// гарантия монотонности на уровне типа. Этот тест документирует
    /// контракт (compile-time check'ом импорта Foundation, не trip'ом
    /// wall-clock).
    func testUsesMonotonicClock() {
        // Этот тест — чисто документация: если в будущем кто-то заменит
        // ContinuousClock на Date, тип closure не сойдётся (Date != Instant).
        let now: @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
        var pacer = FramePacer(interval: .seconds(1), now: now)
        _ = pacer.shouldAdmit()
    }
}
