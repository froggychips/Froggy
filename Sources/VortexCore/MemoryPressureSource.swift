import Dispatch
import Foundation
import os

/// Уровень давления на unified memory. `.normal < .warning < .critical`.
/// Сигналит ядро через `dispatch_source_memorypressure`.
public enum MemoryPressureLevel: String, Sendable, Codable, Comparable {
    case normal
    case warning
    case critical

    private var rank: Int {
        switch self {
        case .normal:   return 0
        case .warning:  return 1
        case .critical: return 2
        }
    }

    public static func < (lhs: MemoryPressureLevel, rhs: MemoryPressureLevel) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// Источник событий давления. Абстрагирован, чтобы тесты могли подменять
/// `DispatchMemoryPressureSource` на `FakeMemoryPressureSource`.
public protocol MemoryPressureSource: Sendable {
    func events() -> AsyncStream<MemoryPressureLevel>
}

/// Реальный источник: оборачивает `DispatchSource.makeMemoryPressureSource`.
/// Подписка нескольких слушателей через broadcast.
public final class DispatchMemoryPressureSource: MemoryPressureSource, @unchecked Sendable {
    private static let log = Logger(subsystem: "com.froggychips.froggy", category: "pressure-source")
    /// Signposter для time-correlated визуализации в Instruments.
    /// Каждое событие давления — точка на timeline; см. ADR-кандидат
    /// "observability via OS signposts".
    private static let signposter = OSSignposter(subsystem: "com.froggychips.froggy", category: "pressure")
    private static let poi = OSSignposter(subsystem: "com.froggychips.froggy", category: "PointsOfInterest")

    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<MemoryPressureLevel>.Continuation] = [:]
    private let dispatchSource: DispatchSourceMemoryPressure

    public init(queue: DispatchQueue = .global(qos: .utility)) {
        let src = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: queue
        )
        self.dispatchSource = src
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let mask = src.mask
            let level: MemoryPressureLevel
            if mask.contains(.critical) { level = .critical }
            else if mask.contains(.warning) { level = .warning }
            else { level = .normal }
            Self.log.info("dispatch pressure event: \(level.rawValue, privacy: .public)")
            // Signpost-event: видно как точку в Instruments timeline.
            // Параллельный POI-event для standard PointsOfInterest track.
            Self.signposter.emitEvent("pressure-level",
                                       "level=\(level.rawValue, privacy: .public)")
            Self.poi.emitEvent("pressure_level",
                                "level=\(level.rawValue, privacy: .public)")
            self.broadcast(level)
        }
        src.resume()
    }

    public func events() -> AsyncStream<MemoryPressureLevel> {
        AsyncStream { cont in
            let id = UUID()
            self.lock.lock()
            self.continuations[id] = cont
            self.lock.unlock()
            cont.onTermination = { [weak self] _ in
                self?.lock.lock()
                self?.continuations.removeValue(forKey: id)
                self?.lock.unlock()
            }
        }
    }

    private func broadcast(_ level: MemoryPressureLevel) {
        lock.lock()
        let snapshot = Array(continuations.values)
        lock.unlock()
        for c in snapshot { c.yield(level) }
    }
}

/// Тестовый источник: руками вызываем `emit(_:)`.
public final class FakeMemoryPressureSource: MemoryPressureSource, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<MemoryPressureLevel>.Continuation] = [:]

    public init() {}

    public func events() -> AsyncStream<MemoryPressureLevel> {
        AsyncStream { cont in
            let id = UUID()
            self.lock.lock()
            self.continuations[id] = cont
            self.lock.unlock()
            cont.onTermination = { [weak self] _ in
                self?.lock.lock()
                self?.continuations.removeValue(forKey: id)
                self?.lock.unlock()
            }
        }
    }

    public func emit(_ level: MemoryPressureLevel) {
        lock.lock()
        let snapshot = Array(continuations.values)
        lock.unlock()
        for c in snapshot { c.yield(level) }
    }
}
