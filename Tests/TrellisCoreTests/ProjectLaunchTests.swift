import Foundation
import XCTest

@testable import TrellisCore

/// A project resolved for a target (FR-PL06–FR-PL08): folders, layout, commands, what setup does and the setup script.
final class ProjectLaunchTests: XCTestCase {
    private let project = ProjectDefinition(
        name: "My Shop", repository: ProjectRepository(url: "git@github.com:acme/shop.git", branch: "main"),
        tabs: [
            ProjectTab(
                title: "API", directory: "api", repository: ProjectRepository(url: "https://github.com/acme/api.git"),
                root: .split(axis: .x, ratio: 0.5, first: .pane(ProjectPane(command: "make dev")), second: .pane(ProjectPane(title: "Logs", directory: "logs")))),
            ProjectTab(title: "Web", root: .pane(ProjectPane(directory: "web", command: "npm run dev", repository: ProjectRepository(url: "git@github.com:acme/web.git", branch: "next"))))
        ])

    func testFoldersResolvePerTargetAndUnsafeOnesAreRefused() throws {
        let local = try XCTUnwrap(ProjectLaunch.resolve(project, target: .local, folder: "~/code/shop", home: "/Users/me"))
        XCTAssertEqual(local.root, "/Users/me/code/shop")
        XCTAssertEqual(local.folder, "/Users/me/code/shop")
        let host = UUID()
        let remote = try XCTUnwrap(ProjectLaunch.resolve(project, target: .host(host), folder: "code/shop", home: "/home/dev"))
        XCTAssertEqual(remote.root, "/home/dev/code/shop")
        XCTAssertEqual(remote.folder, "code/shop")
        XCTAssertNotEqual(local.namespace, remote.namespace, "Each target and folder has its own window")
        for folder in ["code/shop", "~", "/", "/Users/me/a\"b", "/tmp/$(id)", "/tmp/a'b", "/tmp/a!b"] {
            XCTAssertNil(ProjectLaunch.resolve(project, target: .local, folder: folder, home: "/Users/me"), folder)
        }
        for folder in ["", "/abs", "../up", "a\"b", "."] { XCTAssertNil(ProjectLaunch.resolve(project, target: .host(host), folder: folder, home: "/home/dev"), folder) }
        XCTAssertNil(ProjectLaunch.resolve(project, target: .host(host), folder: "shop", home: "/home/o'neil"), "A host's home is quoted too")
        XCTAssertEqual(ProjectLaunch.resolve(project, target: .host(host), folder: "-x/shop", home: "/home/dev")?.root, "/home/dev/-x/shop")
        XCTAssertEqual(ProjectLaunch.suggestedFolder(project, target: .local), "~/my-shop")
        XCTAssertEqual(ProjectLaunch.suggestedFolder(project, target: .host(host)), "my-shop")
    }

    func testTheLayoutStartsPanesInTheirFoldersAndKeepsCommands() throws {
        let launch = try XCTUnwrap(ProjectLaunch.resolve(project, target: .local, folder: "/w/shop", home: "/Users/me"))
        guard case .split(_, _, _, let children) = launch.layout.windows[0].tabs[0].root else { return XCTFail("No split") }
        XCTAssertEqual(children.map(\.key), ["t1-1", "t1-2"])
        guard case .pane(_, _, .shell(let first?)) = children[0], case .pane(_, "Logs", .shell(let second?)) = children[1] else { return XCTFail("\(children)") }
        XCTAssertEqual(first, "/w/shop/api", "A pane without a folder starts in its tab's")
        XCTAssertEqual(second, "/w/shop/logs")
        XCTAssertEqual(launch.commands, ["t1-1": "make dev", "t2-0": "npm run dev"])
        XCTAssertEqual(launch.layout.windows[0].name, "My Shop")
    }

    func testCheckingSortsCheckoutsIntoCloneKeepAndBlocked() throws {
        var launch = try XCTUnwrap(ProjectLaunch.resolve(project, target: .local, folder: "/w/shop", home: "/Users/me"))
        let present: Set<String> = ["/w/shop", "/w/shop/api", "/w/shop/api/.git", "/w/shop/web"]
        launch.check(exists: present.contains, isDirectory: present.contains)
        XCTAssertTrue(launch.rootExists)
        XCTAssertEqual(launch.checkouts.map(\.state), [.clone, .present, .blocked], "\(launch.checkouts)")
        XCTAssertTrue(launch.needsSetup)
        launch.check(exists: { _ in true }, isDirectory: { _ in true })
        XCTAssertFalse(launch.needsSetup)
    }

