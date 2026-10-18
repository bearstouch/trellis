import Darwin
import XCTest
@testable import TrellisCore

/// FR-R04: the opt-in scrollback file.
final class ScrollbackStoreTests: XCTestCase {
    private var root: URL!
    private var store: ScrollbackStore!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-scrollback-\(UUID())")
        store = ScrollbackStore(directory: root.appendingPathComponent("Scrollback"))
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func mode(_ path: String) -> mode_t {
        var info = stat()
        XCTAssertEqual(lstat(path, &info), 0)
        return info.st_mode & 0o777
    }

    func testSavesRedactedOwnerOnlyFilesAndLoadsThem() async throws {
        let id = UUID()
        let written = await store.replaceAll([(id, "$ export GITHUB_TOKEN=ghp_abcdefghijklmnopqrstuvwxyz0123456789\nok")])
        XCTAssertEqual(written, [id])
        let path = store.directory.appendingPathComponent("\(id.uuidString).txt").path
        XCTAssertEqual(mode(path), 0o600)
        XCTAssertEqual(mode(store.directory.path), 0o700)
        let saved = await store.load(sessionID: id)
        let loaded = try XCTUnwrap(saved)
        XCTAssertFalse(loaded.text.contains("ghp_"), "Secrets are redacted before writing")
        XCTAssertTrue(loaded.text.contains("[redacted]"))
        XCTAssertTrue(loaded.text.hasSuffix("ok"))
        XCTAssertLessThan(abs(loaded.savedAt.timeIntervalSinceNow), 60)
    }

    func testEachFileKeepsTheNewestMebibyteFromALineStart() async throws {
        let id = UUID()
        let line = String(repeating: "a", count: 99) + "\n"
        await store.replaceAll([(id, String(repeating: line, count: 12_000) + "END")])
        let saved = await store.load(sessionID: id)
        let text = try XCTUnwrap(saved).text
        XCTAssertLessThanOrEqual(text.utf8.count, ScrollbackStore.fileLimit)
        XCTAssertTrue(text.hasPrefix("a"), "Starts on a whole line")
        XCTAssertTrue(text.hasSuffix("END"))
        XCTAssertEqual(ScrollbackStore.tail("é" + String(repeating: "b", count: 10), limit: 10), String(repeating: "b", count: 10))
    }

    func testTheTotalIsCappedAndOtherFilesAreRemoved() async throws {
        let big = String(repeating: String(repeating: "c", count: 1023) + "\n", count: 1024)
        let ids = (0..<70).map { _ in UUID() }
        let stale = UUID()
        await store.replaceAll([(stale, "old")])
        let written = await store.replaceAll(ids.map { ($0, big) })
        XCTAssertLessThan(written.count, ids.count, "Pane texts beyond 64 MiB are not saved")
        let files = try FileManager.default.contentsOfDirectory(atPath: store.directory.path)
        XCTAssertEqual(Set(files), Set(written.map { "\($0.uuidString).txt" }))
        let total = try files.reduce(0) { $0 + (try FileManager.default.attributesOfItem(atPath: store.directory.appendingPathComponent($1).path)[.size] as? Int ?? 0) }
        XCTAssertLessThanOrEqual(total, ScrollbackStore.totalLimit)
        let loadedStale = await store.load(sessionID: stale)
        XCTAssertNil(loadedStale)
    }

    func testSymlinksAreNeverFollowed() async throws {
        let id = UUID()
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let target = root.appendingPathComponent("elsewhere.txt")
        try Data("secret elsewhere".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(atPath: store.directory.appendingPathComponent("\(id.uuidString).txt").path, withDestinationPath: target.path)
        let loaded = await store.load(sessionID: id)
        XCTAssertNil(loaded, "A symlinked file is refused")

        let linked = ScrollbackStore(directory: root.appendingPathComponent("Linked"))
        try FileManager.default.createSymbolicLink(atPath: linked.directory.path, withDestinationPath: store.directory.path)
        let written = await linked.replaceAll([(UUID(), "text")])
        XCTAssertTrue(written.isEmpty, "A symlinked directory is never written through")
    }

    func testRetainAndDeleteAllTouchOnlyScrollbackFiles() async throws {
        let keep = UUID(), drop = UUID()
        await store.replaceAll([(keep, "keep"), (drop, "drop")])
        let unrelated = store.directory.appendingPathComponent("notes.md")
        try Data("x".utf8).write(to: unrelated)
        await store.retain([keep])
        let names = try FileManager.default.contentsOfDirectory(atPath: store.directory.path)
        XCTAssertEqual(Set(names), ["\(keep.uuidString).txt", "notes.md"])
        await store.delete(sessionIDs: [keep])
        await store.deleteAll()
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path), "Only files this store writes are removed")
        try FileManager.default.removeItem(at: unrelated)
        await store.deleteAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.path))
    }
}

