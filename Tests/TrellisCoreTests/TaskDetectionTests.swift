import XCTest
import TrellisCore

/// Detected tasks (FR-TK03): fixed templates from root files only, with an in-memory folder.
final class TaskDetectionTests: XCTestCase {
    private func detect(_ files: [String: String], limits: inout [String: Int]) -> [DetectedTask] {
        TaskDetector.detect(
            read: { name, limit in
                limits[name] = limit
                return files[name].flatMap { $0.utf8.count <= limit ? Data($0.utf8) : nil }
            }, exists: { files[$0] != nil })
    }

    private func detect(_ files: [String: String]) -> [DetectedTask] {
        var limits: [String: Int] = [:]
        return detect(files, limits: &limits)
    }

    private func commands(_ files: [String: String]) -> [String] { detect(files).map(\.task.command) }

    func testEmptyFolderHasNoTasks() { XCTAssertEqual(detect([:]), []) }

    func testPackageScriptsUseTheProjectsPackageManager() {
        let manifest = #"{"scripts": {"test": "jest", "build": "tsc", "dev": "vite", "lint:fix": "eslint", "odd name": "x", "it's": "x", "a\\b": "x", "-x": "y", "n": 1}}"#
        XCTAssertEqual(
            commands(["package.json": manifest]),
            ["npm run build", "npm run dev", "npm run lint:fix", "npm run 'odd name'", "npm run test"])
        XCTAssertEqual(commands(["package.json": manifest, "pnpm-lock.yaml": ""]).first, "pnpm run build")
        XCTAssertEqual(commands(["package.json": manifest, "yarn.lock": ""]).first, "yarn run build")
        XCTAssertEqual(commands(["package.json": manifest, "bun.lockb": ""]).first, "bun run build")
        let declared = #"{"packageManager": "pnpm@9.1.0", "scripts": {"test": "x"}}"#
        XCTAssertEqual(commands(["package.json": declared, "yarn.lock": ""]), ["pnpm run test"])
        let tasks = detect(["package.json": manifest])
        XCTAssertEqual(tasks.first { $0.task.command == "npm run test" }?.task.group, .test)
        XCTAssertEqual(tasks.first { $0.task.command == "npm run build" }?.task.group, .build)
        XCTAssertEqual(tasks.first { $0.task.command == "npm run dev" }?.task.group, .run)
        XCTAssertEqual(tasks.first { $0.task.command == "npm run test" }?.task.name, "npm: test")
        XCTAssertEqual(tasks.first { $0.task.command == "npm run test" }?.detail, "script “test” in package.json")
        XCTAssertEqual(commands(["package.json": "not json"]), [])
        XCTAssertEqual(commands(["package.json": #"{"scripts": ["x"]}"#]), [])
    }

    func testMakeTargetsSkipSpecialPatternVariableAndAssignmentLines() {
        let makefile = """
            # comment
            .PHONY: all test
            CC := clang
            X ::= 1
            Y = a:b
            Z += c
            all: build
            \tcc -o app main.c
            build test: deps
            %.o: %.c
            $(OBJ): x
            install::
            deploy-prod :
              indented: no
            lib/a.o: a.c
            all: again
            """
        XCTAssertEqual(commands(["Makefile": makefile]), ["make all", "make build", "make install", "make deploy-prod", "make lib/a.o"])
        XCTAssertEqual(detect(["Makefile": makefile]).first?.task.group, .build)
        XCTAssertEqual(commands(["GNUmakefile": "first:\n", "Makefile": "second:\n"]), ["make first"], "GNU make's file order")
        let many = (0..<80).map { "t\($0):" }.joined(separator: "\n")
        XCTAssertEqual(commands(["Makefile": many]).count, 50)
    }

    func testCMakeSwiftPythonAndCargo() {
        XCTAssertEqual(commands(["CMakeLists.txt": "project(x)"]), ["cmake -S . -B build && cmake --build build"])
        XCTAssertEqual(commands(["CMakeLists.txt": "enable_testing()"]), ["cmake -S . -B build && cmake --build build", "ctest --test-dir build"])
        XCTAssertEqual(commands(["Package.swift": ""]), ["swift build", "swift test"])
        XCTAssertEqual(commands(["setup.py": ""]), ["python3 -m unittest"])
        XCTAssertEqual(commands(["pyproject.toml": "[tool.pytest.ini_options]"]), ["python3 -m pytest"])
        XCTAssertEqual(commands(["pyproject.toml": "", "conftest.py": ""]), ["python3 -m pytest"])
        XCTAssertEqual(commands(["pyproject.toml": "", "uv.lock": "", "pytest.ini": ""]), ["uv run pytest"])
        XCTAssertEqual(commands(["pyproject.toml": "", "uv.lock": ""]), ["uv run python -m unittest"])
        XCTAssertEqual(commands(["tox.ini": "[pytest]"]), ["python3 -m pytest", "tox"])
        XCTAssertEqual(commands(["Cargo.toml": "[package]"]), ["cargo build", "cargo test"])
        XCTAssertEqual(commands(["Cargo.toml": "[package]", "src/main.rs": ""]), ["cargo build", "cargo test", "cargo run"])
        XCTAssertEqual(commands(["Cargo.toml": "[[bin]]\nname = \"x\""]), ["cargo build", "cargo test", "cargo run"])
    }

    func testOrderIsStableAndFilesAreReadWithLimits() {
        let files = ["package.json": #"{"scripts": {"test": "x"}}"#, "Makefile": "all:", "Package.swift": "", "Cargo.toml": ""]
        var limits: [String: Int] = [:]
        let names = detect(files, limits: &limits).map(\.task.name)
        XCTAssertEqual(names, ["npm: test", "make: all", "swift: build", "swift: test", "cargo: build", "cargo: test"])
        XCTAssertEqual(names, detect(files).map(\.task.name))
        XCTAssertEqual(limits["package.json"], 1_048_576)
        XCTAssertEqual(limits["Makefile"], 262_144)
        XCTAssertEqual(Set(detect(files).map(\.id)).count, names.count, "IDs are unique")
        XCTAssertEqual(commands(["Makefile": "all:" + String(repeating: " ", count: 262_144)]), [], "An oversized file is skipped")
    }
}
