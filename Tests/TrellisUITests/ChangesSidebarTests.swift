import AppKit
import XCTest
import TrellisBroker
import TrellisCore
import TrellisTerminal
@testable import TrellisUI

/// The sidebar's Changes view and the Review tab (FR-GC01–FR-GC07) at the model level: a real shell pane in a temporary git
/// repository, real git, and Finder, apps and the pasteboard injected so nothing outside the test is touched.
final class ChangesSidebarTests: XCTestCase {
    private var scratch: URL!
    private var repo: String!
    private var shell: String!

    override func setUpWithError() throws {
        guard BrokerGit.capture(["--version"], directory: "/", environment: ProcessInfo.processInfo.environment)?.exit == 0 else { throw XCTSkip("git isn't installed") }
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-gc-\(UUID().uuidString.prefix(8))").resolvingSymlinksInPath()
        repo = scratch.appendingPathComponent("repo").path
        for folder in ["bin", "state", "repo/Sources/UI", "plain"] {
            try FileManager.default.createDirectory(at: scratch.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        // Git reports the real path (/private/var/…), which Foundation's resolving shortens.
        scratch = URL(
            fileURLWithPath: try XCTUnwrap(
                realpath(scratch.path, nil).map {
                    defer { free($0) }; return String(cString: $0)
                }))
        repo = scratch.appendingPathComponent("repo").path
        shell = scratch.appendingPathComponent("bin/sh").path
        try "#!/bin/sh\nprintf 'SHELL-UP\\n'\n[ \"$2\" = -c ] && exec /bin/sh -c \"$3\"\nexec /bin/cat\n".write(toFile: shell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell)
    }

    override func tearDownWithError() throws { if let scratch { try? FileManager.default.removeItem(at: scratch) } }

    private final class Recorder: @unchecked Sendable {
        var opened: [(URL, URL?)] = []
        var revealed: [[URL]] = []
        var copied: [String] = []
    }

    @discardableResult
    private func git(_ arguments: [String], in directory: String? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "init.defaultBranch=main", "-c", "commit.gpgsign=false"] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory ?? repo)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " "))")
        return String(decoding: data, as: UTF8.self)
    }

    private func write(_ text: String, _ path: String) throws {
        let url = URL(fileURLWithPath: repo + "/" + path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// A repository with one commit, then a change of every kind.
    private func makeChangedRepository() throws {
        try git(["init", "-q"])
        try write("one\ntwo\nthree\n", "Sources/UI/Right.swift")
        try write("keep\n", "README.md")
        try write("bye\n", "gone.md")
        try write("staged\n", "staged.txt")
        try write("odd\n", ":magic.txt")
        try git(["add", "-A"])
        try git(["commit", "-q", "-m", "first"])
        try write("one\nTWO\nthree\nfour\n", "Sources/UI/Right.swift")
        try FileManager.default.removeItem(atPath: repo + "/gone.md")
        try write("new\nfile\n", "Sources/New.swift")
        try write("staged and more\n", "staged.txt")
        try git(["add", "staged.txt"])
        try write("odd changed\n", ":magic.txt")
    }

    @MainActor
    private func makeModel(directory: String? = nil) async throws -> (AppWorkspaceModel, UUID, Recorder) {
        _ = NSApplication.shared
        let preferences = try XCTUnwrap(UserDefaults(suiteName: "trellis-gc-\(UUID().uuidString)"))
        let model = AppWorkspaceModel(store: try WorkspaceStore(), preferences: preferences, persistence: WorkspacePersistence(directory: scratch.appendingPathComponent("state")))
        _ = await model.loadWorkspace()
        model.confirmCloseSessions = { _ in true }
        model.workspaceIsFrontmost = { true }
        let recorder = Recorder()
        model.openFileInApp = { recorder.opened.append(($0, $1)) }
        model.revealFiles = { recorder.revealed.append($0) }
        model.copyToPasteboard = { recorder.copied.append($0) }
        model.applicationURL = { _ in nil }
        let saved = await model.saveLaunchSettings(shell: shell, directory: directory ?? repo + "/Sources")
        XCTAssertTrue(saved)
        _ = await model.createWindow(name: "W")
        let pane = try XCTUnwrap(model.presentation.activePane?.id)
        try await waitFor { self.text(model, pane).contains("SHELL-UP") }
        return (model, pane, recorder)
    }

    @MainActor
    private func cleanUp(_ model: AppWorkspaceModel) {
        model.terminals.values.forEach {
            $0.requestTermination(force: true); $0.adapter.detach()
        }
    }

    @MainActor
    private func waitFor(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    }

    @MainActor
    private func text(_ model: AppWorkspaceModel, _ pane: UUID) -> String { (try? model.terminals[pane]?.adapter.read(.retainedText)) ?? "" }

    @MainActor
    private func file(_ model: AppWorkspaceModel, _ path: String) -> GitChangedFile? { model.gitChanges.list?.files.first { $0.path == path } }

    // MARK: Dock (FR-GC01)

    @MainActor
    func testChangesIsTheSecondDockViewWithItsShortcutAndIsLocalOnly() async throws {
        try makeChangedRepository()
        let (model, local, _) = try await makeModel()
        defer { cleanUp(model) }
        XCTAssertEqual(SidebarView.allCases, [.files, .changes, .scratchpad, .tasks, .agents])
        XCTAssertEqual(SidebarView(shortcut: .toggleChanges), .changes)
        XCTAssertEqual(SidebarView.changes.symbol, "arrow.triangle.branch", "The fallback symbol; the dock draws a branch graph")
        let before = model.snapshot
        let request = model.gitChangesFocusRequest
        model.toggleSidebarView(.changes)
        XCTAssertEqual(model.visibleSidebarView, .changes)
        XCTAssertEqual(model.gitChangesFocusRequest, request + 1, "Showing Changes focuses its filter")
        XCTAssertEqual(model.snapshot, before, "Showing Changes is never a workspace change")

        model.gitStatuses[local] = BrokerGitStatus(branch: "main", commit: nil, changes: 5, ahead: 0, behind: 0)
        XCTAssertEqual(model.changedFileCount, 5, "The badge counts the header status's changes")

        let created = try await model.service.execute(.createRemoteWindow(name: "Remote", hostID: UUID()))
        let remoteWindow = try XCTUnwrap(created.snapshot.windows.last)
        let remote = try XCTUnwrap(created.snapshot.tabs[remoteWindow.activeTabID]?.activePaneID)
        model.publish(try await model.service.execute(.configureStoppedSession(paneID: remote, launch: .remoteShell(hostID: remoteWindow.remoteHostID!, directory: "/srv/app"))).snapshot)
        await model.selectWindow(remoteWindow.id)
        XCTAssertEqual(model.sidebarUnavailableReason(.changes), "Changes reads git only in panes on this Mac.")
        XCTAssertNil(model.visibleSidebarView, "Changes hides on a remote workspace pane")
        await model.refreshGitChanges(paneID: remote)
        XCTAssertEqual(model.gitChanges.load, .idle, "Nothing is read for a remote pane")

        await model.selectWindow(try XCTUnwrap(model.snapshot.windows.first?.id))
        XCTAssertEqual(model.visibleSidebarView, .changes, "and comes back with focus")
    }

    // MARK: Listing (FR-GC02, FR-GC03)

    @MainActor
    func testEveryKindOfChangeIsListedWithCountsAndStagedState() async throws {
        try makeChangedRepository()
        try write("conflict-free\n", "notes/todo.txt")
        let (model, pane, _) = try await makeModel()
        defer { cleanUp(model) }
        await model.refreshGitChanges(paneID: pane)
        let list = try XCTUnwrap(model.gitChanges.list, "\(model.gitChanges.load)")
        XCTAssertEqual(list.root, repo, "The view reads from the top level, not the pane's subfolder")
        XCTAssertEqual(list.branch, "main")
        XCTAssertTrue(list.hasCommits)
        XCTAssertEqual(Set(list.files.map(\.path)), ["Sources/UI/Right.swift", "gone.md", "Sources/New.swift", "staged.txt", ":magic.txt", "notes/todo.txt"])
        let right = try XCTUnwrap(file(model, "Sources/UI/Right.swift"))
        XCTAssertEqual(right.kind, .modified); XCTAssertEqual(right.added, 2); XCTAssertEqual(right.removed, 1); XCTAssertEqual(right.staging, .none)
        XCTAssertEqual(file(model, "gone.md")?.kind, .deleted); XCTAssertEqual(file(model, "gone.md")?.removed, 1)
        XCTAssertEqual(file(model, "Sources/New.swift")?.kind, .untracked); XCTAssertEqual(file(model, "Sources/New.swift")?.added, 2)
        XCTAssertEqual(file(model, "staged.txt")?.staging, .full)
        XCTAssertEqual(file(model, ":magic.txt")?.added, 1, "A path git could read as pathspec magic is read literally")

        let rows = model.gitChanges.rows
        XCTAssertEqual(rows.first?.name, "notes", "Folders first")
        XCTAssertEqual(rows.first { $0.path == "Sources" }?.added, 4)

        model.setGitChangesFilter("RIGHT")
        XCTAssertEqual(model.gitChanges.rows.compactMap(\.file).map(\.path), ["Sources/UI/Right.swift"])
        model.setGitChangesFilter("")
        model.collapseAllGitChanges()
        XCTAssertEqual(model.gitChanges.rows.map(\.name), ["notes", "Sources", ":magic.txt", "gone.md", "staged.txt"])
        model.toggleGitChangesFolder("Sources")
        XCTAssertTrue(model.gitChanges.rows.contains { $0.path == "Sources/UI" })
        model.moveGitChangesSelection(by: 1)
        XCTAssertEqual(model.gitChanges.selection, "Sources/New.swift", "↓ selects the first visible file")

        await model.refreshGitChanges(paneID: pane)
        XCTAssertTrue(model.gitChanges.collapsed.contains("notes"), "Folds survive a refresh for the session")
    }

    @MainActor
    func testOutsideARepositoryAndBeforeTheFirstCommit() async throws {
        let (model, pane, _) = try await makeModel(directory: scratch.appendingPathComponent("plain").path)
        defer { cleanUp(model) }
        await model.refreshGitChanges(paneID: pane)
        XCTAssertEqual(model.gitChanges.load, .noRepository(scratch.appendingPathComponent("plain").path))

        try git(["init", "-q"])
        try write("a\nb\n", "first.txt")
        try git(["add", "first.txt"])
        let (fresh, freshPane, _) = try await makeModel(directory: repo)
        defer { cleanUp(fresh) }
        await fresh.refreshGitChanges(paneID: freshPane)
        let list = try XCTUnwrap(fresh.gitChanges.list)
        XCTAssertFalse(list.hasCommits)
        XCTAssertEqual(file(fresh, "first.txt")?.kind, .added)
        XCTAssertEqual(file(fresh, "first.txt")?.added, 2, "Counted against the empty tree")
        await fresh.toggleGitChangeStaged("first.txt")
        XCTAssertEqual(file(fresh, "first.txt")?.kind, .untracked, "Unstaging before the first commit removes it from the index only")
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo + "/first.txt"))
    }

    @MainActor
    func testReadingNeverRunsTheRepositorysFilterDriver() async throws {
        try git(["init", "-q"])
        try write("* filter=trap\n", ".gitattributes")
        try write("x\n", "a.txt")
        try git(["add", "-A"])
        try git(["commit", "-q", "-m", "first"])
        let marker = scratch.appendingPathComponent("ran").path
        try git(["config", "filter.trap.clean", "touch '\(marker)'; cat"])
        try write("y\n", "a.txt")
        let (model, pane, _) = try await makeModel(directory: repo)
        defer { cleanUp(model) }
        await model.refreshGitChanges(paneID: pane)
        XCTAssertNotNil(file(model, "a.txt"))
        await model.reviewGitChange("a.txt")
        try await waitFor { model.currentReview?.diff != nil }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker), "Listing and diffing never run a filter driver")
    }

    @MainActor
    func testReadingNeverLooksInsideADirtySubmoduleWhoseOwnFilterWouldRun() async throws {
        let inner = scratch.appendingPathComponent("inner").path
        try FileManager.default.createDirectory(atPath: inner, withIntermediateDirectories: true)
        try git(["init", "-q"], in: inner)
        try "* filter=trap\n".write(toFile: inner + "/.gitattributes", atomically: true, encoding: .utf8)
        try "x\n".write(toFile: inner + "/a.txt", atomically: true, encoding: .utf8)
        try git(["add", "-A"], in: inner)
        try git(["commit", "-q", "-m", "inner"], in: inner)
        try git(["init", "-q"])
        try write("top\n", "top.txt")
        try git(["-c", "protocol.file.allow=always", "submodule", "add", "-q", inner, "inner"])
        try git(["commit", "-q", "-m", "first"])
        let marker = scratch.appendingPathComponent("ran").path
        try git(["config", "filter.trap.clean", "touch '\(marker)'; cat"], in: repo + "/inner")
        try "y\n".write(toFile: repo + "/inner/a.txt", atomically: true, encoding: .utf8)
        try write("top changed\n", "top.txt")
        let (model, pane, _) = try await makeModel(directory: repo)
        defer { cleanUp(model) }
        await model.refreshGitChanges(paneID: pane)
        XCTAssertNotNil(file(model, "top.txt"), "\(model.gitChanges.load)")
        await model.reviewGitChange("top.txt")
        XCTAssertNotNil(BrokerGit.status(directory: repo, environment: ProcessInfo.processInfo.environment, timeout: 10_000))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker), "Neither the view nor the header status runs a submodule's own filter")
    }

    @MainActor
    func testALateStagingRefreshLeavesTheNewlyFocusedPanesViewAlone() async throws {
        try makeChangedRepository()
        let (model, pane, _) = try await makeModel()
        defer { cleanUp(model) }
        let local = GitChangesClient.local
        model.gitChangesClient = GitChangesClient(
            list: local.list, diff: local.diff,
            stage: { root, file, stage, hasCommits in
                Thread.sleep(forTimeInterval: 0.4); return local.stage(root, file, stage, hasCommits)
            })
        await model.refreshGitChanges(paneID: pane)
        let staging = Task { await model.toggleGitChangeStaged("Sources/UI/Right.swift") }
        try await waitFor { !model.gitChanges.staging.isEmpty }
        _ = await model.createWindow(name: "Other", startSession: false)
        let other = try XCTUnwrap(model.presentation.activePane?.id)
        XCTAssertNotEqual(other, pane)
        await model.selectWindow(try XCTUnwrap(model.snapshot.windows.first?.id))
        XCTAssertEqual(model.presentation.activePane?.id, pane)
        await model.refreshGitChanges(paneID: pane)
        let shown = model.gitChanges
        XCTAssertNotNil(shown.list)
        await model.selectWindow(try XCTUnwrap(model.snapshot.windows.last?.id))
        await model.refreshGitChanges(paneID: other)
        XCTAssertEqual(model.gitChanges.load, .idle, "A pane that hasn't started has no folder yet")
        await model.refreshGitChanges(paneID: pane)
        XCTAssertEqual(model.gitChanges.paneID, other, "A refresh for a pane no longer focused changes nothing")
        await staging.value
        XCTAssertEqual(model.gitChanges.paneID, other, "The finished stage refreshes the focused pane, not the one it started in")
        XCTAssertEqual(model.gitChanges.load, .idle)
        XCTAssertEqual(model.gitChanges.status, "Staged Right.swift")
    }

    // MARK: Staging (FR-GC06)

    @MainActor
    func testStagingAndUnstagingModifiedNewAndDeletedFiles() async throws {
        try makeChangedRepository()
        let (model, pane, _) = try await makeModel()
        defer { cleanUp(model) }
        await model.refreshGitChanges(paneID: pane)
        for path in ["Sources/UI/Right.swift", "Sources/New.swift", "gone.md"] {
            await model.toggleGitChangeStaged(path)
            XCTAssertEqual(file(model, path)?.staging, .full, path)
            XCTAssertEqual(model.gitChanges.status, "Staged \(file(model, path)?.name ?? "")")
        }
        XCTAssertEqual(file(model, "Sources/New.swift")?.kind, .added, "A staged new file is Added")
        XCTAssertEqual(try git(["diff", "--cached", "--name-only"]).split(separator: "\n").sorted(), ["Sources/New.swift", "Sources/UI/Right.swift", "gone.md", "staged.txt"])
        await model.toggleGitChangeStaged("Sources/UI/Right.swift")
        XCTAssertEqual(file(model, "Sources/UI/Right.swift")?.staging, GitChangedFile.Staging.none)
        XCTAssertEqual(try String(contentsOfFile: repo + "/Sources/UI/Right.swift", encoding: .utf8), "one\nTWO\nthree\nfour\n", "Unstaging leaves the working tree")
        await model.toggleGitChangeStaged("gone.md")
        XCTAssertEqual(file(model, "gone.md")?.staging, GitChangedFile.Staging.none)
    }

    @MainActor
    func testAFailedStageSaysSoAndChangesNothing() async throws {
        try makeChangedRepository()
        let (model, pane, _) = try await makeModel()
        defer { cleanUp(model) }
        let local = GitChangesClient.local
        model.gitChangesClient = GitChangesClient(list: local.list, diff: local.diff, stage: { _, _, _, _ in false })
        await model.refreshGitChanges(paneID: pane)
        let before = model.gitChanges.list
        await model.toggleGitChangeStaged("Sources/UI/Right.swift")
        XCTAssertEqual(model.gitChanges.status, "Couldn't stage Right.swift; git reported an error.")
        XCTAssertEqual(model.gitChanges.list, before)
        XCTAssertTrue(model.gitChanges.staging.isEmpty)
    }

    // MARK: Review tab (FR-GC05, FR-GC07)

    @MainActor
    func testTheReviewTabOpensReplacesHidesAndCloses() async throws {
        try makeChangedRepository()
        let (model, pane, recorder) = try await makeModel()
        defer { cleanUp(model) }
        let terminalTab = try XCTUnwrap(model.presentation.selectedTab?.id)
        let before = model.snapshot
        await model.refreshGitChanges(paneID: pane)
        await model.reviewGitChange("Sources/UI/Right.swift")
        XCTAssertTrue(model.reviewVisible)
        let review = try XCTUnwrap(model.currentReview)
        XCTAssertEqual(review.file.path, "Sources/UI/Right.swift")
        guard case .lines(let lines)? = review.diff?.body else { return XCTFail("\(String(describing: review.diff))") }
        XCTAssertEqual(lines.filter { $0.kind == .added }.map(\.text), ["TWO", "four"])
        XCTAssertEqual(lines.filter { $0.kind == .removed }.map(\.text), ["two"])
        XCTAssertEqual(review.diff?.changeStarts.count, 2)
        let ordered = try XCTUnwrap(model.gitChanges.list?.orderedFiles.map(\.path))
        XCTAssertEqual(model.reviewPosition?.count, ordered.count)
        XCTAssertEqual(model.reviewPosition?.index, ordered.firstIndex(of: "Sources/UI/Right.swift").map { $0 + 1 })

        await model.reviewAdjacentFile(-1)
        XCTAssertEqual(model.currentReview?.file.path, "Sources/UI/Right.swift", "The first file has no previous one")
        await model.reviewAdjacentFile(1)
        XCTAssertEqual(model.currentReview?.file.path, "Sources/New.swift", "] reviews the next file in tree order, after the folder's folders")
        guard case .lines(let created)? = model.currentReview?.diff?.body else { return XCTFail() }
        XCTAssertEqual(created.filter { $0.kind == .added }.map(\.text), ["new", "file"], "A new file diffs against nothing")
        XCTAssertEqual(model.reviewTabs.count, 1, "One Review tab per window; reviewing replaces it")

        await model.reviewGitChange("gone.md")
        guard case .lines(let removed)? = model.currentReview?.diff?.body else { return XCTFail() }
        XCTAssertEqual(removed.map(\.kind), [.hunk, .removed])
        await model.openGitChange(repo, try XCTUnwrap(model.currentReview?.file))
        XCTAssertEqual(model.gitChanges.status, "gone.md was deleted; there's nothing to open.")
        XCTAssertTrue(recorder.opened.isEmpty && recorder.revealed.isEmpty)

        await model.selectTab(terminalTab)
        XCTAssertFalse(model.reviewVisible, "Selecting a terminal tab shows the terminals")
        XCTAssertNotNil(model.currentReview, "and keeps the Review tab")
        model.showReview()
        XCTAssertTrue(model.reviewVisible)
        model.hideReview()
        XCTAssertFalse(model.reviewVisible)
        model.closeReview()
        XCTAssertNil(model.currentReview)
        XCTAssertEqual(model.snapshot, before, "Reviewing never changes the saved workspace")
    }

    @MainActor
    func testANewTabHidesTheReviewAndADeletedWindowDropsIt() async throws {
        try makeChangedRepository()
        let (model, pane, _) = try await makeModel()
        defer { cleanUp(model) }
        let first = try XCTUnwrap(model.presentation.selectedWindow?.id)
        await model.refreshGitChanges(paneID: pane)
        await model.reviewGitChange("Sources/UI/Right.swift")
        XCTAssertTrue(model.reviewVisible)
        _ = await model.createTab(startSessions: false)
        XCTAssertFalse(model.reviewVisible, "A new tab shows its terminal, never stays behind the Review tab")
        XCTAssertNotNil(model.currentReview)

        let created = await model.createWindow(name: "Second", startSession: false)
        let second = try XCTUnwrap(created)
        XCTAssertNil(model.currentReview, "The Review tab belongs to its window")
        await model.selectWindow(first)
        model.showReview()
        XCTAssertTrue(model.reviewVisible)
        await model.selectWindow(second)
        await model.selectWindow(first)
        XCTAssertTrue(model.reviewVisible, "Switching windows keeps each window's Review tab as it was")
        await model.deleteWindow(first)
        XCTAssertNil(model.reviewTabs[first], "A deleted window's Review tab goes with it")
        XCTAssertFalse(model.reviewShownWindows.contains(first))
    }

    @MainActor
    func testAReviewClosedWhileARefreshReadsDiffsDoesNotComeBack() async throws {
        try makeChangedRepository()
        let (model, pane, _) = try await makeModel()
        defer { cleanUp(model) }
        let local = GitChangesClient.local
        model.gitChangesClient = GitChangesClient(
            list: local.list,
            diff: { root, file, hasCommits in
                Thread.sleep(forTimeInterval: 0.3); return local.diff(root, file, hasCommits)
            }, stage: local.stage)
        let first = try XCTUnwrap(model.presentation.selectedWindow?.id)
        await model.refreshGitChanges(paneID: pane)
        await model.reviewGitChange("Sources/UI/Right.swift")
        let created = await model.createWindow(name: "Second", startSession: false)
        let second = try XCTUnwrap(created)
        await model.reviewGitChange("Sources/UI/Right.swift")
        XCTAssertEqual(Set(model.reviewTabs.keys), [first, second])
        await model.selectWindow(first)
        let firstPane = try XCTUnwrap(model.presentation.activePane?.id)
        XCTAssertEqual(firstPane, pane)
        try write("one\nTWO\nthree\nfour\nfive\n", "Sources/UI/Right.swift")
        let refresh = Task { await model.refreshGitChanges(paneID: pane) }
        try await waitFor { model.reviewTabs.values.contains { $0.diff == nil } }
        await model.selectWindow(second)
        model.closeReview()
        await model.selectWindow(first)
        await refresh.value
        XCTAssertNil(model.reviewTabs[second], "A closed Review tab stays closed")
        XCTAssertEqual(model.reviewTabs[first]?.file.added, 3, "The other window's review takes the new counts")
    }

    @MainActor
    func testAReviewedFileThatIsNoLongerChangedSaysSoAndOpenAndCopyWork() async throws {
        try makeChangedRepository()
        let (model, pane, recorder) = try await makeModel()
        defer { cleanUp(model) }
        await model.refreshGitChanges(paneID: pane)
        await model.reviewGitChange("Sources/UI/Right.swift")
        let review = try XCTUnwrap(model.currentReview)
        await model.openGitChange(review.root, review.file)
        XCTAssertEqual(recorder.revealed.first?.first?.resolvingSymlinksInPath().path.hasSuffix("/repo/Sources/UI/Right.swift"), true, "Finder, the default editor, reveals the file")
        model.copyGitChangePath(review.root, review.file, relative: true)
        model.copyGitChangePath(review.root, review.file)
        XCTAssertEqual(recorder.copied, ["Sources/UI/Right.swift", repo + "/Sources/UI/Right.swift"])

        try git(["checkout", "--", "Sources/UI/Right.swift"])
        model.toggleSidebarView(.changes)
        await model.refreshGitChanges(paneID: pane)
        XCTAssertEqual(model.currentReview?.diff?.body, .unchanged, "A file no longer changed says so")
    }

    // MARK: Conflicts and pane actions (FR-GC05, FR-GC06)

    @MainActor
    func testStagingAConflictedFileAsksFirstAndCancelChangesNothing() async throws {
        try git(["init", "-q"])
        try write("base\n", "c.txt")
        try git(["add", "c.txt"]); try git(["commit", "-q", "-m", "base"])
        try git(["checkout", "-q", "-b", "other"])
        try write("theirs\n", "c.txt"); try git(["commit", "-q", "-am", "theirs"])
        try git(["checkout", "-q", "main"])
        try write("ours\n", "c.txt"); try git(["commit", "-q", "-am", "ours"])
        let merge = Process()
        merge.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        merge.arguments = ["git", "-c", "user.name=Test", "-c", "user.email=test@example.com", "merge", "-q", "other"]
        merge.currentDirectoryURL = URL(fileURLWithPath: repo)
        merge.standardOutput = FileHandle.nullDevice; merge.standardError = FileHandle.nullDevice
        try merge.run(); merge.waitUntilExit()
        XCTAssertNotEqual(merge.terminationStatus, 0, "The merge conflicts")
        let (model, pane, _) = try await makeModel(directory: repo)
        defer { cleanUp(model) }
        var asked: [String] = []
        model.confirmStageConflict = {
            asked.append($0); return false
        }
        await model.refreshGitChanges(paneID: pane)
        XCTAssertEqual(file(model, "c.txt")?.kind, .conflicted)
        await model.toggleGitChangeStaged("c.txt")
        XCTAssertEqual(asked, ["c.txt"])
        XCTAssertEqual(file(model, "c.txt")?.kind, .conflicted, "Cancel leaves the conflict unresolved")
        XCTAssertNil(model.gitChanges.status)
        XCTAssertTrue(try git(["diff", "--name-only", "--diff-filter=U"]).contains("c.txt"))

        model.confirmStageConflict = {
            asked.append($0); return true
        }
        await model.toggleGitChangeStaged("c.txt")
        XCTAssertEqual(asked.count, 2)
        XCTAssertEqual(file(model, "c.txt")?.kind, .modified, "Staging as resolved clears the conflict")
        XCTAssertEqual(file(model, "c.txt")?.staging, .full)
    }

    @MainActor
    func testPaneActionsShowTheTerminalsBeforeActingWhileTheReviewIsShown() async throws {
        try makeChangedRepository()
        let (model, pane, _) = try await makeModel()
        defer { cleanUp(model) }
        await model.refreshGitChanges(paneID: pane)
        await model.reviewGitChange("Sources/UI/Right.swift")
        model.revealTerminalsForPaneAction(.zoomIn)
        XCTAssertTrue(model.reviewVisible, "Actions that don't touch a pane leave the review")
        model.revealTerminalsForPaneAction(.closePane)
        XCTAssertTrue(model.reviewVisible, "Close is redirected to the review itself, not revealed")
        for action in [ShortcutAction.splitLeftRight, .findInPane, .focusLeft, .clearPane, .maximizePane, .resizeUp, .nextPrompt] {
            model.showReview()
            model.revealTerminalsForPaneAction(action)
            XCTAssertFalse(model.reviewVisible, "\(action) shows the terminals first")
            XCTAssertNotNil(model.currentReview, "and keeps the Review tab")
        }
    }
}
