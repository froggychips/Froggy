import XCTest
@testable import LushaBridge
@testable import LushaExperimental

final class LushaExperimentalTests: XCTestCase {
    func testRegistrarRegistersAtLeastOneExperimentalAccessor() async {
        // Минимум: после регистрации registry непустой и хотя бы один
        // descriptor помечен experimental. Без этого канал EXP-1 пуст
        // и команда `accessors --experimental` ничего не возвращала бы.
        let registry = AccessorRegistry()
        await LushaExperimentalRegistrar().register(into: registry)
        let descriptors = await registry.list()
        XCTAssertFalse(descriptors.isEmpty, "registrar should add accessors")
        XCTAssertTrue(
            descriptors.allSatisfy { $0.experimental },
            "all accessors registered by LushaExperimentalRegistrar must be experimental"
        )
    }

    func testThermalAccessorIsExperimental() {
        let accessor = ThermalStateAccessor()
        XCTAssertTrue(accessor.experimental)
        XCTAssertEqual(accessor.id, "thermal")
    }

    func testThermalAccessorSnapshotIsNonEmpty() async {
        // Не утверждаем конкретное значение thermalState — оно зависит
        // от runtime (CI/локалка/sandbox). Достаточно, что snapshot
        // возвращает структурированные строки и не падает.
        let accessor = ThermalStateAccessor()
        let snap = await accessor.snapshot()
        XCTAssertEqual(snap.count, 2)
        XCTAssertTrue(snap[0].hasPrefix("state="), "first line should encode state label")
        XCTAssertTrue(snap[1].hasPrefix("raw="), "second line should encode raw rawValue")
    }

    func testRegistrySnapshotForExperimentalIdReturnsLines() async {
        // End-to-end: registrar регистрирует, registry умеет
        // вернуть snapshot по id experimental-аксессора.
        let registry = AccessorRegistry()
        await LushaExperimentalRegistrar().register(into: registry)
        let lines = await registry.snapshot(id: "thermal")
        XCTAssertNotNil(lines)
        XCTAssertEqual(lines?.count, 2)
    }

    func testFilterReturnsOnlyExperimentalAfterMixedRegistration() async {
        // Симулирует реальный сценарий main.swift: core + experimental
        // регистраторы вместе, фильтр `experimental: true` оставляет
        // только LushaExperimental-аксессоры.
        let registry = AccessorRegistry()
        let store = ContextStore(capacity: 1)
        await LushaBridgeRegistrar(contextStore: store).register(into: registry)
        await LushaExperimentalRegistrar().register(into: registry)
        let onlyExperimental = await registry.list(experimental: true)
        XCTAssertFalse(onlyExperimental.isEmpty)
        XCTAssertTrue(onlyExperimental.allSatisfy { $0.experimental })
        let onlyCore = await registry.list(experimental: false)
        XCTAssertFalse(onlyCore.isEmpty)
        XCTAssertTrue(onlyCore.allSatisfy { !$0.experimental })
    }
}
