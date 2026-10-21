import XCTest
import TrellisCore

/// launch.json rules, the typed line, and run state (FR-TK01, FR-TK04, FR-TK05, FR-TK07, FR-TK09).
final class LaunchFileTests: XCTestCase {
    func testAddingSkipsSameCommandAndNumbersTakenNames() {
        let file = LaunchFile(tasks: [LaunchTask(name: "swift: build", command: "swift build")])
        XCTAssertFalse(file.adding(LaunchTask(name: "other", command: "swift build")).added, "Same command and folder is already there")
        let renamed = file.adding(LaunchTask(name: "swift: build", command: "swift build -c release"))
        XCTAssertTrue(renamed.added)
        XCTAssertEqual(renamed.file.tasks.map(\.name), ["swift: build", "swift: build 2"])
        XCTAssertEqual(renamed.file.adding(LaunchTask(name: "swift: build", command: "x")).file.tasks.last?.name, "swift: build 3")
        XCTAssertTrue(file.adding(LaunchTask(name: "sub", command: "swift build", cwd: "sub")).added, "Another folder is another task")
    }

    func testEnvironmentMergesWithTaskWinningAndSortsByName() {
        let task = LaunchTask(name: "t", command: "c", env: ["B": "y", "C": "3"])
        let file = LaunchFile(env: ["A": "1", "B": "x"], tasks: [task])
        XCTAssertEqual(file.environment(for: task).map { "\($0.name)=\($0.value)" }, ["A=1", "B=y", "C=3"])
        XCTAssertTrue(file.issues.isEmpty)
    }

    func testVariableNamesAndValues() {
        for name in ["A", "_x", "PATH_2", "a1"] { XCTAssertTrue(LaunchFile.isVariableName(name), name) }
        for name in ["", "1X", "A-B", "A B", "É", "A=B", String(repeating: "A", count: 256)] { XCTAssertFalse(LaunchFile.isVariableName(name), name) }
        XCTAssertFalse(LaunchFile(env: ["A": "x\u{0}"]).issues.isEmpty)
        XCTAssertFalse(LaunchFile(env: ["A": "x\u{200B}y"]).issues.isEmpty)
        XCTAssertTrue(LaunchFile(env: ["A": ""]).issues.isEmpty, "Empty values are allowed")
    }

