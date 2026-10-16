import XCTest
@testable import TrellisCore

final class ApplicationInstanceLockTests: XCTestCase {
    func testOnlyOneOwnerAndReleasedLockCanBeReacquired() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        var owner: ApplicationInstanceLock?
        switch try ApplicationInstanceLock.acquire(at: url) {
        case .acquired(let lock): owner = lock
        case .alreadyRunning: return XCTFail("First launch must acquire the lock")
        }
        withExtendedLifetime(owner) {
            do {
                switch try ApplicationInstanceLock.acquire(at: url) {
                case .acquired: XCTFail("Second launch must not acquire the lock")
                case .alreadyRunning(let pid): XCTAssertEqual(pid, ProcessInfo.processInfo.processIdentifier)
                }
            } catch { XCTFail("\(error)") }
        }
        owner = nil
        switch try ApplicationInstanceLock.acquire(at: url) {
        case .acquired: break
        case .alreadyRunning: XCTFail("Exiting must release the lock")
        }
    }

    func testStalePIDDoesNotPreventLaunch() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("12345\n".utf8).write(to: url)
        switch try ApplicationInstanceLock.acquire(at: url) {
        case .acquired: break
        case .alreadyRunning: XCTFail("Only an active lock should block launch")
        }
    }

    func testRejectsSymbolicLink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target")
        try Data("unchanged".utf8).write(to: target)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try ApplicationInstanceLock.acquire(at: link))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "unchanged")
    }
}
