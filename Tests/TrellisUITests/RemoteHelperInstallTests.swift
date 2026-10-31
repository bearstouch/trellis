import Darwin
import Foundation
import TrellisBroker
import TrellisCore
import TrellisTerminal
import TrellisUI
import XCTest

/// The host library's helper actions (FR-RW17) through a fake `ssh` that runs the bootstrap locally under a temporary
/// `HOME`: status is recorded only from probes, nothing is installed without consent, and Remove protects running sessions.
@MainActor
final class RemoteHelperInstallTests: XCTestCase {
    private var root = ""
    private var home = ""
    private var model: RemoteHostsModel!
    private var host: SavedHost!

    override func setUp() async throws {
        _ = NSApplication.shared
        host = SavedHost(id: UUID(), draft: try HostDraft(name: "build-box", destination: "build-box").validated { _ in false }, revision: 1)
        let helper = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent(BrokerProtocol.helperName).path
        guard FileManager.default.isExecutableFile(atPath: helper) else { throw XCTSkip("Run `swift build` first to build \(BrokerProtocol.helperName).") }
        root = try XCTUnwrap(BrokerFiles.realPath(NSTemporaryDirectory())) + "/trellis-helper-\(UUID().uuidString.prefix(8))"
        home = root + "/home"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let ssh = root + "/ssh"
        try """
        #!/bin/sh
        while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done
        shift; shift
        export HOME="$FAKE_SSH_HOME"
        exec /bin/sh -c "$1"
        """.write(toFile: ssh, atomically: true, encoding: .utf8)
        chmod(ssh, 0o755)
        model = RemoteHostsModel(
            settings: RemoteHostSettings(stateDirectory: URL(fileURLWithPath: root + "/state")),
            catalog: RemoteArtifactCatalog.load(remoteDirectory: nil, macHelper: helper), clientID: RemoteClientIdentity.randomHex())
        model.sshExecutable = ssh
        let fakeHome = home
        model.environment = { ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "FAKE_SSH_HOME": fakeHome] }
        model.confirmInstall = { _, _, _, _ in false }
        model.confirmRemove = { _ in false }
        model.confirmStopSessions = { _, _ in false }
    }

    override func tearDown() async throws {
        if let model, let host, model.preferences(host).helper?.state == .current {
            model.confirmRemove = { _ in true }
            model.confirmStopSessions = { _, _ in true }
            await model.remove(host)
        }
        try? FileManager.default.removeItem(atPath: root)
    }

    func testStatusIsObservedNeverAssumed() async throws {
        XCTAssertNil(model.preferences(host).helper, "Unknown until a check")
        await model.check(host)
        XCTAssertEqual(model.preferences(host).helper?.state, .missing)
        XCTAssertEqual(model.preferences(host).helper?.system, "Darwin")
        XCTAssertNil(model.activity[host.id])

        var asked = false
        model.confirmInstall = { _, probe, artifact, update in
            asked = true
            XCTAssertFalse(update)
            XCTAssertEqual(probe.platform, "darwin")
            XCTAssertEqual(artifact.platform, "darwin")
            return false
        }
        await model.install(host)
        XCTAssertTrue(asked)
        XCTAssertEqual(model.messages[host.id], "Nothing was installed.")
        XCTAssertEqual(model.preferences(host).helper?.state, .missing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home + "/.trellis"))

        model.confirmInstall = { _, _, _, _ in true }
        await model.install(host)
        XCTAssertEqual(model.preferences(host).helper?.state, .current)
        XCTAssertEqual(model.messages[host.id], "The helper is installed.")
        let reloaded = await RemoteHostSettings(stateDirectory: URL(fileURLWithPath: root + "/state")).preferences(host.id)
        XCTAssertEqual(reloaded.helper?.state, .current, "Saved for the next launch")
    }

    func testRemoveProtectsRunningSessions() async throws {
        model.confirmInstall = { _, _, _, _ in true }
        await model.install(host)
        // A session this Mac left running on the host.
        let link = RemoteHostLink(
            request: .init(sshExecutable: model.sshExecutable, options: [], destination: host.destination, environment: model.environment(), clientID: model.clientID!),
            catalog: model.catalog)
        _ = try await link.run(.bridge, install: .never).get()
        let spawned = try await XCTUnwrap(link.connection).request(
            .spawnLogin(BrokerLoginRequest(sessionID: UUID(), shell: "/bin/sh", directory: nil, environment: [:], integration: nil, columns: 80, rows: 24)))
        guard case .spawned = spawned else { return XCTFail("\(spawned)") }
        link.close()

        await model.remove(host)
        XCTAssertEqual(model.preferences(host).helper?.state, .current, "Not confirmed: nothing removed")

        model.confirmRemove = { _ in true }
        var running = 0
        model.confirmStopSessions = { _, count in
            running = count; return false
        }
        await model.remove(host)
        XCTAssertEqual(running, 1)
        XCTAssertEqual(model.messages[host.id], "The helper was kept, with its 1 running session(s).")
        XCTAssertTrue(FileManager.default.fileExists(atPath: home + "/.trellis/remote"))

        model.confirmStopSessions = { _, _ in true }
        await model.remove(host)
        XCTAssertEqual(model.preferences(host).helper?.state, .missing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home + "/.trellis"))
    }

    func testRemoveProtectsAnOlderHelpersSessions() async throws {
        model.confirmInstall = { _, _, _, _ in true }
        await model.install(host)
        let directory = try XCTUnwrap(model.catalog.artifacts["darwin"]).directory
        // After a Trellis update only the older helper is installed (FR-RW14), and its broker still runs a session.
        try FileManager.default.moveItem(atPath: home + "/.trellis/remote/" + directory, toPath: home + "/.trellis/remote/" + String(repeating: "0", count: 16))
        await model.check(host)
        XCTAssertEqual(model.preferences(host).helper?.state, .outdated)
        let link = RemoteHostLink(
            request: .init(sshExecutable: model.sshExecutable, options: [], destination: host.destination, environment: model.environment(), clientID: model.clientID!),
            catalog: model.catalog)
        _ = try await link.run(.bridge, install: .never).get()
        let spawned = try await XCTUnwrap(link.connection).request(
            .spawnLogin(BrokerLoginRequest(sessionID: UUID(), shell: "/bin/sh", directory: nil, environment: [:], integration: nil, columns: 80, rows: 24)))
        guard case .spawned = spawned else { return XCTFail("\(spawned)") }
        link.close()

        model.confirmRemove = { _ in true }
        var running = 0
        model.confirmStopSessions = { _, count in
            running = count; return false
        }
        await model.remove(host)
        XCTAssertEqual(running, 1, "An outdated helper's sessions are counted too")
        XCTAssertTrue(FileManager.default.fileExists(atPath: home + "/.trellis/remote"))

        model.confirmStopSessions = { _, _ in true }
        await model.remove(host)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home + "/.trellis"))
    }

    func testRemoveIsRefusedWhenSessionsCannotBeChecked() async throws {
        model.confirmInstall = { _, _, _, _ in true }
        await model.install(host)
        // ssh fails before the helper answers: the count is unknown, never taken as zero.
        let ssh = model.sshExecutable
        model.sshExecutable = "/usr/bin/false"
        model.confirmRemove = { _ in true }
        model.confirmStopSessions = { _, _ in true }
        await model.remove(host)
        model.sshExecutable = ssh
        XCTAssertEqual(model.messages[host.id]?.hasPrefix("The helper was kept"), true, model.messages[host.id] ?? "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: home + "/.trellis/remote"))
    }

    func testAnUnreadableHostLibraryKeepsEveryHostsSettings() async {
        await model.setAutoInstall(host, true)
        let storage = MemoryHosts()
        storage.data = Data("not json".utf8)
        let hosts = HostListModel(library: HostLibrary(storage: storage))
        hosts.remote = model
        await hosts.load()
        XCTAssertTrue(hosts.loadFailed)
        let saved = await RemoteHostSettings(stateDirectory: URL(fileURLWithPath: root + "/state")).preferences(host.id)
        XCTAssertTrue(saved.autoInstall, "Kept for when the library is readable again")
    }

    func testALinkThatDropsWhileItsStatusIsSavedIsNeverHandedOut() async throws {
        model.confirmInstall = { _, _, _, _ in true }
        await model.install(host)
        var reported: [RemoteHostLink.State] = []
        model.onWorkspaceLinkChanged = { _, state in reported.append(state) }
        // The settings actor is busy, so the new link waits to record its probe; it drops meanwhile.
        let settings = model.settings, other = UUID()
        let busy = Task.detached { await settings.update(other) { _ in usleep(1_500_000) } }
        try await Task.sleep(for: .milliseconds(100))
        let pending = Task { await self.model.workspaceLink(self.host, interactive: false) }
        let deadline = Date().addingTimeInterval(10)
        while model.workspaceConnection(host.id) == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try XCTUnwrap(model.workspaceConnection(host.id)).close()
        let result = await pending.value
        _ = await busy.value
        guard case .failure(.lost) = result else { return XCTFail("Returned \(result), never connected") }
        XCTAssertEqual(reported, [.failed(.lost)], "The drop reaches the sidebar, which schedules a reconnect")
        XCTAssertNil(model.workspaceConnection(host.id))
    }

    func testCancelStopsOnlyTheHostsActionNeverItsWorkspaceLink() async throws {
        model.confirmInstall = { _, _, _, _ in true }
        await model.install(host)
        // An update waits at its confirmation while an automatic reconnect opens the workspace link.
        var release: CheckedContinuation<Bool, Never>?
        model.confirmInstall = { _, _, _, _ in await withCheckedContinuation { release = $0 } }
        let action = Task { await self.model.install(self.host) }
        let deadline = Date().addingTimeInterval(10)
        while release == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard case .success(let workspace) = await model.workspaceLink(host, interactive: false) else { return XCTFail("No workspace link") }

        model.cancel(host)
        release?.resume(returning: true)
        await action.value
        XCTAssertEqual(model.messages[host.id], "Cancelled.")
        XCTAssertEqual(workspace.state, .connected, "Cancel never closes the link the host's workspaces share")
        model.closeWorkspaceLinks()
        XCTAssertEqual(workspace.state, .closed)
    }

    func testAutoInstallIsOffByDefaultAndSaved() async {
        XCTAssertFalse(model.preferences(host).autoInstall)
        await model.setAutoInstall(host, true)
        let saved = await RemoteHostSettings(stateDirectory: URL(fileURLWithPath: root + "/state")).preferences(host.id)
        XCTAssertTrue(saved.autoInstall)
    }
}
