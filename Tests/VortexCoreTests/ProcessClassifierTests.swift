import Foundation
import XCTest
@testable import VortexCore

final class ProcessClassifierTests: XCTestCase {
    let classifier = ProcessClassifier()

    func testRejectsLowPid() {
        let v = classifier.classify(pid: 1)
        guard case .forbidden(let reason) = v else { return XCTFail() }
        XCTAssertTrue(reason.contains("system pid"))
    }

    func testRejectsZeroPid() {
        let v = classifier.classify(pid: 0)
        guard case .forbidden = v else { return XCTFail() }
    }

    func testRejectsSelf() {
        let v = classifier.classify(pid: getpid())
        guard case .forbidden(let reason) = v else { return XCTFail() }
        XCTAssertEqual(reason, "self")
    }

    func testRejectsNonexistentPid() {
        // pid = 999_999 — почти наверняка нет.
        let v = classifier.classify(pid: 999_999)
        guard case .forbidden(let reason) = v else { return XCTFail() }
        // Может быть "no such process" или (очень маловероятно) "different EUID";
        // главное — НЕ freezable.
        XCTAssertTrue(reason.contains("no such process") || reason.contains("EUID"))
    }

    func testExecutablePathReturnsValueForSelf() {
        let path = ProcessClassifier.executablePath(pid: getpid())
        XCTAssertNotNil(path)
        XCTAssertTrue(path!.hasPrefix("/"), "expected absolute, got \(path ?? "nil")")
    }

    func testDefaultAllowedPrefixesIncludeApplications() {
        XCTAssertTrue(ProcessClassifier.defaultAllowedPrefixes.contains("/Applications/"))
    }

    /// Запускаем дочерний `/bin/sleep` (он лежит в `/bin/`, что НЕ
    /// под `/Applications/`), убеждаемся что классификатор отказывает по path.
    func testRejectsBinSleepPath() throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sleep")
        proc.arguments = ["10"]
        try proc.run()
        defer { proc.terminate() }

        // дать время процессу подняться
        Thread.sleep(forTimeInterval: 0.1)
        let v = classifier.classify(pid: proc.processIdentifier)
        guard case .forbidden(let reason) = v else {
            XCTFail("expected forbidden, got \(v)")
            return
        }
        XCTAssertTrue(reason.contains("not a user app"), "got: \(reason)")
    }
}
