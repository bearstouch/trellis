import XCTest
import TrellisControl
import TrellisCore

final class ProjectFileJSONTests: XCTestCase {
    private let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func document(tabs: [Any], extra: [String: Any] = [:]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["version": 1, "name": "Project", "tabs": tabs].merging(extra) { $1 })
    }

    private func pane(_ fields: [String: Any] = [:]) -> [String: Any] { ["type": "pane"].merging(fields) { $1 } }

    private func issues(_ data: Data) -> [String] {
        guard case .failure(let error) = ProjectFileJSON.parse(data) else { return [] }
        return error.issues.map(\.message)
    }

    func testRepositoryFileParsesAndReencodesToTheSameBytes() throws {
        let data = try Data(contentsOf: repository.appendingPathComponent(".trellis/project.json"))
        let file = try ProjectFileJSON.parse(data).get()
        XCTAssertEqual(file.name, "Trellis")
        XCTAssertEqual(file.tabs.map(\.title), ["Develop", "Build", "Docs"])
        XCTAssertEqual(file.tabs.map(\.color), [.green, .blue, .purple])
        XCTAssertEqual(file.entries.map(\.key), ["t1-1", "t1-2", "t2-1", "t2-2", "t3-0"])
        XCTAssertEqual(file.entries.compactMap(\.pane.command), ["git status --short", "swift build", "swift format lint --strict -r Sources Tests"])
        XCTAssertEqual(String(decoding: ProjectFileJSON.encode(file), as: UTF8.self), String(decoding: data, as: UTF8.self))
    }

    func testDocumentedExampleParses() throws {
        let page = try String(contentsOf: repository.appendingPathComponent("docs/features/project-files.md"), encoding: .utf8)
        let start = try XCTUnwrap(page.range(of: "```json\n")), end = try XCTUnwrap(page.range(of: "\n```", range: start.upperBound..<page.endIndex))
        let file = try ProjectFileJSON.parse(Data(page[start.upperBound..<end.lowerBound].utf8)).get()
        XCTAssertEqual(file.tabs.count, 2)
        XCTAssertEqual(file.entries.last?.pane.directory, "docs")
    }

    func testEncodingRoundTripsAndOmitsDefaults() throws {
        let file = ProjectFile(
            name: "Café “quoted”",
            tabs: [
                .init(title: "A", color: .red, root: .split(key: "main", axis: .y, ratio: 0.25, children: [.pane(.init(title: "x", directory: "src/app", command: "make \"all\"")), .pane(.init())])),
                .init(key: "second", title: "B", root: .pane(.init(key: "solo")))
            ])
        let data = ProjectFileJSON.encode(file)
        XCTAssertEqual(try ProjectFileJSON.parse(data).get(), file)
        XCTAssertEqual(ProjectFileJSON.encode(try ProjectFileJSON.parse(data).get()), data, "Saving twice writes identical bytes")
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.hasSuffix("}\n"))
        XCTAssertTrue(text.hasPrefix("{\n  \"version\": 1,\n  \"name\": "), text)
        XCTAssertFalse(text.contains("\"key\": \"t"), "Derived keys are never written")
    }

    func testDefaultsAndSchemaField() throws {
        let file = try ProjectFileJSON.parse(
            try document(
                tabs: [["title": "T", "root": ["type": "split", "axis": "x", "children": [pane(), pane()]]]], extra: ["$schema": "./project-file.schema.json"])
        ).get()
        guard case .split(_, _, let ratio, _) = file.tabs[0].root else { return XCTFail("split expected") }
        XCTAssertEqual(ratio, 0.5)
    }

    func testRejectsUnsafeOrMalformedContent() throws {
        let cases: [(String, Data)] = [
            ("unknown field", try document(tabs: [["title": "T", "root": pane(["shell": "zsh"])]])),
            ("unknown top-level field", try document(tabs: [["title": "T", "root": pane()]], extra: ["windows": []])),
            ("absolute directory", try document(tabs: [["title": "T", "root": pane(["directory": "/etc"])]])),
            ("parent directory", try document(tabs: [["title": "T", "root": pane(["directory": "src/../../secret"])]])),
            ("home directory", try document(tabs: [["title": "T", "root": pane(["directory": "~/x"])]])),
            ("expansion", try document(tabs: [["title": "T", "root": pane(["directory": "$HOME"])]])),
            ("multi-line command", try document(tabs: [["title": "T", "root": pane(["command": "ls\nrm -rf x"])]])),
            ("bidi override", try document(tabs: [["title": "T", "root": pane(["command": "echo \u{202E}safe"])]])),
            ("zero-width title", try document(tabs: [["title": "T\u{200B}", "root": pane()]])),
            ("line separator command", try document(tabs: [["title": "T", "root": pane(["command": "echo a\u{2028}rm -rf x"])]])),
            ("filler command", try document(tabs: [["title": "T", "root": pane(["command": "echo \u{3164}"])]])),
            ("paragraph separator title", try document(tabs: [["title": "T\u{2029}x", "root": pane()]])),
            ("blank command", try document(tabs: [["title": "T", "root": pane(["command": "  "])]])),
            ("bad color", try document(tabs: [["title": "T", "color": "pink", "root": pane()]])),
            ("host launch", try document(tabs: [["title": "T", "root": pane(["launch": ["kind": "host"]])]])),
            ("reserved key", try document(tabs: [["key": ProjectFile.windowKey, "title": "T", "root": pane()]])),
            ("no tabs", try document(tabs: [])),
            ("one child", try document(tabs: [["title": "T", "root": ["type": "split", "axis": "x", "children": [pane()]]]])),
            ("version", try JSONSerialization.data(withJSONObject: ["version": 2, "name": "P", "tabs": [["title": "T", "root": pane()]]])),
            ("not JSON", Data("{".utf8)),
            ("oversized", Data(repeating: 0x20, count: ProjectFile.maximumBytes + 1))
        ]
        for (name, data) in cases { XCTAssertFalse(issues(data).isEmpty, name) }
        XCTAssertEqual(issues(try document(tabs: [["title": "T", "root": pane(["command": "a\u{202E}b"])]])).count, 1)
    }

    func testDerivedKeysAreStableAndCollisionsAreCaught() throws {
        let data = try document(tabs: [["title": "A", "root": pane()], ["title": "B", "root": ["type": "split", "axis": "x", "children": [pane(), pane()]]]])
        let first = try ProjectFileJSON.parse(data).get(), second = try ProjectFileJSON.parse(data).get()
        XCTAssertEqual(first.entries.map(\.key), ["t1-0", "t2-1", "t2-2"])
        XCTAssertEqual(first.resolve(projectRoot: "/p"), second.resolve(projectRoot: "/p"))
        // A declared key may collide with a derived one; the planner reports it instead of merging panes.
        let colliding = try ProjectFileJSON.parse(try document(tabs: [["title": "A", "root": pane(["key": "t2-0"])], ["title": "B", "root": pane()]])).get()
        let plan = LayoutPlanner.plan(
            colliding.resolve(projectRoot: "/p").layout, bindings: [:], snapshot: WorkspaceSnapshot(), home: "/h", hostExists: { _ in false },
            directoryExists: { _ in true })
        XCTAssertTrue(plan.errors.contains { $0.message.contains("unique") })
    }
}
