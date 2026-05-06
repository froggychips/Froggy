import XCTest
@testable import LushaBridge

final class VisionActorTests: XCTestCase {
    func testNotCapturingInitially() async {
        let v = VisionActor()
        let on = await v.capturing()
        XCTAssertFalse(on)
    }

    func testStateFileLandsInApplicationSupport() async {
        let v = VisionActor()
        let url = await v.stateFileURL()
        XCTAssertTrue(url.path.contains("Application Support/Froggy"),
                      "got: \(url.path)")
        XCTAssertEqual(url.lastPathComponent, "state.json")
    }
}
