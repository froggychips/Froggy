import XCTest
@testable import VortexCore

final class ReactiveProcessFinderTests: XCTestCase {
    func testSeedsFromRunningApplications() async {
        let source = FakeWorkspaceEventSource(seed: [
            (101, "com.apple.Slack"),
            (102, "com.apple.Spotify"),
            (103, "com.apple.Slack"), // 2-я Slack-инстанция
            (104, nil),               // helper без bundle-id
        ])
        let finder = ReactiveProcessFinder(source: source)
        await finder.start()

        let slackPids = await finder.pids(forBundleIds: ["com.apple.Slack"])
        XCTAssertEqual(Set(slackPids), [101, 103])

        let spotify = await finder.pids(forBundleIds: ["com.apple.Spotify"])
        XCTAssertEqual(spotify, [102])

        let none = await finder.pids(forBundleIds: ["com.apple.Nope"])
        XCTAssertEqual(none, [])
    }

    func testActivationAddsPid() async throws {
        let source = FakeWorkspaceEventSource(seed: [])
        let finder = ReactiveProcessFinder(source: source)
        await finder.start()

        let initial = await finder.pids(forBundleIds: ["com.x"])
        XCTAssertEqual(initial, [])

        source.emit(.appActivated(pid: 555, bundleId: "com.x"))
        // дать listenTask проглотить событие
        try await Task.sleep(for: .milliseconds(50))

        let after = await finder.pids(forBundleIds: ["com.x"])
        XCTAssertEqual(after, [555])
    }

    func testTerminationRemovesPid() async throws {
        let source = FakeWorkspaceEventSource(seed: [
            (10, "com.foo"),
            (11, "com.foo"),
        ])
        let finder = ReactiveProcessFinder(source: source)
        await finder.start()

        let both = await finder.pids(forBundleIds: ["com.foo"])
        XCTAssertEqual(Set(both), [10, 11])

        source.emit(.appTerminated(pid: 10, bundleId: "com.foo"))
        try await Task.sleep(for: .milliseconds(50))

        let afterFirst = await finder.pids(forBundleIds: ["com.foo"])
        XCTAssertEqual(afterFirst, [11])

        source.emit(.appTerminated(pid: 11, bundleId: "com.foo"))
        try await Task.sleep(for: .milliseconds(50))
        let afterBoth = await finder.pids(forBundleIds: ["com.foo"])
        XCTAssertEqual(afterBoth, [])
    }

    /// Если событие пришло без bundle-id, finder использует обратную мапу.
    func testTerminationWithoutBundleIdUsesReverseMap() async throws {
        let source = FakeWorkspaceEventSource(seed: [(42, "com.bar")])
        let finder = ReactiveProcessFinder(source: source)
        await finder.start()

        source.emit(.appTerminated(pid: 42, bundleId: nil))
        try await Task.sleep(for: .milliseconds(50))

        let after = await finder.pids(forBundleIds: ["com.bar"])
        XCTAssertEqual(after, [])
    }

    func testDeactivateDoesNotRemove() async throws {
        let source = FakeWorkspaceEventSource(seed: [(7, "com.baz")])
        let finder = ReactiveProcessFinder(source: source)
        await finder.start()

        source.emit(.appDeactivated(pid: 7, bundleId: "com.baz"))
        try await Task.sleep(for: .milliseconds(50))

        let after = await finder.pids(forBundleIds: ["com.baz"])
        XCTAssertEqual(after, [7])
    }

    /// Без `start()` finder всё равно отвечает корректно (one-shot seed).
    func testWithoutStartUsesOneShotSeed() async {
        let source = FakeWorkspaceEventSource(seed: [(99, "com.lazy")])
        let finder = ReactiveProcessFinder(source: source)
        let pids = await finder.pids(forBundleIds: ["com.lazy"])
        XCTAssertEqual(pids, [99])
    }
}
