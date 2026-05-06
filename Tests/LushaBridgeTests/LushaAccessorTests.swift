import XCTest
@testable import LushaBridge

private struct StubAccessor: LushaAccessor {
    let id: String
    let name: String
    let lines: [String]
    func snapshot() async -> [String] { lines }
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
}
