import XCTest
@testable import LushaBridge

final class FrameDigestTests: XCTestCase {
    func testIdenticalIsExactlyOne() {
        let bytes = (0..<1024).map { UInt8($0 & 0xFF) }
        let a = FrameDigest(size: 32, bytes: bytes)
        let b = FrameDigest(size: 32, bytes: bytes)
        XCTAssertEqual(a.similarity(to: b), 1.0, accuracy: 1e-9)
    }

    func testWhiteVsBlackIsExactlyZero() {
        let white = FrameDigest(size: 32, bytes: Array(repeating: 255, count: 1024))
        let black = FrameDigest(size: 32, bytes: Array(repeating: 0, count: 1024))
        XCTAssertEqual(white.similarity(to: black), 0.0, accuracy: 1e-9)
    }

    func testNearlyIdenticalIsHigh() {
        var a = Array(repeating: UInt8(128), count: 1024)
        var b = a
        // Bump 10 pixels by 5 — small noise.
        for i in 0..<10 { b[i] = a[i] &+ 5 }
        let da = FrameDigest(size: 32, bytes: a)
        let db = FrameDigest(size: 32, bytes: b)
        let sim = da.similarity(to: db)
        XCTAssertGreaterThan(sim, 0.99)
        XCTAssertLessThan(sim, 1.0)
    }

    func testDifferentSizesReturnsZero() {
        let a = FrameDigest(size: 32, bytes: Array(repeating: 0, count: 1024))
        let b = FrameDigest(size: 16, bytes: Array(repeating: 0, count: 256))
        XCTAssertEqual(a.similarity(to: b), 0.0)
    }
}
