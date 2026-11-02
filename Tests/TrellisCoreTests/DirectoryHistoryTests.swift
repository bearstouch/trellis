import XCTest
@testable import TrellisCore

/// FR-DJ01–FR-DJ09: what is remembered, how it ranks, and that the file fails safe.
final class DirectoryHistoryTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    private var scratch: URL!
    private let clock = Clock()
    private let host = UUID()

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-dj-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: scratch) }

    private var file: URL { scratch.appendingPathComponent(DirectoryHistory.fileName) }
    private var backup: URL { scratch.appendingPathComponent(DirectoryHistory.backupName) }

    /// Writes only on `flush()`, unless a test passes its own `sleep`.
    private func makeHistory(
        directory: URL? = nil, mounts: [DirectoryMount] = [], sleep: @escaping @Sendable (TimeInterval) async -> Void = { _ in try? await Task.sleep(for: .seconds(3600)) }
    ) -> DirectoryHistory {
        let clock = clock
        return DirectoryHistory(stateDirectory: directory ?? scratch, now: { clock.now }, sleep: sleep, mounts: { mounts })
    }

    private func document(_ entries: String, version: Int = 1) -> Data { Data("{\"version\":\(version),\"entries\":[\(entries)]}".utf8) }

    private func entryJSON(_ path: String, machine: String = "local", visits: Int = 1) -> String {
        "{\"path\":\"\(path)\",\"machine\":\"\(machine)\",\"visits\":\(visits),\"lastVisit\":\"2027-01-01T00:00:00Z\"}"
    }

    // MARK: Skip rules (FR-DJ04)

    func testPathRulesSkipSystemTemporaryAndCredentialFolders() {
        let skipped = [
            "/", "/net", "/net/server/share", "/Network/Servers", "/afs/x",
            "/proc", "/proc/1", "/sys/class", "/dev", "/run/user/1000", "/boot", "/tmp", "/tmp/x", "/var/tmp/y", "/var/run/z", "/var/lock", "/lost+found", "/snap/a", "/etc",
            "/etc/nginx", "/root", "/root/app", "/private/tmp/x", "/private/var/folders/a", "/private/etc", "/var/folders/ab", "/System/Library",
            "/Users/me/.ssh", "/Users/me/.ssh/keys", "/home/me/.gnupg", "/Users/me/.aws/sso", "/Users/me/.kube", "/Users/me/.password-store", "/Users/me/.Trash/x",
            "/Users/me", "/home/me"
        ]
        for path in skipped { XCTAssertFalse(DirectorySkipRules.allowsPath(path), path) }
        let kept = ["/Users/me/code", "/home/me/code/trellis", "/procfoo", "/network-share", "/etcetera", "/opt/app", "/srv/www", "/var/www/site", "/Users/me/.config/nvim", "/Volumes/Data/repo"]
        for path in kept { XCTAssertTrue(DirectorySkipRules.allowsPath(path), path) }
    }

    func testPathRulesIgnoreCaseBecauseMacOSFileSystemsDo() {
        for path in ["/NET/x", "/network", "/TMP", "/Users/me/.SSH", "/USERS/me", "/SYSTEM/Library"] { XCTAssertFalse(DirectorySkipRules.allowsPath(path), path) }
    }

    func testMalformedPathsAreSkipped() {
        for path in ["", "relative/path", "~/code", "/code/a\u{1B}[31m", "/code/a\nb", "/code/\u{200B}x", "/" + String(repeating: "a", count: 1024)] {
            XCTAssertFalse(DirectorySkipRules.allowsPath(path), path)
        }
        XCTAssertTrue(DirectorySkipRules.allowsPath("/" + String(repeating: "a", count: 1023)))
    }

    func testNetworkVolumesAreFoundFromTheMountTable() {
        let mounts = [
            DirectoryMount(path: "/", isLocal: true), DirectoryMount(path: "/Volumes/Share", isLocal: false), DirectoryMount(path: "/Volumes/Data", isLocal: true),
            DirectoryMount(path: "/Users/me/nfs", isLocal: false), DirectoryMount(path: "/Users/me/nfs/local", isLocal: true)
        ]
        for path in ["/Volumes/Share", "/Volumes/Share/repo", "/volumes/share/repo", "/Users/me/nfs/x", "/Volumes/Gone/repo", "/Volumes"] {
            XCTAssertTrue(DirectorySkipRules.isOnNetworkVolume(path, mounts: mounts), path)
        }
        for path in ["/Volumes/Data/repo", "/Users/me/code", "/Users/me/nfs/local/x"] {
            XCTAssertFalse(DirectorySkipRules.isOnNetworkVolume(path, mounts: mounts), path)
        }
        XCTAssertTrue(DirectorySkipRules.isOnNetworkVolume("/Volumes/Sharepoint-not/x", mounts: mounts), "A similar name isn't that mount, and has no mount of its own")
        XCTAssertTrue(DirectorySkipRules.isOnNetworkVolume("/Volumes/x", mounts: []), "With no table, /Volumes stays skipped")
        XCTAssertFalse(DirectorySkipRules.isOnNetworkVolume("/Users/me/code", mounts: []))
    }

    func testTheRealMountTableReadsTheRootVolumeAsLocal() throws {
        let mounts = DirectoryMountTable.current()
        XCTAssertEqual(try XCTUnwrap(mounts.first { $0.path == "/" }).isLocal, true)
    }

    func testRecordingAppliesMountRulesOnlyToThisMac() async {
        let history = makeHistory(mounts: [DirectoryMount(path: "/", isLocal: true), DirectoryMount(path: "/data", isLocal: false)])
        let skipped = await history.record(path: "/data/repo", on: .local)
        XCTAssertNil(skipped)
        let remote = await history.record(path: "/data/repo", on: .host(host))
        XCTAssertEqual(remote?.map(\.machine), [host.uuidString], "The same path on a host says nothing about this Mac's mounts")
        let rules = await history.record(path: "/tmp/x", on: .host(host))
        XCTAssertNil(rules, "Path rules apply on every machine")
    }

    // MARK: Entries (FR-DJ01–FR-DJ03)

    func testVisitsCountPerMachineAndPath() async {
        let history = makeHistory()
        await history.record(path: "/code/a", on: .local)
        clock.now.addTimeInterval(10)
        await history.record(path: "/code/a/", on: .local)
        await history.record(path: "/code/a", on: .host(host))
        let entries = await history.all()
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.first { $0.machine == "local" }?.visits, 2, "A trailing slash is the same directory")
        XCTAssertEqual(entries.first { $0.machine == "local" }?.lastVisit, clock.now)
        XCTAssertEqual(entries.first { $0.machine == host.uuidString }?.visits, 1)
    }

    func testAHundredAndFirstDirectoryEvictsTheLeastRecentlyVisited() async {
        let history = makeHistory()
        await history.record(path: "/code/frequent", on: .local)
        for _ in 0..<50 { await history.record(path: "/code/frequent", on: .local) }
        clock.now.addTimeInterval(10)
        for index in 0..<99 {
            clock.now.addTimeInterval(1)
            await history.record(path: "/code/\(index)", on: .local)
        }
        var entries = await history.all()
        XCTAssertEqual(entries.count, 100)
        clock.now.addTimeInterval(1)
        await history.record(path: "/code/new", on: .local)
        entries = await history.all()
        XCTAssertEqual(entries.count, 100)
        XCTAssertFalse(entries.contains { $0.path == "/code/frequent" }, "Eviction looks at the last visit, not at how often")
        XCTAssertTrue(entries.contains { $0.path == "/code/new" })
    }

    func testRankingWeighsVisitsByRecencyAndBreaksTiesByTheLastVisit() {
        let now = clock.now
        func entry(_ path: String, visits: Int, ago: TimeInterval) -> DirectoryHistoryEntry {
            DirectoryHistoryEntry(path: path, machine: "local", visits: visits, lastVisit: now.addingTimeInterval(-ago))
        }
        XCTAssertEqual(entry("/a", visits: 3, ago: 59 * 60).frecency(now: now), 12)
        XCTAssertEqual(entry("/a", visits: 3, ago: 3_600).frecency(now: now), 6)
        XCTAssertEqual(entry("/a", visits: 3, ago: 86_400).frecency(now: now), 1.5)
        XCTAssertEqual(entry("/a", visits: 3, ago: 604_800).frecency(now: now), 0.75)
        let ranked = DirectoryHistoryEntry.ranked(
            [entry("/old-but-often", visits: 40, ago: 700_000), entry("/recent", visits: 3, ago: 60), entry("/week", visits: 2, ago: 200_000), entry("/hour", visits: 1, ago: 60), entry("/day", visits: 2, ago: 7200)],
            now: now)
        // Scores 12, 10, 4, 4 and 1: /hour and /day tie, and /hour was visited last.
        XCTAssertEqual(ranked.map(\.path), ["/recent", "/old-but-often", "/hour", "/day", "/week"])
    }

    func testLastVisitDescription() {
        let now = clock.now
        func text(_ ago: TimeInterval) -> String { DirectoryHistoryEntry(path: "/a", machine: "local", visits: 1, lastVisit: now.addingTimeInterval(-ago)).lastVisitDescription(now: now) }
        XCTAssertEqual(text(5), "just now")
        XCTAssertEqual(text(300), "5m ago")
        XCTAssertEqual(text(7_200), "2h ago")
        XCTAssertEqual(text(172_800), "2d ago")
        XCTAssertEqual(text(1_814_400), "3w ago")
    }

    func testReadingDropsWhatIsOnANonLocalMountButKeepsAnUnpluggedDisk() async throws {
        let entries = [
            entryJSON("/data/repo"), entryJSON("/data/repo", machine: host.uuidString), entryJSON("/Volumes/Unplugged/repo"), entryJSON("/Volumes/Share/repo"), entryJSON("/code/a")
        ]
        try document(entries.joined(separator: ",")).write(to: file)
        let table = [DirectoryMount(path: "/", isLocal: true), DirectoryMount(path: "/data", isLocal: false), DirectoryMount(path: "/Volumes/Share", isLocal: false)]
        let read = await makeHistory(mounts: table).all()
        XCTAssertEqual(
            Set(read.map { $0.machine + ":" + $0.path }), ["\(host.uuidString):/data/repo", "local:/Volumes/Unplugged/repo", "local:/code/a"],
            "A host's path says nothing about this Mac's mounts, and a disk that isn't plugged in isn't a share")
    }

    func testRemoveAndRetain() async {
        let history = makeHistory()
        let other = UUID()
        await history.record(path: "/code/a", on: .local)
        await history.record(path: "/code/a", on: .host(host))
        await history.record(path: "/code/b", on: .host(other))
        let removed = await history.remove(path: "/code/a", on: .local)
        XCTAssertEqual(removed.count, 2, "The same path on a host stays")
        let kept = await history.retain(hosts: [host])
        XCTAssertEqual(kept.map(\.machine), [host.uuidString])
    }

    // MARK: Storage (FR-DJ08, FR-DJ09)

    func testFlushWritesAnOwnerOnlyFileWithOnlyTheRecordedFields() async throws {
        let history = makeHistory()
        await history.record(path: "/code/a", on: .local)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "Batched: nothing yet")
        await history.flush()
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(json["version"] as? Int, 1)
        let entry = try XCTUnwrap((json["entries"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(entry.keys), ["path", "machine", "visits", "lastVisit"])

        let reread = await makeHistory().all()
        XCTAssertEqual(reread.map(\.path), ["/code/a"])
        XCTAssertEqual(reread.first?.machine, "local")
    }

    func testManyQuickVisitsWriteOnce() async throws {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        let (released, release) = AsyncStream.makeStream(of: Void.self)
        final class Box: @unchecked Sendable {
            var waits = 0
            let lock = NSLock()
            func add() { lock.withLock { waits += 1 } }
        }
        let box = Box()
        let history = makeHistory(sleep: { _ in
            box.add()
            continuation.yield()
            for await _ in released { break }
        })
        for index in 0..<20 { await history.record(path: "/code/\(index)", on: .local) }
        for await _ in stream { break }
        XCTAssertEqual(box.waits, 1, "One save is pending however many visits arrive")
        release.yield()
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: file.path) { try await Task.sleep(for: .milliseconds(10)) }
        let stored = await makeHistory().all()
        XCTAssertEqual(stored.count, 20)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path), "Written once, so there's no earlier version to back up")
    }

    func testSavingKeepsThePreviousVersionAsABackup() async throws {
        let history = makeHistory()
        await history.record(path: "/code/a", on: .local)
        await history.flush()
        await history.record(path: "/code/b", on: .local)
        await history.flush()
        let previous = try String(contentsOf: backup, encoding: .utf8)
        XCTAssertTrue(previous.contains("/code/a"))
        XCTAssertFalse(previous.contains("/code/b"))
    }

    func testAnUnparsableFileIsSetAsideAndReadsAsEmpty() async throws {
        try Data("not json".utf8).write(to: file)
        let history = makeHistory()
        let entries = await history.all()
        XCTAssertTrue(entries.isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: scratch.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("directory-history.unreadable.") }, "\(names)")
        await history.record(path: "/code/a", on: .local)
        await history.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "The set-aside file doesn't block new history")
    }

    func testANewerFileIsNeverWrittenOverAndChangesLastUntilQuit() async throws {
        let newer = document(entryJSON("/code/future"), version: 2)
        try newer.write(to: file)
        let history = makeHistory()
        await history.record(path: "/code/a", on: .local)
        let entries = await history.all()
        XCTAssertEqual(entries.map(\.path), ["/code/a"])
        await history.flush()
        XCTAssertEqual(try Data(contentsOf: file), newer)
        let cleared = await history.clear()
        XCTAssertFalse(cleared, "Reported, because the file stays")
        XCTAssertEqual(try Data(contentsOf: file), newer)
    }

    func testClearWithANewerFileStillDeletesTheCopiesAndReportsTheFileThatStays() async throws {
        let newer = document(entryJSON("/code/future"), version: 2)
        try newer.write(to: file)
        try Data("old".utf8).write(to: backup)
        let aside = scratch.appendingPathComponent("directory-history.unreadable.\(UUID().uuidString).json")
        try Data("old".utf8).write(to: aside)
        let cleared = await makeHistory().clear()
        XCTAssertFalse(cleared)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratch.path), [DirectoryHistory.fileName])
        XCTAssertEqual(try Data(contentsOf: file), newer)
    }

    func testClearReportsAFolderItCouldNotList() async throws {
        let folder = scratch.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let history = makeHistory(directory: folder)
        await history.record(path: "/code/a", on: .local)
        await history.flush()
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        let cleared = await history.clear()
        XCTAssertFalse(cleared, "The file is still there, so success would be a lie")
    }

    func testAFailedWriteIsTriedAgainAtQuitWithNothingNewToBatch() async throws {
        let folder = scratch.appendingPathComponent("readonly")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(DirectoryHistory.fileName)
        let history = makeHistory(directory: folder)
        _ = await history.all()
        await history.record(path: "/code/a", on: .local)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        await history.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        let kept = await history.all()
        XCTAssertEqual(kept.map(\.path), ["/code/a"], "A failed write keeps the list")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        await history.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    func testASymlinkedFileIsNeverFollowed() async throws {
        let target = scratch.appendingPathComponent("elsewhere.json")
        try Data("keep".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        let history = makeHistory()
        await history.record(path: "/code/a", on: .local)
        await history.flush()
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "keep")
    }

    func testTheFileIsValidatedWhenReadBecauseItsPathsCanBeTypedIntoAShell() async throws {
        let entries = [
            entryJSON("/code/good"), entryJSON("relative"), entryJSON("/tmp/x"), entryJSON("/code/esc\\u001b[31m"), entryJSON("/code/zero", visits: 0),
            entryJSON("/code/machine", machine: "not-a-machine"), entryJSON("/code/good"), entryJSON("/code/slash/"), entryJSON("/code/huge", visits: 2_000_000_000)
        ]
        try document(entries.joined(separator: ",")).write(to: file)
        let read = await makeHistory().all()
        XCTAssertEqual(Set(read.map(\.path)), ["/code/good", "/code/huge"])
        XCTAssertEqual(read.first { $0.path == "/code/huge" }?.visits, DirectoryHistory.maximumVisits)
    }

    func testAnOverfullFileIsCutToTheLimit() async throws {
        let entries = (0..<150).map { entryJSON("/code/\($0)") }
        try document(entries.joined(separator: ",")).write(to: file)
        let read = await makeHistory().all()
        XCTAssertEqual(read.count, DirectoryHistory.capacity)
    }

    func testClearDeletesEveryCopyAndCancelsThePendingSave() async throws {
        let history = makeHistory()
        await history.record(path: "/code/a", on: .local)
        await history.flush()
        await history.record(path: "/code/b", on: .local)
        await history.flush()
        let aside = scratch.appendingPathComponent("directory-history.unreadable.\(UUID().uuidString).json")
        try Data("old".utf8).write(to: aside)
        let unrelated = scratch.appendingPathComponent("remote-hosts.json")
        try Data("keep".utf8).write(to: unrelated)
        await history.record(path: "/code/c", on: .local)

        let cleared = await history.clear()
        XCTAssertTrue(cleared)
        let entries = await history.all()
        XCTAssertTrue(entries.isEmpty)
        await history.flush()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratch.path), ["remote-hosts.json"])
    }

    func testWithoutAStateDirectoryNothingIsWritten() async throws {
        let history = DirectoryHistory(stateDirectory: nil, sleep: { _ in })
        await history.record(path: "/code/a", on: .local)
        await history.flush()
        let entries = await history.all()
        XCTAssertEqual(entries.map(\.path), ["/code/a"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratch.path), [])
    }

    // MARK: The line typed into a shell (FR-DJ06)

    func testChangeDirectoryLineQuotesPerShellAndRefusesWhatCantBeTyped() {
        XCTAssertEqual(TaskCommand.changeDirectoryLine("/code/my app", kind: .zsh), "cd '/code/my app'")
        XCTAssertEqual(TaskCommand.changeDirectoryLine("/code/it's; rm -rf ~", kind: .bash), #"cd '/code/it'\''s; rm -rf ~'"#)
        XCTAssertEqual(TaskCommand.changeDirectoryLine(#"/code/it's\x"#, kind: .fish), #"cd '/code/it\'s\\x'"#)
        XCTAssertNil(TaskCommand.changeDirectoryLine("relative", kind: .zsh))
        XCTAssertNil(TaskCommand.changeDirectoryLine("/code/a\nrm -rf ~", kind: .zsh))
        XCTAssertNil(TaskCommand.changeDirectoryLine("/code/\u{1B}[31m", kind: .fish))
    }

    func testChangeDirectoryLineRunsInARealShell() throws {
        // `pwd -P` answers with the real path, and the temporary folder is reached through a link.
        let real = try XCTUnwrap(realpath(scratch.path, nil))
        defer { free(real) }
        let tricky = URL(fileURLWithPath: String(cString: real)).appendingPathComponent("it's a \"dir\" $HOME `x` \\y")
        try FileManager.default.createDirectory(at: tricky, withIntermediateDirectories: true)
        for (shell, kind) in [("/bin/zsh", ShellIntegrationKind.zsh), ("/bin/bash", .bash), ("/opt/homebrew/bin/fish", .fish), ("/usr/local/bin/fish", .fish)]
        where FileManager.default.isExecutableFile(atPath: shell) {
            let line = try XCTUnwrap(TaskCommand.changeDirectoryLine(tricky.path, kind: kind))
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = ["-c", line + " && pwd -P"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            process.waitUntilExit()
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .newlines)
            XCTAssertEqual(text, tricky.path, shell)
        }
    }

    // MARK: Palette and shortcut

    func testPaletteBoostSettlesSimilarMatchesButNotAClearlyBetterOne() {
        func row(_ path: String, boost: Int) -> CommandPaletteItem {
            CommandPaletteItem(target: .directory(machine: "local", path: path), kind: .directory, title: path, boost: boost)
        }
        let items = [row("/a/trellis", boost: 0), row("/b/trellis", boost: 10), row("/c/trellis", boost: 5)]
        let titles = CommandPaletteSearch.sections(items: items, query: "trellis", scope: .directories, recents: []).flatMap { $0.matches.map(\.item.title) }
        XCTAssertEqual(titles, ["/b/trellis", "/c/trellis", "/a/trellis"])
        let exact = CommandPaletteSearch.sections(items: [row("/x/t-r-e-l-l-i-s", boost: 10), row("/trellis", boost: 0)], query: "trellis", scope: .directories, recents: [])
        XCTAssertEqual(exact.first?.matches.first?.item.title, "/trellis")
    }

    func testDirectoryScopeListsOnlyDirectoriesInTheirOrderUnderTheirMachine() {
        let items = [
            CommandPaletteItem(target: .action(.newTab), kind: .action, title: "New Tab"),
            CommandPaletteItem(target: .directory(machine: "local", path: "/a"), kind: .directory, title: "/a", groupID: "local", groupTitle: "Local"),
            CommandPaletteItem(target: .directory(machine: "h", path: "/b"), kind: .directory, title: "/b", groupID: "h", groupTitle: "build-box"),
            CommandPaletteItem(target: .directory(machine: "local", path: "/c"), kind: .directory, title: "/c", groupID: "local", groupTitle: "Local")
        ]
        let sections = CommandPaletteSearch.sections(items: items, query: "", scope: .directories, recents: [])
        XCTAssertEqual(sections.map(\.title), ["Local", "build-box"])
        XCTAssertEqual(sections[0].matches.map(\.item.title), ["/a", "/c"])
    }

    func testTheSamePathOnTwoMachinesIsTwoRows() {
        XCTAssertNotEqual(CommandPaletteTarget.directory(machine: "local", path: "/a").id, CommandPaletteTarget.directory(machine: "h", path: "/a").id)
    }

    func testJumpShortcutDefaultsToCommandJAndYieldsToAnEarlierChoice() throws {
        XCTAssertEqual(ShortcutMap.defaults[.jumpToDirectory], KeyChord("j"))
        XCTAssertTrue(ShortcutMap.defaults.issues().isEmpty)
        var settings = KeyboardSettings()
        settings.shortcuts = settings.shortcuts.assigning(nil, to: .jumpToDirectory).assigning(KeyChord("j"), to: .clearPane)
        // As saved before this action existed: no entry for it at all.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        var overrides = try XCTUnwrap(object["overrides"] as? [String: Any])
        overrides.removeValue(forKey: ShortcutAction.jumpToDirectory.rawValue)
        object["overrides"] = overrides
        let decoded = try JSONDecoder().decode(KeyboardSettings.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.shortcuts[.clearPane], KeyChord("j"))
        XCTAssertNil(decoded.shortcuts[.jumpToDirectory])
        XCTAssertTrue(decoded.shortcuts.issues().isEmpty)
    }
}
