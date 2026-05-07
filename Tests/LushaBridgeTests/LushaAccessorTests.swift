import XCTest
@testable import LushaBridge

private struct StubAccessor: LushaAccessor {
    let id: String
    let name: String
    let lines: [String]
    var experimental: Bool = false
    func snapshot() async -> [String] { lines }
}

/// Регистратор-пустышка для `AccessorRegistrar`-теста: добавляет известный
/// набор stub-аксессоров. Проверяет, что main.swift может полагаться на
/// конвенциональную регистрацию без знания о конкретных типах.
private struct StubRegistrar: AccessorRegistrar {
    let accessors: [StubAccessor]
    func register(into registry: AccessorRegistry) async {
        for a in accessors { await registry.register(a) }
    }
}

final class LushaAccessorTests: XCTestCase {
    func testRegistryListAndSnapshot() async {
        let registry = AccessorRegistry()
        await registry.register(StubAccessor(id: "a", name: "Alpha", lines: ["one"]))
        await registry.register(StubAccessor(id: "b", name: "Beta", lines: ["two", "three"]))

        let descriptors = await registry.list()
        XCTAssertEqual(descriptors.map(\.id), ["a", "b"])
        XCTAssertEqual(descriptors.first?.name, "Alpha")

        let snapA = await registry.snapshot(id: "a")
        XCTAssertEqual(snapA, ["one"])
        let snapB = await registry.snapshot(id: "b")
        XCTAssertEqual(snapB, ["two", "three"])
    }

    func testUnknownIdReturnsNil() async {
        let registry = AccessorRegistry()
        await registry.register(StubAccessor(id: "a", name: "Alpha", lines: ["x"]))
        let snap = await registry.snapshot(id: "missing")
        XCTAssertNil(snap)
    }

    func testReregisterOverwrites() async {
        let registry = AccessorRegistry()
        await registry.register(StubAccessor(id: "a", name: "v1", lines: ["v1"]))
        await registry.register(StubAccessor(id: "a", name: "v2", lines: ["v2"]))
        let descriptors = await registry.list()
        XCTAssertEqual(descriptors.count, 1)
        XCTAssertEqual(descriptors.first?.name, "v2")
        let snap = await registry.snapshot(id: "a")
        XCTAssertEqual(snap, ["v2"])
    }

    func testOCRAccessorReadsLatestSnapshot() async {
        let store = ContextStore(capacity: 5)
        await store.push(lines: ["older"])
        await store.push(lines: ["newest one", "newest two"])
        let accessor = OCRAccessor(store: store)
        let snap = await accessor.snapshot()
        XCTAssertEqual(snap, ["newest one", "newest two"])
    }

    func testOCRAccessorReturnsEmptyWhenStoreEmpty() async {
        let store = ContextStore(capacity: 5)
        let accessor = OCRAccessor(store: store)
        let snap = await accessor.snapshot()
        XCTAssertEqual(snap, [])
    }

    // MARK: - EXP-1: experimental flag + AccessorRegistrar protocol

    func testDefaultExperimentalIsFalse() async {
        // Existing accessors не должны пометиться experimental случайно —
        // default value protocol-extension гарантирует false.
        let frontmost = FrontmostAppAccessor()
        XCTAssertFalse(frontmost.experimental)
        let ocr = OCRAccessor(store: ContextStore(capacity: 1))
        XCTAssertFalse(ocr.experimental)
    }

    func testRegistryListIncludesExperimentalFlag() async {
        let registry = AccessorRegistry()
        await registry.register(StubAccessor(id: "core", name: "Core", lines: []))
        await registry.register(
            StubAccessor(id: "exp", name: "Exp", lines: [], experimental: true)
        )
        let descriptors = await registry.list()
        XCTAssertEqual(descriptors.map(\.id), ["core", "exp"])
        XCTAssertEqual(descriptors.first?.experimental, false)
        XCTAssertEqual(descriptors.last?.experimental, true)
    }

    func testRegistryFiltersByExperimentalFlag() async {
        let registry = AccessorRegistry()
        await registry.register(StubAccessor(id: "a", name: "A", lines: []))
        await registry.register(StubAccessor(id: "b", name: "B", lines: []))
        await registry.register(
            StubAccessor(id: "x", name: "X", lines: [], experimental: true)
        )
        let core = await registry.list(experimental: false)
        XCTAssertEqual(core.map(\.id), ["a", "b"])
        let exp = await registry.list(experimental: true)
        XCTAssertEqual(exp.map(\.id), ["x"])
        let all = await registry.list(experimental: nil)
        XCTAssertEqual(all.map(\.id), ["a", "b", "x"])
    }

    func testAccessorRegistrarAccumulatesIntoRegistry() async {
        // Конвенциональная регистрация: список регистраторов → registry,
        // ровно как делает FroggyDaemon/main.swift.
        let registry = AccessorRegistry()
        let registrars: [any AccessorRegistrar] = [
            StubRegistrar(accessors: [
                StubAccessor(id: "core1", name: "Core1", lines: ["c1"]),
                StubAccessor(id: "core2", name: "Core2", lines: ["c2"]),
            ]),
            StubRegistrar(accessors: [
                StubAccessor(id: "exp1", name: "Exp1", lines: ["e1"], experimental: true),
            ]),
        ]
        for registrar in registrars {
            await registrar.register(into: registry)
        }
        let all = await registry.list()
        XCTAssertEqual(all.map(\.id), ["core1", "core2", "exp1"])
        XCTAssertEqual(all.last?.experimental, true)
        let snap = await registry.snapshot(id: "exp1")
        XCTAssertEqual(snap, ["e1"])
    }

    func testLushaBridgeRegistrarRegistersCoreAccessors() async {
        // Reality-check: built-in регистратор core-аксессоров действительно
        // подключает оба известных аксессора и оба не-experimental.
        let registry = AccessorRegistry()
        let store = ContextStore(capacity: 5)
        await LushaBridgeRegistrar(contextStore: store).register(into: registry)
        let descriptors = await registry.list()
        let ids = descriptors.map(\.id).sorted()
        XCTAssertEqual(ids, ["frontmost", "ocr"])
        XCTAssertTrue(descriptors.allSatisfy { $0.experimental == false })
    }
}
