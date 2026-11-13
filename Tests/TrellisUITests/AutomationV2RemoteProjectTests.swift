import AppKit
import Darwin
import TrellisBroker
import TrellisControl
import TrellisCore
import TrellisTerminal
import XCTest

@testable import TrellisUI

/// Protocol 2 project launches on a host (methods.md#projects, FR-PL06–FR-PL08, FR-RW): a fake `ssh` runs the real
/// bootstrap, helper and broker under a temporary `HOME`, whose login shell finds a fake `git` first on its PATH. The
/// app's install sheet fails the test if shown: the API connects first under the helperInstall rule and never asks.
@MainActor
final class AutomationV2RemoteProjectTests: XCTestCase {
    private var root = ""
    private var home = ""
    private var v: HarnessV2!
    private var host: SavedHost!
    private var remote: RemoteHostsModel!
    private var projects: ProjectListModel!

    private static let launcher: Set<CapabilityV2> = [.projectRead, .projectLaunch, .sessionStart, .sessionExecute, .remoteConnect, .workspaceRead, .hostRead]

    override func setUp() async throws {
        _ = NSApplication.shared
        let helper = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent(BrokerProtocol.helperName).path
        guard FileManager.default.isExecutableFile(atPath: helper) else { throw XCTSkip("Run `swift build` first to build \(BrokerProtocol.helperName).") }
        root = try XCTUnwrap(BrokerFiles.realPath(NSTemporaryDirectory())) + "/trellis-v2rpl-\(UUID().uuidString.prefix(8))"
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

        projects = ProjectListModel(library: ProjectLibrary(storage: MemoryHosts()))
        await projects.load()
        v = try HarnessV2(projects: projects)
        let model = v.model
        guard case .success(let saved) = await v.base.hosts.save(HostDraft(name: "build-box", destination: "build-box"), editing: nil) else { return XCTFail("No host") }
        host = saved
        remote = RemoteHostsModel(
            settings: RemoteHostSettings(stateDirectory: URL(fileURLWithPath: root + "/state")),
            catalog: RemoteArtifactCatalog.load(remoteDirectory: nil, macHelper: helper), clientID: RemoteClientIdentity.randomHex())
        remote.sshExecutable = root + "/ssh"
        let environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "FAKE_SSH_HOME": home]
        remote.environment = { environment }
        remote.confirmInstall = { _, _, _, _ in
            XCTFail("The API showed the install sheet"); return false
        }
        model.remoteHosts = remote
        let hosts = v.base.hosts
        model.resolveHost = { id in await hosts.host(id) }
        model.commandPaletteHosts = { hosts.hosts }
        model.confirmStopOrphans = { _ in false }
        model.remoteReconnector.sleep = { _ in try await Task.sleep(for: .seconds(3_600)) }
    }

    override func tearDown() async throws {
        if let remote, let host, let connection = remote.workspaceConnection(host.id) {
            connection.sendStopAll()
            try? await Task.sleep(for: .milliseconds(300))
        }
        v?.model.remoteReconnector.cancelAll()
        remote?.closeWorkspaceLinks()
        v?.model.terminals.values.forEach { $0.adapter.detach() }
        v?.base.discardPreferences()
        try? FileManager.default.removeItem(atPath: root)
    }

    private func grant(_ name: String, _ capabilities: Set<CapabilityV2>, scope: GrantScope = GrantScope()) async throws {
        try await v.grant(name, settings: GrantSettings(name: name, capabilities: capabilities, scope: scope))
    }

    private func until(_ what: String, timeout: TimeInterval = 20, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { XCTFail("Timed out: \(what)"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private var installed: Bool { FileManager.default.fileExists(atPath: home + "/.trellis/remote") }

    func testALaunchOnAHostConnectsFirstUnderTheHelperInstallRuleThenSetsUpAndBindsTheSpace() async throws {
        guard
            case .success(let project) = await projects.save(
                ProjectDefinition(
                    name: "Shop",
                    tabs: [ProjectTab(title: "API", directory: "api", repository: ProjectRepository(url: "git@github.com:acme/api.git"), root: .pane(ProjectPane(command: "echo api-$((6*7))")))]))
        else { return XCTFail("Not saved") }
        let hostTarget: [String: Any] = ["kind": "host", "hostId": host.id.uuidString.lowercased()]
        let params: [String: Any] = ["id": project.id.uuidString.lowercased(), "target": hostTarget, "folder": "code/shop"]
        try await grant("noRemote", Self.launcher.subtracting([.remoteConnect]))
        try await grant("unapproved", Self.launcher, scope: GrantScope(hosts: .approved([])))
        try await grant("launcher", Self.launcher)
        try await grant("manager", Self.launcher.union([.remoteManage]))

        let noRemote = try await v.call("project.check", params, as: "noRemote")
        XCTAssertEqual(details(noRemote)?["missing"] as? [String], ["remote.connect"], "Checking a host connects to it")
        let unapproved = try await v.code("project.launch", params, as: "unapproved")
        XCTAssertEqual(unapproved, "NOT_FOUND", "The host must be in scope")
        // No helper there and no consent to install one: refused before anything is created or written on the host.
        let refused = try await v.call("project.launch", params.merging(["setup": true]) { $1 }, as: "launcher")
        XCTAssertEqual(errorCode(refused), "CONFIRMATION_REQUIRED")
        XCTAssertEqual(details(refused)?["reason"] as? String, "helperInstall")
        XCTAssertFalse(installed)
        XCTAssertTrue(v.model.snapshot.spaces.allSatisfy { $0.projectID == nil })
        XCTAssertFalse(FileManager.default.fileExists(atPath: home + "/git.log"))

        // remote.manage is the grant's consent: the check connects and installs, then reads the host.
        let plan = object(try await v.ok("project.check", params, as: "manager"), "plan")
        XCTAssertTrue(installed, "Installed under the grant's remote.manage, without the sheet")
        XCTAssertEqual(plan["needsSetup"] as? Bool, true)
        XCTAssertEqual(plan["folder"] as? String, "code/shop", "Relative to home on a host, as the folder is given")
        XCTAssertEqual(plan["target"] as? [String: String], ["kind": "host", "hostId": host.id.uuidString.lowercased()])
        let launched = try await v.ok("project.launch", params.merging(["setup": true, "expectedRevision": plan["revision"] ?? 0]) { $1 }, as: "launcher")
        XCTAssertEqual(try String(contentsOfFile: home + "/git.log", encoding: .utf8), "git clone -- git@github.com:acme/api.git ./api\n")
        let spaceID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(object(launched, "space")["id"] as? String)))
        let space = try XCTUnwrap(v.model.snapshot.spaces.first { $0.id == spaceID })
        XCTAssertEqual(space.remoteHostID, host.id, "Bound to the host, as a remote workspace")
        XCTAssertEqual(space.projectID, project.id, "Bound to the project")
        XCTAssertEqual(object(object(launched, "space"), "project")["folder"] as? String, "code/shop")
        let pane = try XCTUnwrap(UUID(uuidString: try XCTUnwrap((launched["launches"] as? [[String: Any]])?.first?["paneId"] as? String)))
        guard case .remoteShell(host.id, home + "/code/shop/api")? = v.model.snapshot.sessions[v.model.snapshot.panes[pane]!.sessionID]?.launch else {
            return XCTFail("Not a shell on the host in the checkout")
        }
        let terminal = try XCTUnwrap(v.model.terminals[pane])
        try await until("the command ran on the host") { terminal.screenText.contains("api-42") }
        XCTAssertTrue(v.model.automationSetupTerminals.isEmpty, "The setup's terminal is let go once it ended")
    }
}
