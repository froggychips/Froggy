import Foundation
import XCTest
@testable import VortexCore

final class PageoutChainTests: XCTestCase {
    func testJetsamPreferredSucceeds() async {
        let chain = PageoutChain(
            preferred: .jetsam,
            machVM: FakePageoutImpl { _ in .failed(reason: "no entitlement") },
            jetsam: FakePageoutImpl { _ in .success(strategyUsed: .jetsam) },
            scratch: FakePageoutImpl { _ in .success(strategyUsed: .scratch) }
        )
        let outcome = await chain.pageout(pid: 1234)
        XCTAssertEqual(outcome, .success(strategyUsed: .jetsam))
    }

    /// machVM-preferred + KERN_FAILURE → fallback к jetsam.
    func testMachVMFallsBackToJetsamOnFailure() async {
        let chain = PageoutChain(
            preferred: .machVM,
            machVM: FakePageoutImpl { _ in .failed(reason: "task_for_pid kr=5") },
            jetsam: FakePageoutImpl { _ in .success(strategyUsed: .jetsam) },
            scratch: FakePageoutImpl { _ in .success(strategyUsed: .scratch) }
        )
        let outcome = await chain.pageout(pid: 1234)
        XCTAssertEqual(outcome, .success(strategyUsed: .jetsam))
    }

    /// machVM + jetsam падают → должен сработать scratch.
    func testFullChainFallback() async {
        let chain = PageoutChain(
            preferred: .machVM,
            machVM: FakePageoutImpl { _ in .failed(reason: "x") },
            jetsam: FakePageoutImpl { _ in .failed(reason: "EPERM") },
            scratch: FakePageoutImpl { _ in .success(strategyUsed: .scratch) }
        )
        let outcome = await chain.pageout(pid: 1234)
        XCTAssertEqual(outcome, .success(strategyUsed: .scratch))
    }

    /// Все стратегии падают — финальный outcome `.failed` с агрегатом.
    func testAllStrategiesFailReturnsFailed() async {
        let chain = PageoutChain(
            preferred: .machVM,
            machVM: FakePageoutImpl { _ in .failed(reason: "a") },
            jetsam: FakePageoutImpl { _ in .failed(reason: "b") },
            scratch: FakePageoutImpl { _ in .failed(reason: "c") }
        )
        let outcome = await chain.pageout(pid: 1234)
        if case .failed(let reason) = outcome {
            XCTAssertTrue(reason.contains("all pageout strategies failed"))
        } else {
            XCTFail("expected .failed, got \(outcome)")
        }
    }

    /// `.scratch` preferred — не пробует machVM/jetsam.
    func testScratchPreferredSkipsOthers() async {
        let machVMCalled = LockedFlag()
        let jetsamCalled = LockedFlag()
        let chain = PageoutChain(
            preferred: .scratch,
            machVM: FakePageoutImpl { _ in
                machVMCalled.set()
                return .failed(reason: "should not be called")
            },
            jetsam: FakePageoutImpl { _ in
                jetsamCalled.set()
                return .failed(reason: "should not be called")
            },
            scratch: FakePageoutImpl { _ in .success(strategyUsed: .scratch) }
        )
        _ = await chain.pageout(pid: 1234)
        XCTAssertFalse(machVMCalled.value)
        XCTAssertFalse(jetsamCalled.value)
    }

    /// `.jetsam` preferred — не дёргает machVM, но при падении уходит в scratch.
    func testJetsamPreferredSkipsMachVM() async {
        let machVMCalled = LockedFlag()
        let chain = PageoutChain(
            preferred: .jetsam,
            machVM: FakePageoutImpl { _ in
                machVMCalled.set()
                return .success(strategyUsed: .machVM)
            },
            jetsam: FakePageoutImpl { _ in .failed(reason: "EPERM") },
            scratch: FakePageoutImpl { _ in .success(strategyUsed: .scratch) }
        )
        let outcome = await chain.pageout(pid: 1234)
        XCTAssertFalse(machVMCalled.value, "jetsam preferred не должен трогать machVM")
        XCTAssertEqual(outcome, .success(strategyUsed: .scratch))
    }
}

/// Минимальный thread-safe флаг для проверки «вызывали ли стратегию».
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
    func set() {
        lock.lock(); defer { lock.unlock() }
        _value = true
    }
}
