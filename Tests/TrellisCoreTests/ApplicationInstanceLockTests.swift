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

final class AppInstanceIdentityTests: XCTestCase {
    func testInstalledAndDevelopmentBuildsDoNotShareInstanceResources() throws {
        let installed = AppInstanceIdentity(bundleIdentifier: "com.bearstouch.trellis")
        let unbundled = AppInstanceIdentity(bundleIdentifier: nil)
        let devBundle = AppInstanceIdentity(bundleIdentifier: "com.bearstouch.trellis.dev")
        XCTAssertFalse(installed.isDevelopment)
        XCTAssertTrue(unbundled.isDevelopment); XCTAssertEqual(unbundled, devBundle)
        let tmp = URL(fileURLWithPath: "/tmp", isDirectory: true)
        XCTAssertEqual(installed.lockURL(in: tmp, uid: 501).lastPathComponent, "com.bearstouch.trellis-501.instance.lock")
        XCTAssertNotEqual(installed.lockURL(in: tmp, uid: 501), unbundled.lockURL(in: tmp, uid: 501))
        XCTAssertNotEqual(installed.activationNotification, unbundled.activationNotification)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNotEqual(
            try ApplicationSupportLocation.prepare(root: root, bundleIdentifier: installed.identifier),
            try ApplicationSupportLocation.prepare(root: root, bundleIdentifier: unbundled.identifier))
    }

    func testEachStateDirectoryIsItsOwnInstance() throws {
        let tmp = URL(fileURLWithPath: "/tmp", isDirectory: true)
        let plain = AppInstanceIdentity(bundleIdentifier: nil)
        let isolated = AppInstanceIdentity(bundleIdentifier: nil, stateDirectory: URL(fileURLWithPath: "/abs/test", isDirectory: true))
        let same = AppInstanceIdentity(bundleIdentifier: nil, stateDirectory: URL(fileURLWithPath: "/abs/./test/", isDirectory: true))
        let other = AppInstanceIdentity(bundleIdentifier: nil, stateDirectory: URL(fileURLWithPath: "/abs/other", isDirectory: true))
        XCTAssertEqual(plain.lockURL(in: tmp, uid: 501).lastPathComponent, "com.bearstouch.trellis.dev-501.instance.lock", "The default is unchanged")
        XCTAssertNotEqual(isolated.lockURL(in: tmp, uid: 501), plain.lockURL(in: tmp, uid: 501))
        XCTAssertNotEqual(isolated.activationNotification, plain.activationNotification, "Never activates an instance on another workspace")
        XCTAssertEqual(isolated.lockURL(in: tmp, uid: 501), same.lockURL(in: tmp, uid: 501), "The same folder is one instance")
        XCTAssertEqual(isolated.activationNotification, same.activationNotification)
        XCTAssertNotEqual(isolated.lockURL(in: tmp, uid: 501), other.lockURL(in: tmp, uid: 501))
        XCTAssertEqual(isolated.identifier, plain.identifier, "Same identity for preferences")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        guard case .acquired(let running) = try ApplicationInstanceLock.acquire(at: plain.lockURL(in: directory)) else { return XCTFail("First instance must lock") }
        withExtendedLifetime(running) {
            guard case .acquired = try? ApplicationInstanceLock.acquire(at: isolated.lockURL(in: directory)) else {
                return XCTFail("A --state-directory launch must run beside the default dev instance")
            }
        }
    }

    func testFixtureLaunchesUseAFreshWorkspaceUnlessOneIsGiven() {
        let tmp = URL(fileURLWithPath: "/tmp", isDirectory: true)
        XCTAssertNil(LaunchStateDirectory.resolve(arguments: ["Trellis"], temporaryDirectory: tmp), "A normal launch uses Application Support")
        XCTAssertEqual(
            LaunchStateDirectory.resolve(arguments: ["Trellis", "--fixture"], temporaryDirectory: tmp, uniqueName: { "x" })?.path, "/tmp/trellis-fixture-x",
            "Never the developer's workspace")
        XCTAssertNotEqual(
            LaunchStateDirectory.resolve(arguments: ["Trellis", "--fixture"], temporaryDirectory: tmp),
            LaunchStateDirectory.resolve(arguments: ["Trellis", "--fixture"], temporaryDirectory: tmp), "Each fixture launch starts empty")
        XCTAssertEqual(LaunchStateDirectory.resolve(arguments: ["Trellis", "--fixture", "--state-directory", "/abs/q"], temporaryDirectory: tmp)?.path, "/abs/q")
        XCTAssertEqual(LaunchStateDirectory.resolve(arguments: ["Trellis", "--state-directory", "/abs/q"], temporaryDirectory: tmp)?.path, "/abs/q")
    }

    func testInstalledAndDevelopmentLocksAreHeldIndependently() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        guard case .acquired(let installed) = try ApplicationInstanceLock.acquire(at: AppInstanceIdentity(bundleIdentifier: "com.bearstouch.trellis").lockURL(in: directory)) else {
            return XCTFail("Installed app must acquire its lock")
        }
        withExtendedLifetime(installed) {
            guard case .acquired = try? ApplicationInstanceLock.acquire(at: AppInstanceIdentity(bundleIdentifier: nil).lockURL(in: directory)) else {
                return XCTFail("A development build must run beside the installed app")
            }
        }
    }
}
