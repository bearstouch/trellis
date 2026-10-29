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

    func testAutoInstallIsOffByDefaultAndSaved() async {
        XCTAssertFalse(model.preferences(host).autoInstall)
        await model.setAutoInstall(host, true)
        let saved = await RemoteHostSettings(stateDirectory: URL(fileURLWithPath: root + "/state")).preferences(host.id)
        XCTAssertTrue(saved.autoInstall)
    }
}
