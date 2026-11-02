import AppKit
import Darwin
import TrellisBroker
import TrellisCore
import TrellisTerminal
import XCTest

@testable import TrellisUI

/// Launching a library project on a host (FR-PL06–FR-PL08, FR-RW10, FR-RW18) through a fake `ssh` that runs the real
/// bootstrap, helper and broker under a temporary `HOME`. The host's login shell finds a fake `git` first on its PATH.
@MainActor
final class RemoteProjectLaunchTests: XCTestCase {
    private var root = ""
    private var home = ""
    private var host: SavedHost!
    private var model: AppWorkspaceModel!
    private var cleanup: [() -> Void] = []

    override func setUp() async throws {
        _ = NSApplication.shared
        let helper = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent(BrokerProtocol.helperName).path
        guard FileManager.default.isExecutableFile(atPath: helper) else { throw XCTSkip("Run `swift build` first to build \(BrokerProtocol.helperName).") }
        root = try XCTUnwrap(BrokerFiles.realPath(NSTemporaryDirectory())) + "/trellis-rpl-\(UUID().uuidString.prefix(8))"
        home = root + "/home"
        try FileManager.default.createDirectory(atPath: home + "/bin", withIntermediateDirectories: true)
        try "#!/bin/sh\necho \"git $*\" >> \"$HOME/git.log\"\n[ \"$1\" = clone ] && for last; do :; done && mkdir -p \"$last/.git\"\nexit 0\n"
            .write(toFile: home + "/bin/git", atomically: true, encoding: .utf8)
        chmod(home + "/bin/git", 0o755)
        // Login shells reset PATH from the system profile first; the user's own profile puts the fake git back in front.
        for profile in [".zprofile", ".bash_profile", ".profile"] {
            try "export PATH=\"$HOME/bin:$PATH\"\n".write(toFile: home + "/" + profile, atomically: true, encoding: .utf8)
        }
        try """
        #!/bin/sh
        while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done
        shift; shift
        export HOME="$FAKE_SSH_HOME"
        exec /bin/sh -c "$1"
        """.write(toFile: root + "/ssh", atomically: true, encoding: .utf8)
        chmod(root + "/ssh", 0o755)
        host = SavedHost(id: UUID(), draft: try HostDraft(name: "build-box", destination: "build-box").validated { _ in false }, revision: 1)

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
        let hosts = [host!]
        model.resolveHost = { id in hosts.first { $0.id == id } }
        model.commandPaletteHosts = { hosts }
        model.confirmCloseSessions = { _ in true }
        model.confirmStopOrphans = { _ in false }
        _ = await model.loadWorkspace()
    }

