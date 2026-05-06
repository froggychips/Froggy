import XCTest
@testable import VortexCore

final class VortexActorTests: XCTestCase {
    func testInitialSuspendedCountIsZero() async {
        let v = VortexActor()
        let n = await v.suspendedCount()
        XCTAssertEqual(n, 0)
    }

    func testThawAllIsIdempotent() async {
        let v = VortexActor()
        await v.thawAll()
        await v.thawAll()
        let n = await v.suspendedCount()
        XCTAssertEqual(n, 0)
    }

    func testFreezeRejectsLowPid() async {
        let v = VortexActor()
        do {
            _ = try await v.freezeProcess(pid: 1)
            XCTFail("expected freeze of pid=1 to throw")
        } catch let error as VortexError {
            if case .forbiddenPid(_, let reason) = error {
                XCTAssertTrue(reason.contains("system pid"), "got reason: \(reason)")
            } else {
                XCTFail("wrong error case: \(error)")
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testFreezeRejectsSelf() async {
        let v = VortexActor()
        let me = ProcessInfo.processInfo.processIdentifier
        do {
            _ = try await v.freezeProcess(pid: me)
            XCTFail("expected freeze of self to throw")
        } catch let error as VortexError {
            if case .forbiddenPid(_, let reason) = error {
                XCTAssertEqual(reason, "self")
            } else {
                XCTFail("wrong error case: \(error)")
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testFreezeRejectsZeroPid() async {
        let v = VortexActor()
        do {
            _ = try await v.freezeProcess(pid: 0)
            XCTFail("expected freeze of pid=0 to throw")
        } catch is VortexError {
            // ok
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testMemoryPressureInValidRange() async {
        let v = VortexActor()
        let p = await v.getMemoryPressure()
        XCTAssertGreaterThanOrEqual(p, 0)
        XCTAssertLessThanOrEqual(p, 100)
    }
}