    func testQuotingPerShell() {
        XCTAssertEqual(TaskCommand.shellQuote("it's a\\b", kind: .zsh), #"'it'\''s a\b'"#)
        XCTAssertEqual(TaskCommand.shellQuote("it's a\\b", kind: .bash), #"'it'\''s a\b'"#)
        XCTAssertEqual(TaskCommand.shellQuote("it's a\\b", kind: .fish), #"'it\'s a\\b'"#)
    }

    func testComposeAddsCdOnlyWhenElsewhere() {
        func line(_ current: String?, directory: String = "/p/my app") -> String? {
            TaskCommand.compose(command: "make test", directory: directory, currentDirectory: current, environment: [], shell: "/bin/zsh", kind: .zsh)
        }
        XCTAssertEqual(line("/p/my app"), "make test")
        XCTAssertEqual(line("/p/my app/"), "make test")
        XCTAssertEqual(line("/p"), "cd '/p/my app' && make test")
        XCTAssertEqual(line(nil), "cd '/p/my app' && make test")
        XCTAssertNil(line("/p", directory: "relative"))
        XCTAssertNil(line("/p", directory: "/p/\u{202E}x"))
        XCTAssertNil(
            TaskCommand.compose(
                command: String(repeating: "x", count: 4090), directory: "/p", currentDirectory: "/q", environment: [], shell: nil, kind: .bash),
            "The whole line must stay within the command limit")
    }

    func testComposeWrapsVariablesAroundTheWholeCommand() {
        let line = TaskCommand.compose(
            command: "a && b", directory: "/p", currentDirectory: "/p", environment: [("A", "1"), ("B", "it's")], shell: "/bin/zsh", kind: .zsh)
        XCTAssertEqual(line, #"/usr/bin/env A='1' B='it'\''s' '/bin/zsh' -c 'a && b'"#)
        let fish = TaskCommand.compose(command: "echo $A", directory: "/p", currentDirectory: "/q", environment: [("A", "x")], shell: "/opt/fish", kind: .fish)
        XCTAssertEqual(fish, "cd '/p' && /usr/bin/env A='x' '/opt/fish' -c 'echo $A'")
        XCTAssertNil(TaskCommand.compose(command: "a", directory: "/p", currentDirectory: nil, environment: [("A", "1")], shell: "/a=b/zsh", kind: .zsh))
        XCTAssertNil(TaskCommand.compose(command: "a", directory: "/p", currentDirectory: nil, environment: [("A", "1")], shell: nil, kind: .zsh))
        XCTAssertNil(TaskCommand.compose(command: "a", directory: "/p", currentDirectory: nil, environment: [("-u", "1")], shell: "/bin/sh", kind: .zsh))
    }

    /// The typed line in a real POSIX shell: variables reach both commands of a chain, literally, and the exit code is the command's.
    func testComposedLineRunsInARealShell() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-tk-\(UUID().uuidString.prefix(8)) it's").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let line = try XCTUnwrap(
            TaskCommand.compose(
                command: #"printf '%s|' "$FOO" && printf '%s|' "$BAR" "$(basename "$PWD")" && exit 3"#, directory: directory.path, currentDirectory: "/",
                environment: [("BAR", "$HOME it's"), ("FOO", "a b")], shell: "/bin/sh", kind: .bash))
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", line]
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(output, "a b|$HOME it's|\(directory.lastPathComponent)|")
        XCTAssertEqual(process.terminationStatus, 3)
    }

    func testTaskDirectory() {
        XCTAssertEqual(LaunchTask(name: "t", command: "c").directory(projectRoot: "/p"), "/p")
        XCTAssertEqual(LaunchTask(name: "t", command: "c", cwd: ".").directory(projectRoot: "/p"), "/p")
        XCTAssertEqual(LaunchTask(name: "t", command: "c", cwd: "./a//b/").directory(projectRoot: "/p"), "/p/a/b")
    }

    func testRunFollowsMarksByOrder() {
        let start = Date(timeIntervalSince1970: 100)
        var run = TaskRun(taskID: "file:t", name: "t", at: start)
        XCTAssertTrue(run.isActive)
        XCTAssertTrue(run.apply(.commandInputStart, now: start))
        XCTAssertTrue(run.apply(.commandStart(commandLine: "cd '/x'"), now: start.addingTimeInterval(1)), "bash may report only the cd")
        XCTAssertTrue(run.isRunning)
        XCTAssertEqual(run.statusText(now: start.addingTimeInterval(66)), "Running: t · 1 min 5 s")
        XCTAssertTrue(run.apply(.commandFinished(exitCode: 2), now: start.addingTimeInterval(4)))
        XCTAssertEqual(run.phase, .finished(exitCode: 2, duration: 3))
        XCTAssertEqual(run.failed, true)
        XCTAssertEqual(run.statusText(now: start), "t: exit 2")
        XCTAssertTrue(run.apply(.promptStart(directory: nil), now: start.addingTimeInterval(5)), "The result stays at the next prompt")
        XCTAssertFalse(run.apply(.commandStart(commandLine: "ls"), now: start.addingTimeInterval(9)), "A later command clears it")

        var empty = TaskRun(taskID: "file:t", name: "t", at: start)
        XCTAssertFalse(empty.apply(.promptStart(directory: nil), now: start), "A line the shell never started is forgotten")

        var interrupted = TaskRun(taskID: "file:t", name: "t", at: start)
        _ = interrupted.apply(.commandStart(commandLine: nil), now: start)
        XCTAssertTrue(interrupted.apply(.promptStart(directory: nil), now: start))
        XCTAssertEqual(interrupted.statusText(now: start), "t: ended")
        XCTAssertEqual(interrupted.failed, false)
        var done = TaskRun(taskID: "file:t", name: "t", at: start)
        _ = done.apply(.commandStart(commandLine: nil), now: start)
        _ = done.apply(.commandFinished(exitCode: 0), now: start)
        XCTAssertEqual(done.statusText(now: start), "t: done")
    }

    func testTaskRootFindsTrellisOrGitWithinHome() {
        let entries: Set = ["/Users/me/code/app/.git", "/Users/me/code/lib/.trellis", "/Users/me/.git", "/srv/.git"]
        func root(_ directory: String) -> String? { ProjectFileLocator.taskRoot(containing: directory, home: "/Users/me", exists: entries.contains) }
        XCTAssertEqual(root("/Users/me/code/app/Sources/x"), "/Users/me/code/app")
        XCTAssertEqual(root("/Users/me/code/lib"), "/Users/me/code/lib")
        XCTAssertNil(root("/Users/me/code"), "Home's own .git never makes home a project")
        XCTAssertNil(root("/Users/me"))
        XCTAssertEqual(root("/srv/www"), "/srv")
        XCTAssertNil(root("/"))
        XCTAssertNil(root("relative/path"))
    }
}
