import XCTest
import TrellisControl
import TrellisCore

/// `.trellis/launch.json` parsing and encoding (FR-TK01, FR-TK09).
final class LaunchFileJSONTests: XCTestCase {
    private let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func document(tasks: [Any], extra: [String: Any] = [:]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["version": 1, "tasks": tasks].merging(extra) { $1 })
    }

    private func issues(_ data: Data) -> [String] {
        guard case .failure(let error) = LaunchFileJSON.parse(data) else { return [] }
        return error.issues.map { ($0.key.map { "\($0): " } ?? "") + $0.message }
    }

    func testRepositoryFileParsesAndReencodesToTheSameBytes() throws {
        let data = try Data(contentsOf: repository.appendingPathComponent(".trellis/launch.json"))
        let file = try LaunchFileJSON.parse(data).get()
        XCTAssertEqual(file.tasks.map(\.name), ["build", "test", "lint", "format", "run fixture"])
        XCTAssertEqual(file.task(named: "test")?.group, .test)
        XCTAssertEqual(String(decoding: LaunchFileJSON.encode(file), as: UTF8.self), String(decoding: data, as: UTF8.self))
    }

    func testWorkspaceFileBytesAreUnchangedBySharedEncoder() throws {
        let data = try Data(contentsOf: repository.appendingPathComponent(".trellis/workspace.json"))
        XCTAssertEqual(WorkspaceFileJSON.encode(try WorkspaceFileJSON.parse(data).get()), data)
    }

    func testDocumentedExampleParses() throws {
        let page = try String(contentsOf: repository.appendingPathComponent("docs/features/tasks.md"), encoding: .utf8)
        let start = try XCTUnwrap(page.range(of: "```json\n")), end = try XCTUnwrap(page.range(of: "\n```", range: start.upperBound..<page.endIndex))
        let file = try LaunchFileJSON.parse(Data(page[start.upperBound..<end.lowerBound].utf8)).get()
        XCTAssertEqual(file.env, ["NODE_ENV": "development"])
        XCTAssertEqual(file.task(named: "test UI")?.env, ["TRELLIS_TEST_VERBOSE": "1"])
        XCTAssertEqual(LaunchFileJSON.encode(file), Data((page[start.upperBound..<end.lowerBound] + "\n").utf8), "The example is written in encoder order")
    }

    func testEncodingOrdersFieldsAndVariables() throws {
        let file = LaunchFile(
            env: ["Z": "1", "A": "two words"],
            tasks: [LaunchTask(name: "t", command: "make t", cwd: "src", group: .build, env: ["B": "", "A": "x"]), LaunchTask(name: "u", command: "ls")])
        let text = String(decoding: LaunchFileJSON.encode(file), as: UTF8.self)
        XCTAssertEqual(
            text,
            """
            {
              "version": 1,
              "env": {
                "A": "two words",
                "Z": "1"
              },
              "tasks": [
                {
                  "name": "t",
                  "command": "make t",
                  "cwd": "src",
                  "group": "build",
                  "env": {
                    "A": "x",
                    "B": ""
                  }
                },
                {
                  "name": "u",
                  "command": "ls"
                }
              ]
            }

            """)
        XCTAssertEqual(try LaunchFileJSON.parse(Data(text.utf8)).get(), file)
        XCTAssertEqual(String(decoding: LaunchFileJSON.encode(LaunchFile()), as: UTF8.self), "{\n  \"version\": 1,\n  \"tasks\": []\n}\n")
    }

    func testRejectsUnsafeOrMalformedContent() throws {
        func rejects(_ data: Data, _ fragment: String, file: StaticString = #filePath, line: UInt = #line) {
            let found = issues(data)
            XCTAssertTrue(found.contains { $0.contains(fragment) }, "\(fragment) not in \(found)", file: file, line: line)
        }
        let task: [String: Any] = ["name": "t", "command": "make"]
        rejects(try document(tasks: [task], extra: ["extra": 1]), "unsupported fields: extra")
        rejects(try document(tasks: [["label": "t", "command": "make"]]), "unsupported fields: label")
        rejects(try document(tasks: [["command": "make"]]), "missing: name")
        rejects(try document(tasks: [task, task]), "t: Task names must be unique.")
        rejects(try document(tasks: [["name": "t", "command": "make\nrm -rf ~"]]), "single line")
        rejects(try document(tasks: [["name": "t", "command": "make \u{202E}x"]]), "single line")
        rejects(try document(tasks: [["name": "t", "command": "make", "cwd": "../up"]]), "cwd must be relative")
        rejects(try document(tasks: [["name": "t", "command": "make", "cwd": "/etc"]]), "cwd must be relative")
        rejects(try document(tasks: [["name": "t", "command": "make", "group": "deploy"]]), "group must be one of build, test, run")
        rejects(try document(tasks: [["name": "t", "command": "make", "env": ["1X": "a"]]]), "variable name “1X”")
        rejects(try document(tasks: [["name": "t", "command": "make", "env": ["A-B": "a"]]]), "variable name “A-B”")
        rejects(try document(tasks: [["name": "t", "command": "make", "env": ["A": 1]]]), "env value A must be a string")
        rejects(try document(tasks: [task], extra: ["env": ["A": "x\ny"]]), "value of A")
        rejects(try document(tasks: [task], extra: ["env": "A=1"]), "env must be an object")
        rejects(try document(tasks: [["name": " ", "command": "make"]]), "task name needs")
        rejects(try document(tasks: Array(repeating: task, count: 101)), "at most 100 tasks")
        let many = Dictionary(uniqueKeysWithValues: (0..<51).map { ("V\($0)", "x") })
        rejects(try document(tasks: [task], extra: ["env": many]), "at most 50 variables")
        rejects(try JSONSerialization.data(withJSONObject: ["version": 2, "tasks": []]), "version 1")
        rejects(Data("{".utf8), "not valid JSON")
        rejects(Data(repeating: 32, count: LaunchFile.maximumBytes + 1), "64 KB")
    }

    func testSchemaFieldAndEmptyEnvironmentValues() throws {
        let file = try LaunchFileJSON.parse(try document(tasks: [["name": "t", "command": "make", "env": ["EMPTY": ""]]], extra: ["$schema": "x"])).get()
        XCTAssertEqual(file.task(named: "t")?.env, ["EMPTY": ""])
    }

    func testSchemaSurvivesAddingATaskAndHiddenValuesAreRejected() throws {
        let text = "{\n  \"$schema\": \"https://example.com/launch.schema.json\",\n  \"version\": 1,\n  \"tasks\": []\n}\n"
        let file = try LaunchFileJSON.parse(Data(text.utf8)).get()
        XCTAssertEqual(LaunchFileJSON.encode(file), Data(text.utf8), "Re-encodes to identical bytes, $schema first")
        let added = LaunchFileJSON.encode(file.adding(LaunchTask(name: "b", command: "make")).file)
        XCTAssertEqual(try LaunchFileJSON.parse(added).get().schema, "https://example.com/launch.schema.json", "Adding a task keeps $schema")
        XCTAssertFalse(issues(try document(tasks: [["name": "t", "command": "make", "env": ["A": "x\u{3164}y"]]])).isEmpty, "Invisible filler in a value")
    }
}
