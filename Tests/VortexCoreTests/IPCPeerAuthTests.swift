import Darwin
import Foundation
import XCTest
@testable import VortexCore

/// Issue #62: peer authentication через `getpeereid` + `LOCAL_PEERPID`.
///
/// Прямой тест cross-uid отказа в xctest невозможен без root'а (нельзя
/// `setuid` в чужой uid из теста). Покрытие, которое мы можем дать:
/// 1. `peerCredentials` через `socketpair` отдаёт наш uid и валидный pid.
/// 2. Соединение от того же uid (xctest сам — single-uid) принимается
///    сервером и обрабатывается — это уже покрывает `IPCServerTests`.
///
/// Cross-uid отказ остаётся ручным smoke-тестом: `sudo -u nobody nc -U …`
/// должен закрывать соединение немедленно и писать warning в unified log.
final class IPCPeerAuthTests: XCTestCase {

    /// `peerCredentials` на сокете из `socketpair`: каждая сторона видит
    /// своего пира как процесс с тем же uid (это и есть мы) и валидный pid.
    func testPeerCredentialsViaSocketpair() throws {
        var sv: [Int32] = [-1, -1]
        let rc = sv.withUnsafeMutableBufferPointer { ptr -> Int32 in
            socketpair(AF_UNIX, SOCK_STREAM, 0, ptr.baseAddress)
        }
        XCTAssertEqual(rc, 0, "socketpair failed errno=\(errno)")
        defer {
            close(sv[0])
            close(sv[1])
        }

        guard let cred = IPCServer.peerCredentials(fd: sv[0]) else {
            return XCTFail("peerCredentials returned nil on socketpair fd")
        }
        XCTAssertEqual(cred.uid, getuid(), "peer uid must match our uid")
        XCTAssertEqual(cred.gid, getgid(), "peer gid must match our gid")
        XCTAssertEqual(cred.pid, getpid(), "peer pid must match our pid (oба конца — мы сами)")
    }

    /// `peerCredentials` на не-socket fd → nil. getpeereid вернёт ошибку,
    /// мы должны её честно отдать наверх (acceptLoop closes connection).
    func testPeerCredentialsReturnsNilOnNonSocketFd() throws {
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("froggy-peer-test-\(UUID().uuidString)")
        let fd = open(tmpURL.path, O_CREAT | O_WRONLY, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer {
            close(fd)
            try? FileManager.default.removeItem(at: tmpURL)
        }

        let cred = IPCServer.peerCredentials(fd: fd)
        XCTAssertNil(cred, "обычный файл не сокет → getpeereid должен вернуть ошибку")
    }

    /// `processUid` соответствует `getuid()` в момент запуска. Anchor-тест:
    /// если кто-то переименует поле или поменяет источник — тест упадёт.
    func testProcessUidMatchesGetuid() {
        XCTAssertEqual(IPCServer.processUid, getuid())
    }
}
