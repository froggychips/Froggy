import Foundation

/// Issue #64: явное состояние lifecycle'а `VortexCoordinator`.
///
/// До этого coordinator имел неявное состояние, размазанное по
/// `listenTask: Task?` / `workspaceTask: Task?` / `sleeping: Bool` /
/// факту наличия живого MLX worker'а — диагностика «почему демон не
/// реагирует на pressure event» требовала reverse-engineer'инга
/// какая комбинация nil/non-nil считается «нормально».
///
/// Жизненный цикл:
/// * **idle** — supervisor создан, монитор не запущен (`startMonitoring`
///   ещё не вызван). Pressure events игнорятся, freeze не работает.
/// * **starting** — `startMonitoring` в процессе: подписка на
///   `MemoryPressureMonitor`, регистрация crash observer'а.
///   Короткоживущее, не должно быть видно из IPC надолго.
/// * **ready** — монитор работает. Worker может быть не загружен — это
///   валидное состояние (`coordinator.loadModel` ещё не вызван), но
///   freeze-logic активна и реагирует на pressure events.
/// * **degraded** — MLX worker крашнулся неожиданно (не через
///   `unloadModel`). Pressure monitor остался жить и продолжает freeze
///   по tier'ам; LLM-операции (load/generate) недоступны до recovery.
///   `reason` — короткая структурная строка для логов/IPC, не для UI.
/// * **recovering** — `loadModel` в процессе после `degraded`. Промежуточный
///   transient state — успех ⇒ ready, неудача ⇒ обратно degraded.
/// * **stopping** — `stopMonitoring` в процессе. Cancel'им task'и,
///   emergency thaw, идём в idle.
public enum CoordinatorState: Sendable, Equatable {
    case idle
    case starting
    case ready
    case degraded(reason: String)
    case recovering
    case stopping

    /// Стабильный strings name для логов / IPC / тестов.
    /// `degraded` сам по себе без `reason` — payload идёт отдельно.
    public var name: String {
        switch self {
        case .idle:       return "idle"
        case .starting:   return "starting"
        case .ready:      return "ready"
        case .degraded:   return "degraded"
        case .recovering: return "recovering"
        case .stopping:   return "stopping"
        }
    }

    /// Только для `.degraded` — структурная причина (например,
    /// `mlx_crash_pid=12345_status=139`). nil для всех остальных.
    public var reason: String? {
        if case let .degraded(reason) = self { return reason }
        return nil
    }
}
