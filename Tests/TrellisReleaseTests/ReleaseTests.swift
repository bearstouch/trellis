import XCTest
@testable import TrellisRelease

final class ReleaseTests: XCTestCase {
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }

    private func manifest() throws -> ReleaseManifest {
        try JSONDecoder().decode(ReleaseManifest.self, from: Data(contentsOf: root.appendingPathComponent("release/manifest.json")))
    }

    func testManifestMatchesSupportPolicy() throws {
        let manifest = try manifest()
        XCTAssertEqual(manifest.bundleIdentifier, "dev.trellis")
        XCTAssertEqual(Set(manifest.architectures), ["arm64", "x86_64"], "Universal 2")
        XCTAssertTrue(manifest.artifacts.contains("Trellis.app/Contents/Helpers/trellis"), "The CLI is bundled")
        XCTAssertEqual(manifest.dependencies.map(\.license), ["MIT", "OFL-1.1"])
        // Package.swift's deployment target must match the release policy.
        let package = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
        let packageMinimum = package.contains(".macOS(.v14)") ? "14.0" : "unknown"
        for dependency in manifest.dependencies {
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(dependency.licenseFile).path), dependency.licenseFile)
        }

        let good = ReleaseManifest.BuiltProduct(bundleIdentifier: "dev.trellis", minimumMacOS: "14.0", architectures: ["arm64", "x86_64"], files: Set(manifest.artifacts))
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

    func testCleanupAllowlistProtectsUserFiles() {
        let home = "/Users/fixture"
        let items = UninstallPlanner.items(home: home, cliLink: "/Users/fixture/.local/bin/trellis")
        XCTAssertEqual(items.count, 5)
        for item in items {
            XCTAssertTrue(item.path.hasPrefix(home + "/"))
            for protected in [".ssh", "id_rsa", "id_ed25519", "known_hosts", "_history", ".zshrc", ".bashrc", ".profile", "Keychains"] {
                XCTAssertFalse(item.path.contains(protected), "\(item.path) touches \(protected)")
            }
        }
        for path in [
            "/Users/fixture/.ssh/config", "/Users/fixture/.ssh/id_ed25519", "/Users/fixture/.ssh/known_hosts", "/Users/fixture/.zsh_history",
            "/Users/fixture/.bash_history", "/Users/fixture/.zshrc", "/Users/fixture/Library/Keychains/login.keychain-db",
            "/Users/fixture/.ssh/dev.trellis", "/Users/other/Library/Application Support/dev.trellis", "/Users/fixture/Documents",
            "/Users/fixture/Projects/dev.trellis", "/Users/fixture/.SSH/trellis", "/Users/fixture/library/keychains/trellis", "/Users/fixture/Library/Caches/dev.trellis.other",
            "/Users/fixture/Library/Application Support/dev.trellis/../../../.zshrc"
        ] {
            XCTAssertFalse(UninstallPlanner.isAllowed(path, home: home), path)
        }
        XCTAssertTrue(UninstallPlanner.isAllowed("/Users/fixture/Library/Application Support/dev.trellis", home: home))
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
