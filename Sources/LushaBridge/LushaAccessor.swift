import AppKit
import Foundation

/// Pluggable «датчик контекста». Каждый аксессор отвечает за один источник
/// (OCR экрана, текущий frontmost app, в будущем — календарь, почта, браузер).
public protocol LushaAccessor: Sendable {
    var id: String { get }
    var name: String { get }
    func snapshot() async -> [String]
}

/// Реестр зарегистрированных аксессоров. Используется демоном и IPC-handler-ом.
public actor AccessorRegistry {
    public struct Descriptor: Sendable, Equatable {
        public let id: String
        public let name: String
    }

    private var accessors: [String: any LushaAccessor] = [:]

    public init() {}

    public func register(_ accessor: any LushaAccessor) {
        accessors[accessor.id] = accessor
    }

    public func list() -> [Descriptor] {
        accessors.values
            .map { Descriptor(id: $0.id, name: $0.name) }
            .sorted { $0.id < $1.id }
    }

    public func snapshot(id: String) async -> [String]? {
        guard let accessor = accessors[id] else { return nil }
        return await accessor.snapshot()
    }
}

// MARK: - Built-in accessors

/// Возвращает последние OCR-строки из `ContextStore` (без re-capture экрана).
public struct OCRAccessor: LushaAccessor {
    public let id = "ocr"
    public let name = "Screen OCR"
    private let store: ContextStore

    public init(store: ContextStore) {
        self.store = store
    }

    public func snapshot() async -> [String] {
        let snaps = await store.snapshots()
        return snaps.last?.lines ?? []
    }
}

/// Возвращает имя и bundle ID текущего активного приложения.
public struct FrontmostAppAccessor: LushaAccessor {
    public let id = "frontmost"
    public let name = "Frontmost Application"

    public init() {}

    public func snapshot() async -> [String] {
        await MainActor.run {
            guard let app = NSWorkspace.shared.frontmostApplication else { return [] }
            return [
                "name=\(app.localizedName ?? "")",
                "bundleId=\(app.bundleIdentifier ?? "")",
                "pid=\(app.processIdentifier)",
            ]
        }
    }
}