    override func tearDown() async throws {
        if let remote = model?.remoteHosts, let connection = remote.workspaceConnection(host.id) {
            connection.sendStopAll()
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

    private func until(_ what: String, timeout: TimeInterval = 20, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { XCTFail("Timed out: \(what) \(String(describing: model.projectLaunch?.stage).prefix(200))"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testAProjectIsSetUpOnTheHostAndOpensAsAWindowBoundToIt() async throws {
        // The host already has the project folder and one of its repositories; only the other one is cloned.
        try FileManager.default.createDirectory(atPath: home + "/code/shop/web/.git", withIntermediateDirectories: true)
        let project = ProjectDefinition(
            name: "Shop",
            tabs: [
                ProjectTab(title: "API", directory: "api", repository: ProjectRepository(url: "git@github.com:acme/api.git"), root: .pane(ProjectPane(command: "echo api-$((6*7))"))),
                ProjectTab(title: "Web", directory: "web", repository: ProjectRepository(url: "git@github.com:acme/web.git"))
            ])
        model.beginProjectLaunch(project)
        let session = try XCTUnwrap(model.projectLaunch)
        model.setProjectLaunchTarget(session, .host(host.id))
        session.folder = "code/shop"
        await model.checkProjectLaunch(session)
        var launch: ProjectLaunch?
        try await until("the host was checked") {
            if case .ready(let ready) = session.stage, ready.target == .host(host.id), ready.folder == "code/shop" { launch = ready; return true }
            return false
        }
        XCTAssertEqual(launch?.checkouts.map(\.state), [.clone, .present])
        XCTAssertEqual(launch?.rootExists, true)

        await model.runProjectSetup(session)
        try await until("the window opened") { model.projectLaunch == nil && model.snapshot.windows.contains { $0.name == "Shop" } }
        XCTAssertEqual(try String(contentsOfFile: home + "/git.log", encoding: .utf8), "git clone -- git@github.com:acme/api.git ./api\n")
        let window = try XCTUnwrap(model.snapshot.windows.first { $0.name == "Shop" })
        XCTAssertEqual(window.remoteHostID, host.id, "The window is bound to the host")
        let pane = try XCTUnwrap(model.snapshot.tabs[window.tabIDs[0]]?.activePaneID)
        guard case .remoteShell(host.id, home + "/code/shop/api")? = model.snapshot.sessions[model.snapshot.panes[pane]!.sessionID]?.launch else {
            return XCTFail("Not a shell on the host in the checkout")
        }
        let terminal = try XCTUnwrap(model.terminals[pane])
        try await until("the command ran on the host") { terminal.screenText.contains("api-42") }
    }
    func testASetupOnTheHostSurvivesALinkDropAndIsNeverAnOrphan() async throws {
        // The clone waits until the test lets it finish.
        try "#!/bin/sh\necho \"git $*\" >> \"$HOME/git.log\"\nwhile [ ! -e \"$HOME/release\" ]; do sleep 0.1; done\nfor last; do :; done\nmkdir -p \"$last/.git\"\n"
            .write(toFile: home + "/bin/git", atomically: true, encoding: .utf8)
        var orphanPrompts = 0
        model.confirmStopOrphans = { _ in
            orphanPrompts += 1; return true
        }
        let project = ProjectDefinition(name: "Shop", tabs: [ProjectTab(title: "API", directory: "api", repository: ProjectRepository(url: "git@github.com:acme/api.git"))])
        model.beginProjectLaunch(project)
        let session = try XCTUnwrap(model.projectLaunch)
        model.setProjectLaunchTarget(session, .host(host.id))
        session.folder = "code/shop"
        await model.checkProjectLaunch(session)
        try await until("the host was checked") { if case .ready = session.stage { true } else { false } }
        await model.runProjectSetup(session)
        try await until("the clone started") { FileManager.default.fileExists(atPath: home + "/git.log") }
        let setup = try XCTUnwrap(session.terminal)

        model.remoteHosts?.closeWorkspaceLinks()
        try await until("the setup knows the link is down") { setup.remoteTransport?.linkLost == true }
        XCTAssertTrue(model.hasRemoteWorkspace(host.id), "A running setup is reconnected for, though no window is bound to the host yet")
        let failure = await model.connectRemote(hostID: host.id, interactive: false)
        XCTAssertNil(failure)
        try await until("the setup resumed") { setup.remoteTransport?.linkLost == false }
        XCTAssertEqual(orphanPrompts, 0, "The setup is never offered as an orphan")

        FileManager.default.createFile(atPath: home + "/release", contents: nil)
        try await until("the window opened") { model.projectLaunch == nil && model.snapshot.windows.contains { $0.name == "Shop" } }
    }
    func testASetupCancelledWhileDisconnectedIsHungUpOnReconnect() async throws {
        try "#!/bin/sh\necho \"git $*\" >> \"$HOME/git.log\"\nexec sleep 30\n".write(toFile: home + "/bin/git", atomically: true, encoding: .utf8)
        let project = ProjectDefinition(name: "Shop", tabs: [ProjectTab(title: "API", directory: "api", repository: ProjectRepository(url: "git@github.com:acme/api.git"))])
        model.beginProjectLaunch(project)
        let session = try XCTUnwrap(model.projectLaunch)
        model.setProjectLaunchTarget(session, .host(host.id))
        session.folder = "code/shop"
        await model.checkProjectLaunch(session)
        try await until("the host was checked") { if case .ready = session.stage { true } else { false } }
        await model.runProjectSetup(session)
        try await until("the clone started") { FileManager.default.fileExists(atPath: home + "/git.log") }
        let setup = try XCTUnwrap(session.terminal)
        let setupID = try XCTUnwrap(setup.remoteTransport?.sessionID)

        model.remoteHosts?.closeWorkspaceLinks()
        try await until("the setup knows the link is down") { setup.remoteTransport?.linkLost == true }
        model.cancelProjectLaunch(session)
        XCTAssertTrue(model.hasRemoteWorkspace(host.id), "No window is bound to the host, but its hangup still needs the link")
        let failure = await model.connectRemote(hostID: host.id, interactive: false)
        XCTAssertNil(failure)
        XCTAssertFalse(model.hasRemoteWorkspace(host.id), "Sent: nothing more to reconnect for")
        let connection = try XCTUnwrap(model.remoteHosts?.workspaceConnection(host.id))
        var ended = false
        let deadline = Date().addingTimeInterval(5)
        while !ended, Date() < deadline {
            if case .sessions(let records)? = try? await connection.request(.list) { ended = records.first { $0.sessionID == setupID }?.running != true }
            if !ended { try await Task.sleep(for: .milliseconds(100)) }
        }
        XCTAssertTrue(ended, "The cancelled setup was hung up once the host was reachable")
    }
}