    /// The script really runs: from a home folder, with a fake `git`, it creates the folder, initializes the project
    /// folder in place, clones what's missing, never touches a folder that isn't a checkout, and is safe to run again.
    func testTheSetupScriptCreatesTheFolderAndClonesOnlyWhatIsMissing() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-setup-\(UUID().uuidString)").path
        addTeardownBlock { try? FileManager.default.removeItem(atPath: home) }
        let bin = home + "/bin"
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        // Records each call; `clone … -- URL DIR` makes DIR/.git, `init` makes .git.
        try """
        #!/bin/sh
        echo "git $*" >> "$HOME/git.log"
        case "$1" in
        clone) for last; do :; done; mkdir -p "$last/.git" ;;
        init) mkdir .git ;;
        symbolic-ref) echo origin/main ;;
        esac
        """.write(toFile: bin + "/git", atomically: true, encoding: .utf8)
        chmod(bin + "/git", 0o755)
        var launch = try XCTUnwrap(ProjectLaunch.resolve(project, target: .host(UUID()), folder: "code/my shop", home: home))
        try FileManager.default.createDirectory(atPath: home + "/code/my shop/web", withIntermediateDirectories: true)
        let manager = FileManager.default
        launch.check(exists: { manager.fileExists(atPath: $0) }, isDirectory: { manager.fileExists(atPath: $0) })
        XCTAssertEqual(launch.checkouts.map(\.state), [.clone, .clone, .blocked])

        func run() throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-f", "-c", launch.setupCommand]
            process.currentDirectoryURL = URL(fileURLWithPath: home)
            process.environment = ["HOME": home, "PATH": bin + ":/usr/bin:/bin"]
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
        XCTAssertEqual(try run(), 0)
        let log = try String(contentsOfFile: home + "/git.log", encoding: .utf8)
        XCTAssertEqual(
            log.split(separator: "\n"),
            [
                "git init -q", "git remote add origin git@github.com:acme/shop.git", "git fetch origin", "git checkout --track origin/main",
                "git clone -- https://github.com/acme/api.git ./api"
            ])
        XCTAssertTrue(manager.fileExists(atPath: home + "/code/my shop/api/.git"))
        XCTAssertFalse(manager.fileExists(atPath: home + "/code/my shop/web/.git"), "A folder that isn't a checkout is left alone")
        // Retry after everything is in place runs no git at all.
        try "".write(toFile: home + "/git.log", atomically: true, encoding: .utf8)
        XCTAssertEqual(try run(), 0)
        XCTAssertEqual(try String(contentsOfFile: home + "/git.log", encoding: .utf8), "")
    }

    /// `set -e` doesn't stop at a failure inside an && list: a failed fetch must still fail setup, and leave no `.git`
    /// behind for Retry to take as done; files already in the folder stay.
    func testAFailedProjectFolderInitFailsAndLeavesTheFolderAsItWas() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-setup-\(UUID().uuidString)").path
        addTeardownBlock { try? FileManager.default.removeItem(atPath: home) }
        let bin = home + "/bin"
        try FileManager.default.createDirectory(atPath: home + "/shop", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        try "kept".write(toFile: home + "/shop/README", atomically: true, encoding: .utf8)
        try "#!/bin/sh\ncase \"$1\" in init) mkdir .git ;; fetch) exit 128 ;; esac\n".write(toFile: bin + "/git", atomically: true, encoding: .utf8)
        chmod(bin + "/git", 0o755)
        var launch = try XCTUnwrap(ProjectLaunch.resolve(ProjectDefinition(name: "Shop", repository: project.repository), target: .host(UUID()), folder: "shop", home: home))
        launch.check(exists: { FileManager.default.fileExists(atPath: $0) }, isDirectory: { FileManager.default.fileExists(atPath: $0) })
        XCTAssertEqual(launch.checkouts.map(\.state), [.clone])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", launch.setupCommand]
        process.currentDirectoryURL = URL(fileURLWithPath: home)
        process.environment = ["HOME": home, "PATH": bin + ":/usr/bin:/bin"]
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 128)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home + "/shop/.git"))
        XCTAssertEqual(try String(contentsOfFile: home + "/shop/README", encoding: .utf8), "kept")
    }

    func testTheSetupCommandParsesInEveryLoginShell() throws {
        let launch = try XCTUnwrap(ProjectLaunch.resolve(project, target: .local, folder: "/tmp/a b", home: "/Users/me"))
        for shell in ["/bin/sh", "/bin/bash", "/bin/zsh", "/bin/csh", "/bin/tcsh", "/bin/ksh", "/bin/dash"] where FileManager.default.isExecutableFile(atPath: shell) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            // The outer shell only parses `exec /bin/sh -c '…'`; `echo` in place of exec shows the argument arrives whole.
            process.arguments = ["-c", launch.setupCommand.replacingOccurrences(of: "exec /bin/sh -c ", with: "printf %s ")]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), launch.setupScript, shell)
        }
    }
}
