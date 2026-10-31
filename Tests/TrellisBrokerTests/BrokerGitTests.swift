import Foundation
import TrellisPOSIX
import XCTest

@testable import TrellisBroker

/// Git status for pane headers (FR-PL09): counts from `--porcelain=v2 --branch`, run with a fixed argument list.
final class BrokerGitTests: XCTestCase {
    func testPorcelainOutputBecomesCountsWithoutFileNames() {
        let status = BrokerGit.parse(
            """
            # branch.oid 0123456789abcdef0123456789abcdef01234567
            # branch.head main
            # branch.upstream origin/main
            # branch.ab +2 -1
            1 .M N... 100644 100644 100644 aaa bbb secret-name.swift
            2 R. N... 100644 100644 100644 aaa bbb R100 new.swift\told.swift
            u UU N... 100644 100644 100644 100644 a b c conflict.swift
            ? untracked.txt
            ! ignored.log
            """)
        XCTAssertEqual(status, BrokerGitStatus(branch: "main", commit: nil, changes: 4, ahead: 2, behind: 1))
        XCTAssertEqual(
            BrokerGit.parse("# branch.oid 89abcdef0123456789abcdef0123456789abcdef\n# branch.head (detached)\n"),
            BrokerGitStatus(branch: nil, commit: "89abcde", changes: 0, ahead: 0, behind: 0))
        XCTAssertEqual(BrokerGit.parse("# branch.oid (initial)\n# branch.head main\n"), BrokerGitStatus(branch: "main", commit: nil, changes: 0, ahead: 0, behind: 0))
    }

    func testARealWorkTreeIsReadAndOtherFoldersAreNot() throws {
        guard let git = BrokerGit.locate(ProcessInfo.processInfo.environment["PATH"]) else { throw XCTSkip("git isn't installed") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-git-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: folder + "/plain", withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: folder) }
        let environment = ["PATH": "/usr/bin:/bin", "HOME": folder]
        XCTAssertNil(BrokerGit.status(directory: folder + "/plain", environment: environment), "Not a work tree")
        XCTAssertNil(BrokerGit.status(directory: "relative", environment: environment))
        let repository = folder + "/repo"
        try FileManager.default.createDirectory(atPath: repository, withIntermediateDirectories: true)
        let initialize = Process()
        initialize.executableURL = URL(fileURLWithPath: git)
        initialize.arguments = ["-C", repository, "init", "-q", "-b", "trunk"]
        initialize.environment = environment
        try initialize.run()
        initialize.waitUntilExit()
        // Some git builds are run by Xcode's shim, which needs a developer directory; then there's nothing to test here.
        guard initialize.terminationStatus == 0 else { throw XCTSkip("git couldn't create a repository here") }
        try "a".write(toFile: repository + "/one.txt", atomically: true, encoding: .utf8)
        try "b".write(toFile: repository + "/two.txt", atomically: true, encoding: .utf8)
        XCTAssertEqual(BrokerGit.status(directory: repository, environment: environment), BrokerGitStatus(branch: "trunk", commit: nil, changes: 2, ahead: 0, behind: 0))
    }

    #if os(macOS)
        func testXcodesShimIsSkippedWithoutDeveloperTools() {
            XCTAssertNotEqual(BrokerGit.locate("/usr/bin", developerDirectories: []), "/usr/bin/git", "It would ask to install the tools at every prompt")
            // "/" + "/usr/bin/git" is the shim itself: with a developer directory holding git, the shim is used.
            if access("/usr/bin/git", X_OK) == 0 { XCTAssertEqual(BrokerGit.locate("/usr/bin", developerDirectories: ["/"]), "/usr/bin/git") }
        }
    #endif

    /// The capture behind it: output beyond the buffer is drained, and a slow child (or one its group keeps running) is killed.
    func testCaptureIsBoundedInSizeAndTime() {
        func run(_ script: String, size: Int, timeout: Int32) -> (result: Int32, length: Int, seconds: Double) {
            // Typed: Swift 6.3.3 (CI) can't infer these literals.
            let argv: [UnsafeMutablePointer<CChar>?] = ["/bin/sh", "-c", script].map { strdup($0) } + [nil]
            let envp: [UnsafeMutablePointer<CChar>?] = [strdup("PATH=/usr/bin:/bin"), nil]
            defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
            var buffer = [CChar](repeating: 0, count: size)
            var length = 0
            let start = Date()
            let result = buffer.withUnsafeMutableBufferPointer { trellis_run_capture("/bin/sh", argv, envp, "/", $0.baseAddress, size, &length, timeout) }
            return (result, length, Date().timeIntervalSince(start))
        }
        let large = run("head -c 3000000 /dev/zero", size: 1000, timeout: 5000)
        XCTAssertEqual(large.result, 0, "The rest is read and dropped, so the child finishes")
        XCTAssertEqual(large.length, 1000)
        XCTAssertEqual(run("exit 3", size: 16, timeout: 5000).result >> 8 & 0xff, 3)
        let slow = run("sleep 5", size: 16, timeout: 200)
        XCTAssertEqual(slow.result, -2); XCTAssertLessThan(slow.seconds, 2)
        // A background child keeps stdout open after the shell exits: still bounded, and killed with its group.
        let lingering = run("sleep 5 & exit 0", size: 16, timeout: 200)
        XCTAssertEqual(lingering.result, -2); XCTAssertLessThan(lingering.seconds, 2)
    }
}