/// FR-R05: best-effort redaction, one case per pattern plus controls that must survive.
final class ScrollbackRedactorTests: XCTestCase {
    private func assertRedacted(_ input: String, hiding secret: String, file: StaticString = #filePath, line: UInt = #line) {
        let output = ScrollbackRedactor.redact(input)
        XCTAssertFalse(output.contains(secret), "\(input) → \(output)", file: file, line: line)
        XCTAssertTrue(output.contains(ScrollbackRedactor.marker), output, file: file, line: line)
    }

    func testEachPatternIsRedacted() {
        assertRedacted("-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA\n-----END OPENSSH PRIVATE KEY-----", hiding: "b3BlbnNzaC1rZXktdjEAAAAA")
        assertRedacted(String(repeating: "QUJD", count: 16), hiding: "QUJDQUJD")
        assertRedacted("Authorization: Basic dXNlcjpwYXNz", hiding: "dXNlcjpwYXNz")
        assertRedacted("curl -H 'X: Bearer abcdef0123456789'", hiding: "abcdef0123456789")
        assertRedacted("git clone https://deploy:hunter2secret@example.com/repo.git", hiding: "hunter2secret")
        assertRedacted("PASSWORD=correct-horse", hiding: "correct-horse")
        assertRedacted("db_passwd: s3cr3tvalue", hiding: "s3cr3tvalue")
        assertRedacted(#"{"client_secret": "abc123xyz"}"#, hiding: "abc123xyz")
        assertRedacted("mytool --api-key=k-123456 --verbose", hiding: "k-123456")
        assertRedacted("mytool --token t0k3nvalue", hiding: "t0k3nvalue")
        assertRedacted("aws_secret_access_key = wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY", hiding: "wJalrXUtnFEMI")
        assertRedacted("key AKIAIOSFODNN7EXAMPLE in use", hiding: "AKIAIOSFODNN7EXAMPLE")
        assertRedacted("ASIAIOSFODNN7EXAMPLE", hiding: "ASIAIOSFODNN7EXAMPLE")
        assertRedacted("ghp_abcdefghijklmnopqrstuvwxyz0123456789", hiding: "ghp_abcdefghij")
        assertRedacted("github_pat_11ABCDEFG0123456789_abcdefghijkl", hiding: "github_pat_11ABC")
        assertRedacted("glpat-abcdefghij0123456789", hiding: "glpat-abcdefghij")
        assertRedacted("xoxb-1234567890-abcdefghij", hiding: "xoxb-1234567890")
        assertRedacted("sk-ant-api03-abcdefghijklmnopqrstuv", hiding: "sk-ant-api03")
        assertRedacted("sk-proj-abcdefghijklmnopqrstuvwx", hiding: "sk-proj-abcdef")
        assertRedacted("sk_live_abcdefghijklmnop1234", hiding: "sk_live_abcdef")
        assertRedacted("rk_live_abcdefghijklmnop1234", hiding: "rk_live_abcdef")
        assertRedacted("AIzaSyA-abcdefghijklmnopqrstuvwxyz12345", hiding: "AIzaSyA-abcdef")
        assertRedacted("npm_abcdefghijklmnopqrstuvwxyz0123456789", hiding: "npm_abcdefghij")
        assertRedacted("eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.dozjgNryP4J3jVmNHl0w5N", hiding: "dozjgNryP4J3jVmNHl0w5N")
        assertRedacted("Password: typed-because-echo-was-on", hiding: "typed-because")
        assertRedacted("deploy@prod's password for vault: leaked", hiding: "leaked")
    }

    func testOrdinaryOutputSurvives() {
        for text in [
            "The token is valid.", "tokenizer finished in 2s", "password reset complete", "Password:", "https://example.com/path?q=1",
            "Compiling 12 files", "ssh deploy@example.com", "PATH=/usr/bin:/bin", "sk-short", "secrets/", "git log --oneline"
        ] {
            XCTAssertEqual(ScrollbackRedactor.redact(text), text, text)
        }
    }
}
