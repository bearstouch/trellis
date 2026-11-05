import XCTest
@testable import TrellisRelease

final class ReleaseTests: XCTestCase {
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }

    private func manifest() throws -> ReleaseManifest {
        try JSONDecoder().decode(ReleaseManifest.self, from: Data(contentsOf: root.appendingPathComponent("release/manifest.json")))
    }

    func testManifestMatchesSupportPolicy() throws {
        let manifest = try manifest()
        XCTAssertEqual(manifest.bundleIdentifier, "com.bearstouch.trellis")
        XCTAssertEqual(Set(manifest.architectures), ["arm64", "x86_64"], "Universal 2")
        XCTAssertTrue(manifest.artifacts.contains("Trellis.app/Contents/Helpers/trellis"), "The CLI is bundled")
        XCTAssertTrue(manifest.artifacts.contains("Trellis.app/Contents/Helpers/trellis-askpass"), "The saved-password askpass helper is bundled")
        XCTAssertTrue(manifest.artifacts.contains("Trellis.app/Contents/Helpers/trellis-broker"), "The keep-running session broker is bundled")
        XCTAssertTrue(UninstallPlanner.firstStep.contains("trellis-broker"), "Uninstalling first ends kept sessions")
        XCTAssertEqual(UninstallPlanner.keychainServices, ["Trellis Automation", "Trellis SSH Host"], "Uninstall lists every Keychain service")
        XCTAssertEqual(
            manifest.dependencies.map(\.license),
            ["MIT", "MIT"]
                // The tool dock's highlighting: Neon, SwiftTreeSitter, Rearrange, then tree-sitter and its eight grammars (FR-TD11).
                + Array(repeating: "BSD-3-Clause", count: 3) + Array(repeating: "MIT", count: 9)
                + Array(repeating: "OFL-1.1", count: 6) + ["MIT", "MIT", "BSD-3-Clause"],
            "Plus musl, mimalloc and musl-fts in the Linux remote helpers")
        // Package.swift's deployment target must match the release policy.
        let package = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
        let packageMinimum = package.contains(".macOS(.v14)") ? "14.0" : "unknown"
        for dependency in manifest.dependencies {
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(dependency.licenseFile).path), dependency.licenseFile)
        }

        let good = ReleaseManifest.BuiltProduct(bundleIdentifier: "com.bearstouch.trellis", minimumMacOS: "14.0", architectures: ["arm64", "x86_64"], files: Set(manifest.artifacts))
        XCTAssertEqual(manifest.problems(packageMinimumMacOS: packageMinimum, product: good), [])
        var bad = good
        bad.architectures = ["arm64"]
        bad.minimumMacOS = "13.0"
        bad.files.remove("Trellis.app/Contents/Helpers/trellis")
        let problems = manifest.problems(packageMinimumMacOS: "15.0", product: bad)
        XCTAssertEqual(problems.count, 4, "\(problems)")
        XCTAssertTrue(problems.contains { $0.contains("x86_64") })
        XCTAssertTrue(problems.contains { $0.contains("Helpers/trellis") })
    }

    func testSparkleIsPinnedBundledAndKeyed() throws {
        let manifest = try manifest()
        let sparkle = try XCTUnwrap(manifest.dependencies.first { $0.name == "Sparkle" })
        XCTAssertTrue(manifest.artifacts.contains("Trellis.app/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle"), "MAC-14: Sparkle is embedded")
        XCTAssertTrue(manifest.artifacts.contains("Trellis.app/Contents/Resources/Sparkle-LICENSE.txt"))
        // The manifest records exactly what SwiftPM resolved, and Package.swift pins that exact version.
        let resolved = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("Package.resolved"))) as? [String: Any]
        let pin = try XCTUnwrap((resolved?["pins"] as? [[String: Any]])?.first { $0["identity"] as? String == "sparkle" }?["state"] as? [String: String])
        XCTAssertEqual(pin["version"], sparkle.version)
        XCTAssertEqual(pin["revision"], sparkle.revision)
        let package = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
        XCTAssertTrue(package.contains("exact: \"\(sparkle.version)\""))

        let product = ReleaseManifest.BuiltProduct(bundleIdentifier: manifest.bundleIdentifier, minimumMacOS: manifest.minimumMacOS, architectures: Set(manifest.architectures), files: Set(manifest.artifacts))
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("release/manifest.json"))) as! [String: Any]
        json["sparklePublicKey"] = Data(repeating: 7, count: 32).base64EncodedString()
        let keyed = try JSONDecoder().decode(ReleaseManifest.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(keyed.problems(packageMinimumMacOS: manifest.minimumMacOS, product: product), [])
        json["sparklePublicKey"] = "not-a-key"
        let broken = try JSONDecoder().decode(ReleaseManifest.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(broken.problems(packageMinimumMacOS: manifest.minimumMacOS, product: product), ["sparklePublicKey is not a base64 Ed25519 public key."])
    }

    func testCliLinkPlanIsUserLocal() {
        let home = "/Users/fixture", cli = "/Applications/Trellis.app/Contents/Helpers/trellis"
        XCTAssertEqual(
            CLILinkPlanner.install(directory: "~/.local/bin", home: home, cliPath: cli, existing: .nothing),
            .create(link: "/Users/fixture/.local/bin/trellis", target: cli))
        XCTAssertEqual(
            CLILinkPlanner.install(directory: "~/.local/bin", home: home, cliPath: cli, existing: .symlink(to: cli)), .alreadyInstalled(link: "/Users/fixture/.local/bin/trellis"))
        // A moved or upgraded app replaces only its own link.
        XCTAssertEqual(
            CLILinkPlanner.install(directory: "~/bin", home: home, cliPath: cli, existing: .symlink(to: "/Users/fixture/Downloads/Trellis.app/Contents/Helpers/trellis")),
            .replace(link: "/Users/fixture/bin/trellis", target: cli))
        // Unrelated files are preserved.
        for existing: CLILinkPlanner.Existing in [.otherFile, .symlink(to: "/usr/local/bin/other-tool")] {
            guard case .refused = CLILinkPlanner.install(directory: "~/.local/bin", home: home, cliPath: cli, existing: existing) else { return XCTFail("Overwrote \(existing)") }
            guard case .refused = CLILinkPlanner.remove(directory: "~/.local/bin", home: home, existing: existing) else { return XCTFail("Removed \(existing)") }
        }
        // Targets outside the user's home, or in sensitive folders, are refused.
        for directory in ["/usr/local/bin", "/opt/homebrew/bin", "~/../other/bin", "/Users/fixture2/bin", "~/.ssh", "~/.SSH", "~/library/LaunchAgents", "~/Library/Application Support", "/Users/fixture", "bin", "~"] {
            guard case .refused = CLILinkPlanner.install(directory: directory, home: home, cliPath: cli, existing: .nothing) else { return XCTFail("Accepted \(directory)") }
        }
        XCTAssertEqual(CLILinkPlanner.remove(directory: "~/.local/bin", home: home, existing: .symlink(to: cli)), .remove(link: "/Users/fixture/.local/bin/trellis"))
        XCTAssertEqual(CLILinkPlanner.remove(directory: "~/.local/bin", home: home, existing: .nothing), .nothingToRemove)
    }

    private final class FakeLinks {
        var state: [String: CLILinkPlanner.Existing] = [:]
        var executables: Set<String> = []
        var resolved: [String: String] = [:]
        var createFailures = 0
        var log: [String] = []
        var effects: CLILinkEffects {
            CLILinkEffects(
                resolvePath: { self.resolved[$0] ?? $0 }, linkState: { self.state[$0] ?? .nothing },
                createLink: { link, target in
                    if self.createFailures > 0 { self.createFailures -= 1; throw CocoaError(.fileWriteUnknown) }
                    self.log.append("create \(link) -> \(target)"); self.state[link] = .symlink(to: target)
                },
                removeLink: {
                    self.log.append("remove \($0)"); self.state[$0] = nil
                }, isExecutable: { self.executables.contains($0) })
        }
    }
    private let fixtureHome = "/Users/fixture", fixtureBundle = "/Applications/Trellis.app"
    private let fixtureCLI = "/Applications/Trellis.app/Contents/Helpers/trellis", fixtureLink = "/Users/fixture/.local/bin/trellis"

    func testInstallerCreatesOneLinkAndLeavesConflictsAlone() throws {
        let fake = FakeLinks()
        XCTAssertEqual(try CLILinkInstaller.install(home: fixtureHome, cliPath: fixtureCLI, effects: fake.effects), .installed(link: fixtureLink))
        XCTAssertEqual(fake.log, ["create \(fixtureLink) -> \(fixtureCLI)"])
        XCTAssertEqual(try CLILinkInstaller.install(home: fixtureHome, cliPath: fixtureCLI, effects: fake.effects), .alreadyInstalled(link: fixtureLink))
        XCTAssertEqual(fake.log.count, 1, "Installing again changes nothing")
        for existing: CLILinkPlanner.Existing in [.otherFile, .symlink(to: "/opt/homebrew/bin/other-trellis")] {
            let other = FakeLinks(); other.state[fixtureLink] = existing
            guard case .conflict = try CLILinkInstaller.install(home: fixtureHome, cliPath: fixtureCLI, effects: other.effects) else { return XCTFail("Replaced \(existing)") }
            XCTAssertEqual(other.log, [])
        }
    }

    func testInstallerRefusesADirectoryThatResolvesOutsideHome() throws {
        let fake = FakeLinks(); fake.resolved["/Users/fixture/.local/bin"] = "/usr/local/bin"
        guard case .invalidDirectory = try CLILinkInstaller.install(home: fixtureHome, cliPath: fixtureCLI, effects: fake.effects) else { return XCTFail("Linked outside home") }
        XCTAssertEqual(fake.log, [])
    }

    func testFailedReplaceRestoresThePreviousLink() {
        let fake = FakeLinks(), previous = "/Users/fixture/Downloads/Trellis.app/Contents/Helpers/trellis"
        fake.state[fixtureLink] = .symlink(to: previous); fake.createFailures = 1
        XCTAssertThrowsError(try CLILinkInstaller.install(home: fixtureHome, cliPath: fixtureCLI, effects: fake.effects))
        XCTAssertEqual(fake.state[fixtureLink], .symlink(to: previous))
    }

    func testInstallLocationSeparatesStableFromTransient() {
        XCTAssertEqual(CLILinkInstaller.location(bundlePath: fixtureBundle, home: fixtureHome, isReadOnlyVolume: false), .stable)
        XCTAssertEqual(CLILinkInstaller.location(bundlePath: "/Users/fixture/Applications/Trellis.app", home: fixtureHome, isReadOnlyVolume: false), .stable)
        XCTAssertEqual(CLILinkInstaller.location(bundlePath: "/Users/fixture/Downloads/Trellis.app", home: fixtureHome, isReadOnlyVolume: false), .elsewhere)
        XCTAssertEqual(CLILinkInstaller.location(bundlePath: "/Volumes/Trellis 1.0/Trellis.app", home: fixtureHome, isReadOnlyVolume: true), .transient)
        XCTAssertEqual(CLILinkInstaller.location(bundlePath: "/private/var/folders/x/AppTranslocation/ABC/d/Trellis.app", home: fixtureHome, isReadOnlyVolume: false), .transient)
    }

    func testOfferAsksOnlyWhenALinkWouldWorkAndNoneExists() {
        let offer = { (fake: FakeLinks, bundle: String, readOnly: Bool) in
            CLILinkInstaller.offer(bundlePath: bundle, home: self.fixtureHome, isReadOnlyVolume: readOnly, effects: fake.effects)
        }
        XCTAssertEqual(offer(FakeLinks(), fixtureBundle, false), .ask)
        XCTAssertEqual(offer(FakeLinks(), "/Volumes/Trellis/Trellis.app", true), .skip, "A link into the DMG would break")
        XCTAssertEqual(offer(FakeLinks(), "/Users/fixture/Downloads/Trellis.app", false), .skip)
        let installed = FakeLinks(); installed.state[fixtureLink] = .symlink(to: fixtureCLI)
        XCTAssertEqual(offer(installed, fixtureBundle, false), .alreadyInstalled)
        let inBin = FakeLinks(); inBin.state["/Users/fixture/bin/trellis"] = .symlink(to: fixtureCLI)
        XCTAssertEqual(offer(inBin, fixtureBundle, false), .alreadyInstalled, "A link made with --dir ~/bin counts")
        let conflict = FakeLinks(); conflict.state[fixtureLink] = .otherFile
        XCTAssertEqual(offer(conflict, fixtureBundle, false), .skip, "Don't offer what would fail")
        let stale = FakeLinks(); stale.state[fixtureLink] = .symlink(to: "/Users/fixture/Downloads/Trellis.app/Contents/Helpers/trellis")
        XCTAssertEqual(offer(stale, fixtureBundle, false), .ask, "A link to a moved copy can be repaired")
        let escaped = FakeLinks(); escaped.resolved["/Users/fixture/.local/bin"] = "/usr/local/bin"
        XCTAssertEqual(offer(escaped, fixtureBundle, false), .skip)
        XCTAssertEqual(escaped.log, [], "Offering never changes anything")
    }

    func testPathStatusFindsWhichTrellisRuns() {
        let fake = FakeLinks(); fake.executables = [fixtureLink]; fake.resolved[fixtureLink] = fixtureCLI
        let status = { (path: [String]?) in CLILinkInstaller.pathStatus(link: self.fixtureLink, searchPath: path, effects: fake.effects) }
        XCTAssertEqual(status(nil), .unknown)
        XCTAssertEqual(status(["/usr/bin", "/bin"]), .notOnPath)
        XCTAssertEqual(status(["/usr/bin", "/Users/fixture/.local/bin/"]), .onPath, "A trailing slash is the same directory")
        fake.executables.insert("/opt/homebrew/bin/trellis")
        XCTAssertEqual(status(["/opt/homebrew/bin", "/Users/fixture/.local/bin"]), .shadowed(by: "/opt/homebrew/bin/trellis"))
        XCTAssertEqual(status(["/Users/fixture/.local/bin", "/opt/homebrew/bin"]), .onPath)
        fake.resolved["/opt/homebrew/bin/trellis"] = fixtureCLI
        XCTAssertEqual(status(["/opt/homebrew/bin", "/Users/fixture/.local/bin"]), .onPath, "Another link to the same CLI isn't a rival")
    }

    func testPathSetupCommandMatchesTheShell() {
        XCTAssertEqual(CLILinkInstaller.pathSetupCommand(shell: "/bin/zsh"), #"echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc"#)
        XCTAssertEqual(CLILinkInstaller.pathSetupCommand(shell: "/bin/bash"), #"echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bash_profile"#)
        XCTAssertEqual(CLILinkInstaller.pathSetupCommand(shell: "/opt/homebrew/bin/fish"), "fish_add_path $HOME/.local/bin")
        XCTAssertEqual(CLILinkInstaller.pathSetupCommand(shell: "/bin/ksh"), #"export PATH="$HOME/.local/bin:$PATH""#)
    }

    func testLoginShellPathParsesOnlyTheMarkedValue() {
        XCTAssertEqual(LoginShellPath.parse("Welcome!\n__TRELLIS_PATH_BEGIN__/a:/b__TRELLIS_PATH_END__\nbye"), ["/a", "/b"])
        XCTAssertEqual(LoginShellPath.parse("__TRELLIS_PATH_BEGIN__/old__TRELLIS_PATH_END__ __TRELLIS_PATH_BEGIN__/new__TRELLIS_PATH_END__"), ["/new"])
        XCTAssertNil(LoginShellPath.parse("no markers"))
        XCTAssertNil(LoginShellPath.parse("__TRELLIS_PATH_BEGIN____TRELLIS_PATH_END__"), "An empty PATH is unknown, not 'not on PATH'")
    }

    private func fakeShell(_ body: String) throws -> (URL, String) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tshell-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("shell")
        try ("#!/bin/sh\n" + body + "\n").write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return (directory, script.path)
    }

    func testLoginShellPathReadsThroughStartupNoise() throws {
        let (directory, shell) = try fakeShell(#"echo "startup noise"; PATH=/fixture/a:/fixture/b:$PATH; eval "$4"; echo after"#)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertEqual(LoginShellPath.query(shell: shell)?.prefix(2), ["/fixture/a", "/fixture/b"])
    }

    func testLoginShellPathGivesUpOnAHangingOrFailingShell() throws {
        // Ignores SIGTERM and keeps a child holding the pipe, the worst a startup file can do.
        let (directory, hanging) = try fakeShell("trap '' TERM; sleep 20 & while true; do sleep 1; done")
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = Date()
        XCTAssertNil(LoginShellPath.query(shell: hanging, timeout: 0.3))
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        let (failingDirectory, failing) = try fakeShell("exit 1")
        defer { try? FileManager.default.removeItem(at: failingDirectory) }
        XCTAssertNil(LoginShellPath.query(shell: failing))
        XCTAssertNil(LoginShellPath.query(shell: "/nonexistent/shell"))
    }

    func testLoginShellPathDoesNotLeakDescriptors() throws {
        let (directory, shell) = try fakeShell(#"eval "$4""#)
        defer { try? FileManager.default.removeItem(at: directory) }
        let open = { (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? 0 }
        XCTAssertNotNil(LoginShellPath.query(shell: shell))
        let before = open()
        for _ in 0..<12 { XCTAssertNotNil(LoginShellPath.query(shell: shell)) }
        XCTAssertLessThan(open() - before, 6, "Each query closes its pipe")
    }

    func testLiveExecutableCheckIgnoresADirectory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("texec-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertFalse(CLILinkEffects.live.isExecutable(directory.path))
        XCTAssertTrue(CLILinkEffects.live.isExecutable("/bin/sh"))
    }

    func testCleanupAllowlistProtectsUserFiles() {
        let home = "/Users/fixture"
        let items = UninstallPlanner.items(home: home, cliLink: "/Users/fixture/.local/bin/trellis")
        XCTAssertEqual(items.count, 9)
        XCTAssertTrue(items.contains { $0.path == "/Users/fixture/Library/Application Support/dev.trellis" }, "Data left by the identifier migration is listed")
        XCTAssertEqual(UninstallPlanner.items(home: home, bundleIdentifier: "com.bearstouch.trellis.dev").count, 4)
        for item in items {
            XCTAssertTrue(item.path.hasPrefix(home + "/"))
            for protected in [".ssh", "id_rsa", "id_ed25519", "known_hosts", "_history", ".zshrc", ".bashrc", ".profile", "Keychains"] {
                XCTAssertFalse(item.path.contains(protected), "\(item.path) touches \(protected)")
            }
        }
        for path in [
            "/Users/fixture/.ssh/config", "/Users/fixture/.ssh/id_ed25519", "/Users/fixture/.ssh/known_hosts", "/Users/fixture/.zsh_history",
            "/Users/fixture/.bash_history", "/Users/fixture/.zshrc", "/Users/fixture/Library/Keychains/login.keychain-db",
            "/Users/fixture/.ssh/dev.trellis", "/Users/other/Library/Application Support/com.bearstouch.trellis", "/Users/fixture/Documents",
            "/Users/fixture/Projects/dev.trellis", "/Users/fixture/.SSH/trellis", "/Users/fixture/library/keychains/trellis", "/Users/fixture/Library/Caches/com.bearstouch.trellis.other",
            "/Users/fixture/Library/Application Support/com.bearstouch.trellis/../../../.zshrc"
        ] {
            XCTAssertFalse(UninstallPlanner.isAllowed(path, home: home), path)
        }
        XCTAssertTrue(UninstallPlanner.isAllowed("/Users/fixture/Library/Application Support/com.bearstouch.trellis", home: home))
    }

    func testReleaseChecklistRejectsMissingEvidence() {
        var checklist = ReleaseChecklist()
        let empty = checklist.missing(requiredArchitectures: ["arm64", "x86_64"], minimumMacOS: "14.0")
        XCTAssertTrue(empty.contains("Tested matrix: no passing run on arm64."))
        XCTAssertTrue(empty.contains("Tested matrix: no passing run on x86_64."))
        XCTAssertTrue(empty.contains("Tested matrix: no passing run on the minimum macOS 14.0."))
        XCTAssertTrue(empty.contains("Notarization is not evidenced."))
        XCTAssertTrue(empty.contains("Gatekeeper check on a clean machine is not evidenced."))
        XCTAssertTrue(empty.contains("Performance and reliability qualification is not evidenced."))

        // Only arm64 on a newer OS, ad-hoc signing, and a failed qualification: still not ready.
        checklist.matrix = [ReleaseChecklist.MatrixEntry(macOS: "26.6.2", architecture: "arm64", passed: true)]
        checklist.signatureVerified = true
        checklist.hardenedRuntime = true
        checklist.licensesRecorded = true
        checklist.cliInstallVerified = true
        checklist.acceptanceChecksComplete = true
        let partial = checklist.missing(requiredArchitectures: ["arm64", "x86_64"], minimumMacOS: "14.0")
        XCTAssertEqual(
            partial,
            [
                "Tested matrix: no passing run on x86_64.", "Tested matrix: no passing run on the minimum macOS 14.0.", "Notarization is not evidenced.",
                "Stapled ticket is not evidenced.", "Gatekeeper check on a clean machine is not evidenced.",
                "Performance and reliability qualification is not evidenced."
            ])
        // The minimum OS matches by major release only.
        checklist.matrix.append(ReleaseChecklist.MatrixEntry(macOS: "140.1", architecture: "arm64", passed: true))
        XCTAssertTrue(checklist.missing(requiredArchitectures: ["arm64"], minimumMacOS: "14.0").contains("Tested matrix: no passing run on the minimum macOS 14.0."))
        // A failed matrix run never counts.
        checklist.matrix.append(ReleaseChecklist.MatrixEntry(macOS: "14.7", architecture: "x86_64", passed: false))
        XCTAssertTrue(checklist.missing(requiredArchitectures: ["arm64", "x86_64"], minimumMacOS: "14.0").contains("Tested matrix: no passing run on x86_64."))

        checklist.matrix = [ReleaseChecklist.MatrixEntry(macOS: "14.7", architecture: "arm64", passed: true), ReleaseChecklist.MatrixEntry(macOS: "15.5", architecture: "x86_64", passed: true)]
        checklist.notarized = true
        checklist.stapled = true
        checklist.gatekeeperOnCleanMachine = true
        checklist.qualificationPassed = true
        XCTAssertEqual(checklist.missing(requiredArchitectures: ["arm64", "x86_64"], minimumMacOS: "14.0"), [], "Ready only when every item is evidenced")
    }
}
