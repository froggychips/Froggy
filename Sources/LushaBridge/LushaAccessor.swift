import AppKit
import Foundation

/// Pluggable «датчик контекста». Каждый аксессор отвечает за один источник
/// (OCR экрана, текущий frontmost app, в будущем — календарь, почта, браузер).
///
/// `experimental` — маркер для опытных аксессоров, живущих в отдельном
/// target'е (`LushaExperimental`). См. ADR 0011 § EXP-1: registration
/// должен быть generic, чтобы новые experimental-аксессоры подключались
/// без правки `Sources/FroggyDaemon/main.swift`. Default `false` —
/// existing accessors не требуют миграции.
public protocol LushaAccessor: Sendable {
    var id: String { get }
    var name: String { get }
    var experimental: Bool { get }
    func snapshot() async -> [String]
}

extension LushaAccessor {
    public var experimental: Bool { false }
}

/// Реестр зарегистрированных аксессоров. Используется демоном и IPC-handler-ом.
public actor AccessorRegistry {
    public struct Descriptor: Sendable, Equatable {
        public let id: String
        public let name: String
        public let experimental: Bool

        public init(id: String, name: String, experimental: Bool = false) {
            self.id = id
            self.name = name
            self.experimental = experimental
        }
    }

    private var accessors: [String: any LushaAccessor] = [:]

    public init() {}

    public func register(_ accessor: any LushaAccessor) {
        accessors[accessor.id] = accessor
    }

    /// Полный список без фильтрации.
    public func list() -> [Descriptor] {
        accessors.values
            .map { Descriptor(id: $0.id, name: $0.name, experimental: $0.experimental) }
            .sorted { $0.id < $1.id }
    }

    /// Список с фильтром по `experimental`. `nil` — без фильтра.
    public func list(experimental: Bool?) -> [Descriptor] {
        let all = list()
        guard let flag = experimental else { return all }
        return all.filter { $0.experimental == flag }
    }

    public func snapshot(id: String) async -> [String]? {
        guard let accessor = accessors[id] else { return nil }
        return await accessor.snapshot()
    }
}

/// Generic registration entry-point. Каждый модуль (core / experimental /
/// future) предоставляет `AccessorRegistrar`, который знает только про
/// свои собственные аксессоры. `main.swift` принимает list of registrars
/// и не правится при добавлении нового модуля — нужен один import + одна
/// строка в инициализации.
public protocol AccessorRegistrar: Sendable {
    func register(into registry: AccessorRegistry) async
}

/// Регистрар core-аксессоров `LushaBridge` (OCR + frontmost). Вынесен сюда,
/// чтобы `main.swift` не знал о конкретных типах: достаточно вызвать
/// `LushaBridgeRegistrar(...).register(into: registry)`.
public struct LushaBridgeRegistrar: AccessorRegistrar {
    private let store: ContextStore

    public init(contextStore: ContextStore) {
        self.store = contextStore
    }

    public func register(into registry: AccessorRegistry) async {
        await registry.register(OCRAccessor(store: store))
        await registry.register(FrontmostAppAccessor())
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
