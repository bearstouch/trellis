import AppKit
import Darwin
import TrellisBroker
import TrellisCore
import TrellisTerminal
import XCTest

@testable import TrellisUI

/// Project files and tasks on a remote workspace's host (FR-RW10, FR-RW11) through a fake `ssh` that runs the real
/// bootstrap, helper and broker under a temporary `HOME`: offered from the remote shell's directory, read through the
/// helper's allow-list, trusted per host and machine, opened on the host, and tasks run in the remote shell.
@MainActor
final class RemoteProjectTests: XCTestCase {
    private var root = ""
    private var home = ""
    private var host: SavedHost!
    private var otherHost: SavedHost!
    private var model: AppWorkspaceModel!
    private var cleanup: [() -> Void] = []

    override func setUp() async throws {
        _ = NSApplication.shared
        let helper = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent(BrokerProtocol.helperName).path
        guard FileManager.default.isExecutableFile(atPath: helper) else { throw XCTSkip("Run `swift build` first to build \(BrokerProtocol.helperName).") }
        root = try XCTUnwrap(BrokerFiles.realPath(NSTemporaryDirectory())) + "/trellis-rp-\(UUID().uuidString.prefix(8))"
        home = root + "/home"
        try FileManager.default.createDirectory(atPath: home + "/app/.trellis", withIntermediateDirectories: true)
        try """
        {"version": 1, "name": "Remote App", "tabs": [{"title": "Build", "root": {"type": "pane", "command": "echo from-project-$((3*3))"}}]}
        """.write(toFile: home + "/app/.trellis/project.json", atomically: true, encoding: .utf8)
        try """
        {"version": 1, "tasks": [{"name": "hello", "command": "echo task-$((6*7))"}]}
        """.write(toFile: home + "/app/.trellis/launch.json", atomically: true, encoding: .utf8)
        try "build:\n\ttrue\n".write(toFile: home + "/app/Makefile", atomically: true, encoding: .utf8)
        try """
        #!/bin/sh
        while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done
        shift; shift
        export HOME="$FAKE_SSH_HOME"
        exec /bin/sh -c "$1"
        """.write(toFile: root + "/ssh", atomically: true, encoding: .utf8)
        chmod(root + "/ssh", 0o755)
        host = SavedHost(id: UUID(), draft: try HostDraft(name: "build-box", destination: "build-box").validated { _ in false }, revision: 1)
        otherHost = SavedHost(id: UUID(), draft: try HostDraft(name: "twin-box", destination: "twin-box").validated { _ in false }, revision: 1)

        let suite = "trellis.tests.\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        cleanup.append { preferences.removePersistentDomain(forName: suite) }
        model = AppWorkspaceModel(store: try WorkspaceStore(), preferences: preferences, persistence: WorkspacePersistence(directory: URL(fileURLWithPath: root + "/state")))
        let remote = RemoteHostsModel(
            settings: RemoteHostSettings(stateDirectory: URL(fileURLWithPath: root + "/state")),
            catalog: RemoteArtifactCatalog.load(remoteDirectory: nil, macHelper: helper), clientID: RemoteClientIdentity.randomHex())
        remote.sshExecutable = root + "/ssh"
        let environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "FAKE_SSH_HOME": home]
        remote.environment = { environment }
        remote.confirmInstall = { _, _, _, _ in true }
        model.remoteHosts = remote
        let hosts = [host!, otherHost!]
        model.resolveHost = { id in hosts.first { $0.id == id } }
        model.commandPaletteHosts = { hosts }
        model.confirmCloseSessions = { _ in true }
        model.confirmStopOrphans = { _ in false }
        _ = await model.loadWorkspace()
    }

    override func tearDown() async throws {
        if let remote = model?.remoteHosts {
            for saved in [host!, otherHost!] where remote.workspaceConnection(saved.id) != nil {
                remote.workspaceConnection(saved.id)?.sendStopAll()
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
        model?.remoteReconnector.cancelAll()
        model?.remoteHosts?.closeWorkspaceLinks()
        model?.terminals.values.forEach { $0.adapter.detach() }
        model = nil
        cleanup.forEach { $0() }
        cleanup = []
        try? FileManager.default.removeItem(atPath: root)
    }

    private func until(_ what: String, timeout: TimeInterval = 15, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { XCTFail("Timed out: \(what)"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// A remote shell on `host`, in `directory` on the host.
    private func remotePane(on host: SavedHost, in directory: String) async throws -> (pane: UUID, terminal: NativeTerminal) {
        let opened = await model.openRemoteWorkspace(host: host)
        XCTAssertNotNil(opened)
        let pane = try XCTUnwrap(model.presentation.activePane)
        let terminal = try XCTUnwrap(model.terminals[pane.id])
        try await until("the remote shell runs") { terminal.sessionState == .running }
        try terminal.adapter.send(Data("cd '\(directory)'\r".utf8))
        try await until("the shell reports \(directory)") { model.remoteWorkingDirectory(paneID: pane.id) == directory }
        return (pane.id, terminal)
    }

    func testARemoteProjectIsOfferedReviewedOnItsHostAndTrustedPerHost() async throws {
        let (pane, _) = try await remotePane(on: host, in: home + "/app")
        let tab = try XCTUnwrap(model.snapshot.panes[pane]?.tabID)
        try await until("the project is offered") { model.projectFileOffer(tabID: tab) != nil }
        let offer = try XCTUnwrap(model.projectFileOffer(tabID: tab))
        XCTAssertEqual(offer.hostID, host.id)
        XCTAssertEqual(offer.root, home + "/app")
        XCTAssertEqual(offer.name, "Remote App")
        XCTAssertTrue(offer.trustKey.hasPrefix("remote:\(host.id.uuidString):"), offer.trustKey)
        // Looking again after a local project write asks the host, never this Mac (the fake host's path exists here too).
        model.redetectProjectFiles()
        try await until("looked up again") { model.projectFileLookups[pane] != nil && model.projectFileOffers[pane] != nil }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(model.projectFileOffers[pane]?.hostID, host.id)

        // FR-WF03 on a host: a file with commands waits for review, which names the host.
        await model.loadProjectFile(offer: offer)
        let review = try XCTUnwrap(model.pendingProjectReview)
        XCTAssertEqual(review.hostName, "build-box")
        await model.resolveProjectReview(review.id, .trustAndOpen)
        let window = try XCTUnwrap(model.snapshot.windows.first { $0.name == "Remote App" })
        XCTAssertEqual(window.remoteHostID, host.id, "The project opens on its host")
        let projectPane = try XCTUnwrap(model.snapshot.tabs[window.activeTabID]?.activePaneID)
        let projectTerminal = try XCTUnwrap(model.terminals[projectPane])
        try await until("the command ran on the host, once") { projectTerminal.screenText.contains("from-project-9") }
        XCTAssertNotNil(projectTerminal.remoteTransport)
        guard case .remoteShell(host.id, home + "/app")? = model.snapshot.panes[projectPane].flatMap({ model.snapshot.sessions[$0.sessionID]?.launch }) else {
            return XCTFail("Not a shell on the host in the project folder")
        }

        // The same file reached through another saved host asks again: trust is per host and machine.
        let (twinPane, _) = try await remotePane(on: otherHost, in: home + "/app")
        let twinTab = try XCTUnwrap(model.snapshot.panes[twinPane]?.tabID)
        try await until("offered on the other host") { model.projectFileOffer(tabID: twinTab) != nil }
        let twinOffer = try XCTUnwrap(model.projectFileOffer(tabID: twinTab))
        XCTAssertNotEqual(twinOffer.trustKey, offer.trustKey)
        await model.loadProjectFile(offer: twinOffer)
        XCTAssertEqual(model.pendingProjectReview?.hostName, "twin-box", "Not trusted on this host yet")
    }

    func testASymlinkedTrellisFolderIsNeverOffered() async throws {
        try FileManager.default.createDirectory(atPath: home + "/linked", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: home + "/linked/.trellis", withDestinationPath: home + "/app/.trellis")
        let (pane, terminal) = try await remotePane(on: host, in: home + "/app")
        let tab = try XCTUnwrap(model.snapshot.panes[pane]?.tabID)
        try await until("the real project is offered") { model.projectFileOffer(tabID: tab) != nil }
        try terminal.adapter.send(Data("cd '\(home)/linked'\r".utf8))
        try await until("the shell moved") { model.remoteWorkingDirectory(paneID: pane) == home + "/linked" }
        try await until("no offer through a symlinked .trellis") { model.projectFileOffer(tabID: tab) == nil }
    }

    func testTasksOfARemoteProjectAreListedTrustedAndRunOnTheHost() async throws {
        let (pane, terminal) = try await remotePane(on: host, in: home + "/app")
        await model.refreshTaskCatalog(paneID: pane)
        let catalog = try XCTUnwrap(model.taskCatalog)
        XCTAssertEqual(catalog.hostID, host.id)
        XCTAssertEqual(catalog.tasks.map(\.name), ["hello"])
        XCTAssertTrue(catalog.detected.contains { $0.task.command == "make build" }, "\(catalog.detected.map(\.task.command))")
        try await until("the shell is ready for a task") { model.taskAvailability(paneID: pane) == .ready }

        let hello = try XCTUnwrap(catalog.tasks.first)
        model.runTask(hello, fromFile: true)
        let review = try XCTUnwrap(model.pendingTaskReview, "A file task waits for review (FR-TK06)")
        XCTAssertEqual(review.hostName, "build-box")
        model.resolveTaskReview(review.id, trust: true)
        try await until("the task ran in the remote shell") { terminal.screenText.contains("task-42") }

        // Nothing is written on the host.
        let added = await model.addDetectedTask(try XCTUnwrap(catalog.detected.first))
        XCTAssertFalse(added)
        XCTAssertEqual(try String(contentsOfFile: home + "/app/.trellis/launch.json", encoding: .utf8).contains("make build"), false)
    }
}
