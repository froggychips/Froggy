import Foundation

/// Внутренний throttle: пропускает кадры не чаще, чем раз в `interval`.
///
/// Зачем: SCStream может выдавать кадры быстрее, чем `captureIntervalSeconds`
/// (например, при анимациях или scrolling'е, где compositor поднимает rate
/// принудительно), а внешний `Task.sleep` между cycles — слабая защита: один
/// длинный cycle сдвигает фазу, и следующий запускается на максимальной
/// скорости. Pacer работает на каждом frame entry point и **отбрасывает**
/// (не буферизует) кадры, пришедшие слишком рано.
///
/// Использует монотонный `ContinuousClock` — wall-clock (`Date`) прыгает при
/// system time sync и сломал бы pacing в обе стороны.
///
/// ADR 0011 / FCP-1.
struct FramePacer {
    /// Минимальный интервал между admitted кадрами. `.zero` — отключение
    /// throttle'а (пропускать всё).
    let interval: Duration

    /// Время-источник. Параметризован для unit-тестов: продакшн использует
    /// `ContinuousClock.now`, тесты — fake-instant, сдвигаемый вручную.
    private let now: @Sendable () -> ContinuousClock.Instant

    /// Момент последнего admitted кадра. nil — ещё ни одного кадра не было.
    private var lastAdmitted: ContinuousClock.Instant?

    init(
        interval: Duration,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.interval = interval
        self.now = now
    }

    /// Решает, обрабатывать ли текущий кадр. Если возвращает `true` —
    /// обновляет `lastAdmitted` и считает кадр admitted (никакой буферизации).
    /// Если `false` — кадр **дропается**, вызывающий код не должен ничего
    /// делать.
    ///
    /// Edge cases:
    /// - `interval == .zero` → всегда `true` (throttle выключен).
    /// - первый вызов (нет предыдущего admit) → всегда `true`.
    /// - long-idle (например 10× `interval` с прошлого admit'а) → `true`,
    ///   без накопления долга или burst'а: фиксируем «сейчас» как новый
    ///   anchor, никаких backlog'ов нет (ровно как требует FCP-1: «без
    ///   буферизации»).
    mutating func shouldAdmit() -> Bool {
        // interval == .zero — throttle выключен, любой кадр проходит.
        // Не обновляем lastAdmitted: это ускоряет hot path и упрощает
        // семантику (пропустить throttle = pacer вообще не у дел).
        guard interval > .zero else { return true }

        let t = now()
        if let last = lastAdmitted {
            // ContinuousClock.Instant.duration(to:) даёт знаковую Duration;
            // отрицательную (в теории невозможную для монотонных часов) на
            // всякий случай тоже считаем «прошло достаточно».
            let elapsed = last.duration(to: t)
            if elapsed >= .zero, elapsed < interval {
                return false
            }
        }
        lastAdmitted = t
        return true
    }
}
