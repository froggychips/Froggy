import Foundation

/// Узкий интерфейс `VortexActor`, нужный `VortexCoordinator`-у.
/// Существует ради тестов: тесты подменяют его на in-memory реализацию
/// без `kill()`.
public protocol VortexFreezing: Sendable {
    @discardableResult
    func freezeProcess(pid: Int32) async throws -> Int32
    func thawProcess(pid: Int32) async
    func thawAll() async
    func suspendedCount() async -> Int
    /// Текущие счётчики pageout (если pageout вообще включён).
    /// Default-implementation возвращает nil — для тестовых стабов.
    func pageoutCounters() async -> PageoutCounters?
}

extension VortexFreezing {
    public func pageoutCounters() async -> PageoutCounters? { nil }
}

extension VortexActor: VortexFreezing {}
