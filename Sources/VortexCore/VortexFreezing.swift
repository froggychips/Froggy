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
}

extension VortexActor: VortexFreezing {}
