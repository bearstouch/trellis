import XCTest
@testable import TrellisCore

final class ToolDockTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ToolDockTests-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        _ = chmod(folder.path, 0o700)
        try? FileManager.default.removeItem(at: folder)
    }

    @discardableResult private func write(_ relative: String, _ data: Data, mode: mode_t = 0o644) throws -> String {
        let url = folder.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        _ = chmod(url.path, mode)
        return url.path
    }
    @discardableResult private func write(_ relative: String, _ text: String, mode: mode_t = 0o644) throws -> String {
        try write(relative, Data(text.utf8), mode: mode)
    }
    private func open(_ path: String) throws -> EditorFile {
        switch EditorFile.open(path) {
        case .success(let file): return file
        case .failure(let error): throw error
        }
    }
    private func bytes(_ path: String) throws -> [UInt8] { try Array(Data(contentsOf: URL(fileURLWithPath: path))) }

    // MARK: Settings (FR-TD02, FR-TD09)

    func testSettingsSavedBeforeTheToolDockUseTheDefaultsAndUnknownChoicesFallBack() throws {
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(AppearanceSettings())) as? [String: Any])
        legacy["toolDockSide"] = nil; legacy["fileLinkTarget"] = nil; legacy["chromeMode"] = "light"
        let old = try JSONDecoder().decode(AppearanceSettings.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(old.toolDockSide, .right)
        XCTAssertEqual(old.fileLinkTarget, .toolDock)
        XCTAssertEqual(old.chromeMode, .light, "The other settings survive")
        legacy["toolDockSide"] = "top"; legacy["fileLinkTarget"] = "vim"
        let unknown = try JSONDecoder().decode(AppearanceSettings.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(unknown.toolDockSide, .right)
        XCTAssertEqual(unknown.fileLinkTarget, .toolDock)
        XCTAssertEqual(unknown.chromeMode, .light)
    }
    func testDockSettingsRoundTripAndDontReapplyTheTerminalAppearance() throws {
        var settings = AppearanceSettings()
        settings.toolDockSide = .left; settings.fileLinkTarget = .defaultApp
        let decoded = try JSONDecoder().decode(AppearanceSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded, settings)
        XCTAssertFalse(settings.terminalRenderingDiffers(from: AppearanceSettings()))
        XCTAssertEqual(ToolDockSide.right.other, .left)
    }

    // MARK: Root (FR-TD06)

    func testRootIsTheWorkTreeThenTheLibraryFolderThenTheDirectoryButNeverHomeOrSlash() throws {
        let home = folder.appendingPathComponent("home").path
        let repo = home + "/code/trellis"
        try FileManager.default.createDirectory(atPath: repo + "/.git", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: repo + "/Sources/UI", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: home + "/notes/2026", withIntermediateDirectories: true)
        let exists = { FileManager.default.fileExists(atPath: $0) }
        XCTAssertEqual(ToolDockRoot.resolve(directory: repo + "/Sources/UI", home: home, exists: exists), .project(repo))
        XCTAssertEqual(
            ToolDockRoot.resolve(directory: home + "/notes/2026", home: home, libraryFolders: [home + "/notes", home], exists: exists), .project(home + "/notes"),
            "A library folder counts, but never home")
        XCTAssertEqual(ToolDockRoot.resolve(directory: home + "/notes/2026", home: home, exists: exists), .project(home + "/notes/2026"))
        XCTAssertEqual(ToolDockRoot.resolve(directory: home, home: home, libraryFolders: [home], exists: exists), .notAProject)
        XCTAssertEqual(ToolDockRoot.resolve(directory: "/", home: home, exists: exists), .notAProject)
    }

    // MARK: Tree (FR-TD08)

    func testTreeListsFoldersFirstInFinderOrderShowsHiddenFilesAndHidesGit() throws {
        for name in ["b.txt", "a10.txt", "a2.txt", ".env"] { try write(name, "x") }
        for name in ["Sources", ".git/objects", "docs"] { try FileManager.default.createDirectory(at: folder.appendingPathComponent(name), withIntermediateDirectories: true) }
        let names = FileTreeReader.list(folder.path, root: folder.path).entries.map(\.name)
        XCTAssertEqual(names, ["docs", "Sources", ".env", "a2.txt", "a10.txt", "b.txt"])
    }
    func testLinksAreMarkedNeverExpandedAndOpenOnlyInsideTheRoot() throws {
        let project = folder.appendingPathComponent("project").path
        try write("project/real.swift", "let a = 1")
        try write("outside/secret.txt", "s")
        try FileManager.default.createDirectory(atPath: project + "/dir", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: project + "/inside-link", withDestinationPath: project + "/real.swift")
        try FileManager.default.createSymbolicLink(atPath: project + "/outside-link", withDestinationPath: folder.path + "/outside/secret.txt")
        try FileManager.default.createSymbolicLink(atPath: project + "/dir-link", withDestinationPath: project + "/dir")
        let entries = Dictionary(uniqueKeysWithValues: FileTreeReader.list(project, root: project).entries.map { ($0.name, $0) })
        XCTAssertEqual(entries["inside-link"]?.kind, .link(targetIsDirectory: false, targetInsideRoot: true))
        XCTAssertTrue(try XCTUnwrap(entries["inside-link"]).opensAsFile)
        XCTAssertFalse(try XCTUnwrap(entries["outside-link"]).opensAsFile)
        XCTAssertEqual(entries["dir-link"]?.kind, .link(targetIsDirectory: true, targetInsideRoot: true))
        XCTAssertFalse(try XCTUnwrap(entries["dir-link"]).isDirectory, "A link to a folder isn't expanded")
        XCTAssertEqual(FileTreeReader.list(project, root: project).entries.prefix(2).map(\.name), ["dir", "dir-link"], "Folder links sort with folders")
    }
    func testLargeFoldersListTheFirstEntriesAndSaySo() throws {
        let big = folder.appendingPathComponent("big")
        try FileManager.default.createDirectory(at: big, withIntermediateDirectories: true)
        for i in 0...FileTreeReader.maximumEntries { FileManager.default.createFile(atPath: big.appendingPathComponent("f\(i)").path, contents: nil) }
        let listing = FileTreeReader.list(big.path, root: folder.path)
        XCTAssertTrue(listing.truncated)
        XCTAssertEqual(listing.entries.count, FileTreeReader.maximumEntries)
    }
    func testFilterMatchesEveryFragmentOfTheRelativePathIgnoringCase() throws {
        try write("Sources/TrellisUI/PaneTreeView.swift", "")
        try write("Sources/TrellisCore/Workspace.swift", "")
        try write("docs/features/tool-dock.md", "")
        try write(".git/HEAD", "ref")
        XCTAssertEqual(FileTreeReader.filter(root: folder.path, query: "ui pane").entries.map(\.name), ["PaneTreeView.swift"])
        XCTAssertEqual(FileTreeReader.filter(root: folder.path, query: "SWIFT").entries.map(\.name), ["Workspace.swift", "PaneTreeView.swift"])
        XCTAssertTrue(FileTreeReader.filter(root: folder.path, query: "HEAD").entries.isEmpty, ".git isn't searched")
        XCTAssertTrue(FileTreeReader.filter(root: folder.path, query: "  ").entries.isEmpty)
    }

    // MARK: Opening (FR-TD10)

    func testOpenRefusesWhatTheEditorCantHandleWithAReason() throws {
        let cases: [(String, EditorFileError)] = [
            (try write("big.txt", Data(repeating: 0x61, count: EditorFile.maximumBytes + 1)), .tooLarge),
            (try write("image.png", Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01])), .binary),
            (try write("latin1.txt", Data([0x63, 0x61, 0x66, 0xE9])), .notUTF8),
            (folder.appendingPathComponent("missing.txt").path, .notFound),
            (folder.path, .notRegularFile),
            ("/net/host/file.txt", .networkPath),
            ("/Network/Servers/file.txt", .networkPath)
        ]
        for (path, expected) in cases {
            guard case .failure(let error) = EditorFile.open(path) else { XCTFail("\(path) opened"); continue }
            XCTAssertEqual(error, expected, path)
            XCTAssertFalse(error.message.isEmpty)
        }
        XCTAssertEqual(EditorFileError.tooLarge.code, "FILE_TOO_LARGE")
        XCTAssertEqual(EditorFileError.changedOnDisk.code, "CHANGED_ON_DISK")
        let exact = try write("exact.txt", Data(repeating: 0x61, count: EditorFile.maximumBytes))
        XCTAssertEqual(try open(exact).text.utf8.count, EditorFile.maximumBytes, "2 MiB itself opens")
    }
    func testAFileYouCantWriteOpensReadOnlyAndRefusesToSave() throws {
        let path = try write("locked.txt", "keep", mode: 0o444)
        let file = try open(path)
        XCTAssertFalse(file.isWritable)
        XCTAssertEqual(file.save("changed"), .failure(.readOnly))
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "keep")
    }
    func testLanguagesComeFromTheExtension() {
        XCTAssertEqual(EditorLanguage.detect(fileName: "PaneTreeView.swift"), .swift)
        XCTAssertEqual(EditorLanguage.detect(fileName: "launch.JSON"), .json)
        XCTAssertEqual(EditorLanguage.detect(fileName: "README.md"), .markdown)
        XCTAssertEqual(EditorLanguage.detect(fileName: "build.zsh"), .shell)
        XCTAssertEqual(EditorLanguage.detect(fileName: "App.tsx"), .typescript)
        XCTAssertEqual(EditorLanguage.detect(fileName: "ci.yml"), .yaml)
        XCTAssertNil(EditorLanguage.detect(fileName: "Makefile"), "Plain text")
    }

    // MARK: Saving (FR-TD12)

    func testSaveKeepsTheByteOrderMarkLineEndingsAndMissingFinalNewline() throws {
        let path = try write("windows.txt", Data([0xEF, 0xBB, 0xBF] + Array("one\r\ntwo".utf8)))
        let file = try open(path)
        XCTAssertTrue(file.hasByteOrderMark)
        XCTAssertEqual(file.lineEnding, .crlf)
        XCTAssertEqual(file.text, "one\r\ntwo")
        _ = try file.save(file.text + "\nthree").get()
        XCTAssertEqual(try bytes(path), [0xEF, 0xBB, 0xBF] + Array("one\r\ntwo\r\nthree".utf8), "A typed line gets CRLF too, and no final newline appears")
        let unix = try write("unix.txt", "a\nb\n")
        let plain = try open(unix)
        XCTAssertEqual(plain.lineEnding, .lf)
        _ = try plain.save("a\nb\nc\n").get()
        XCTAssertEqual(try String(contentsOfFile: unix, encoding: .utf8), "a\nb\nc\n")
    }
    func testSaveKeepsThePermissionBitsAndReturnsTheNewVersion() throws {
        let path = try write("script.sh", "echo 1\n", mode: 0o750)
        let saved = try open(path).save("echo 2\n").get()
        var info = stat()
        XCTAssertEqual(stat(path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o7777, 0o750)
        XCTAssertEqual(saved.text, "echo 2\n")
        XCTAssertEqual(saved.fingerprint, saved.currentFingerprint())
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.contains(".trellis-") }
        XCTAssertEqual(leftovers, [], "No temporary file is left behind")
    }
    func testSaveFollowsASymbolicLinkAndKeepsTheLink() throws {
        let target = try write("real.swift", "let a = 1\n")
        let link = folder.appendingPathComponent("link.swift").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        _ = try open(link).save("let a = 2\n").get()
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link), target)
        XCTAssertEqual(try String(contentsOfFile: target, encoding: .utf8), "let a = 2\n")
    }
    func testAFailedSaveLeavesTheFileUntouched() throws {
        let path = try write("ro-folder/file.txt", "original")
        let file = try open(path)
        _ = chmod(folder.appendingPathComponent("ro-folder").path, 0o500)
        defer { _ = chmod(folder.appendingPathComponent("ro-folder").path, 0o700) }
        guard case .failure(let error) = file.save("new") else { return XCTFail("Saved into a read-only folder") }
        XCTAssertEqual(error, .permissionDenied)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "original")
    }

    // MARK: Changes on disk (FR-TD13)

    func testSavingOverAChangeMadeElsewhereNeedsAnExplicitOverwrite() throws {
        let path = try write("shared.swift", "let v = 1\n")
        let file = try open(path)
        try write("shared.swift", "let v = 99 // agent\n")
        XCTAssertNotEqual(file.currentFingerprint(), file.fingerprint)
        XCTAssertEqual(file.save("let v = 2\n"), .failure(.changedOnDisk))
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "let v = 99 // agent\n", "The other change is kept")
        _ = try file.save("let v = 2\n", overwrite: true).get()
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "let v = 2\n")
    }
    func testADeletedFileIsRecreatedBySave() throws {
        let path = try write("gone.txt", "text", mode: 0o600)
        let file = try open(path)
        try FileManager.default.removeItem(atPath: path)
        XCTAssertNil(file.currentFingerprint())
        _ = try file.save("back").get()
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "back")
        var info = stat()
        XCTAssertEqual(stat(path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o7777, 0o600)
    }
}
