import Foundation

/// Where a task in the Tasks menu comes from.
public enum TaskSource: String, CaseIterable, Sendable {
    case file, npm, make, cmake, swift, python, cargo

    public var displayName: String {
        switch self {
        case .file: "launch.json"
        case .npm: "package.json"
        case .make: "Makefile"
        case .cmake: "CMake"
        case .swift: "SwiftPM"
        case .python: "Python"
        case .cargo: "Cargo"
        }
    }
}

/// A task Trellis found in the project folder (FR-TK03). Its command comes from a fixed template, never from the
/// file's own text except a package script or Make target name, which must be a plain word.
public struct DetectedTask: Equatable, Sendable, Identifiable {
    public let source: TaskSource
    public let task: LaunchTask
    /// Where it was found, for the menu: "script “test” in package.json".
    public let detail: String
    public var id: String { "detected:" + task.name }
    public init(source: TaskSource, task: LaunchTask, detail: String) { self.source = source; self.task = task; self.detail = detail }
}

/// Reads only well-known files at the project root, each with a size limit, and never runs anything (FR-TK03).
/// `read(name, limit)` returns nil for a missing, unreadable or oversized file; `exists(name)` tests a root entry.
public enum TaskDetector {
    public static let maximumTasks = 200
    static let maximumPerSource = 50
    static let maximumManifestBytes = 1_048_576
    static let maximumBuildFileBytes = 262_144

    public static func detect(read: (String, Int) -> Data?, exists: (String) -> Bool) -> [DetectedTask] {
        let found =
            npmTasks(read: read, exists: exists) + makeTasks(read: read) + cmakeTasks(read: read, exists: exists) + swiftTasks(exists: exists)
            + pythonTasks(read: read, exists: exists) + cargoTasks(read: read, exists: exists)
        return Array(found.prefix(maximumTasks))
    }

    // MARK: npm, pnpm, yarn, bun

    static func npmTasks(read: (String, Int) -> Data?, exists: (String) -> Bool) -> [DetectedTask] {
        guard let data = read("package.json", maximumManifestBytes),
            let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let scripts = manifest["scripts"] as? [String: Any]
        else { return [] }
        let manager = packageManager(manifest["packageManager"] as? String, exists: exists)
        let tasks = scripts.keys.sorted().filter { scripts[$0] is String }.compactMap { name -> DetectedTask? in
            guard let word = plainWord(name) else { return nil }
            return DetectedTask(
                source: .npm, task: LaunchTask(name: "\(manager): \(name)", command: "\(manager) run \(word)", group: group(forScript: name)),
                detail: "script “\(name)” in package.json")
        }
        return Array(tasks.prefix(maximumPerSource))
    }

    static func packageManager(_ declared: String?, exists: (String) -> Bool) -> String {
        if let declared, let name = declared.split(separator: "@").first, ["npm", "pnpm", "yarn", "bun"].contains(String(name)) { return String(name) }
        if exists("pnpm-lock.yaml") { return "pnpm" }
        if exists("yarn.lock") { return "yarn" }
        if exists("bun.lock") || exists("bun.lockb") { return "bun" }
        return "npm"
    }

    static func group(forScript name: String) -> TaskGroup? {
        let base = name.split(separator: ":").first.map { $0.lowercased() } ?? ""
        if base.hasPrefix("test") || base == "e2e" { return .test }
        if ["build", "compile"].contains(base) { return .build }
        if ["start", "dev", "serve", "watch"].contains(base) { return .run }
        return nil
    }

    /// A name typed as one shell word: bare when it has only safe characters, single-quoted otherwise. Quotes and
    /// backslashes quote differently in fish and POSIX shells, and a leading `-` reads as an option, so those are skipped.
    static func plainWord(_ name: String) -> String? {
        guard !name.isEmpty, name.count <= 100, ProjectFile.commandProblem(name) == nil, !name.contains("'"), !name.contains("\\"), !name.hasPrefix("-")
        else { return nil }
        let safe = name.unicodeScalars.allSatisfy { $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || "_-.:/@+=,".unicodeScalars.contains($0)) }
        return safe ? name : "'\(name)'"
    }

    // MARK: Make

    static func makeTasks(read: (String, Int) -> Data?) -> [DetectedTask] {
        guard let (file, data) = ["GNUmakefile", "makefile", "Makefile"].firstNonNil({ name in read(name, maximumBuildFileBytes).map { (name, $0) } })
        else { return [] }
        var targets: [String] = []
        for line in String(decoding: data, as: UTF8.self).split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            guard let target = makeTarget(line), !targets.contains(target) else { continue }
            targets.append(target)
            if targets.count == maximumPerSource { break }
        }
        return targets.map { DetectedTask(source: .make, task: LaunchTask(name: "make: \($0)", command: "make \($0)", group: group(forTarget: $0)), detail: "target in \(file)") }
    }

    /// The first target of a rule line. Recipes (indented), comments, special targets (`.PHONY`), pattern rules (`%`),
    /// variable targets (`$(…)`) and assignments (`=`, `:=`, `::=`, `+=`, `?=`) are skipped; `::` rules count.
    static func makeTarget(_ line: Substring) -> String? {
        guard let first = line.first, !first.isWhitespace, first != "#", first != ".", let colon = line.firstIndex(of: ":") else { return nil }
        let head = line[..<colon], after = line[line.index(after: colon)...]
        guard !head.contains("="), !head.contains("%"), !head.contains("$"), !after.drop(while: { $0 == ":" }).hasPrefix("=") else { return nil }
        guard let word = head.split(whereSeparator: \.isWhitespace).first, let start = word.unicodeScalars.first, start.isASCII,
            start.properties.isAlphabetic || ("0"..."9").contains(start),
            word.unicodeScalars.allSatisfy({ $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || "_-./".unicodeScalars.contains($0)) })
        else { return nil }
        return String(word)
    }

    static func group(forTarget name: String) -> TaskGroup? {
        if ["test", "tests", "check"].contains(name) { return .test }
        if ["all", "build"].contains(name) { return .build }
        if ["run", "serve", "start"].contains(name) { return .run }
        return nil
    }

    // MARK: CMake, SwiftPM, Python, Cargo

    static func cmakeTasks(read: (String, Int) -> Data?, exists: (String) -> Bool) -> [DetectedTask] {
        guard exists("CMakeLists.txt") else { return [] }
        var tasks = [
            DetectedTask(
                source: .cmake, task: LaunchTask(name: "cmake: build", command: "cmake -S . -B build && cmake --build build", group: .build),
                detail: "CMakeLists.txt")
        ]
        let text = read("CMakeLists.txt", maximumBuildFileBytes).map { String(decoding: $0, as: UTF8.self) } ?? ""
        if text.contains("enable_testing") || text.contains("add_test") {
            tasks.append(DetectedTask(source: .cmake, task: LaunchTask(name: "cmake: test", command: "ctest --test-dir build", group: .test), detail: "tests in CMakeLists.txt"))
        }
        return tasks
    }

    static func swiftTasks(exists: (String) -> Bool) -> [DetectedTask] {
        guard exists("Package.swift") else { return [] }
        return [
            DetectedTask(source: .swift, task: LaunchTask(name: "swift: build", command: "swift build", group: .build), detail: "Package.swift"),
            DetectedTask(source: .swift, task: LaunchTask(name: "swift: test", command: "swift test", group: .test), detail: "Package.swift")
        ]
    }

    static func pythonTasks(read: (String, Int) -> Data?, exists: (String) -> Bool) -> [DetectedTask] {
        let markers = ["pyproject.toml", "setup.py", "setup.cfg", "pytest.ini", "tox.ini"]
        guard let marker = markers.first(where: exists) else { return [] }
        let text = ["pyproject.toml", "setup.cfg", "tox.ini"].compactMap { read($0, maximumBuildFileBytes) }.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n")
        let pytest = exists("pytest.ini") || exists("conftest.py") || text.contains("[tool.pytest") || text.contains("[pytest]") || text.contains("[tool:pytest]")
        let uv = exists("uv.lock")
        let command =
            switch (pytest, uv) {
            case (true, true): "uv run pytest"
            case (true, false): "python3 -m pytest"
            case (false, true): "uv run python -m unittest"
            case (false, false): "python3 -m unittest"
            }
        var tasks = [DetectedTask(source: .python, task: LaunchTask(name: "python: test", command: command, group: .test), detail: marker)]
        if exists("tox.ini") { tasks.append(DetectedTask(source: .python, task: LaunchTask(name: "python: tox", command: "tox", group: .test), detail: "tox.ini")) }
        return tasks
    }

    static func cargoTasks(read: (String, Int) -> Data?, exists: (String) -> Bool) -> [DetectedTask] {
        guard exists("Cargo.toml") else { return [] }
        var tasks = [
            DetectedTask(source: .cargo, task: LaunchTask(name: "cargo: build", command: "cargo build", group: .build), detail: "Cargo.toml"),
            DetectedTask(source: .cargo, task: LaunchTask(name: "cargo: test", command: "cargo test", group: .test), detail: "Cargo.toml")
        ]
        let manifest = read("Cargo.toml", maximumBuildFileBytes).map { String(decoding: $0, as: UTF8.self) } ?? ""
        if exists("src/main.rs") || manifest.contains("[[bin]]") {
            tasks.append(DetectedTask(source: .cargo, task: LaunchTask(name: "cargo: run", command: "cargo run", group: .run), detail: "binary in Cargo.toml"))
        }
        return tasks
    }
}

extension Sequence {
    fileprivate func firstNonNil<T>(_ transform: (Element) -> T?) -> T? {
        for element in self { if let value = transform(element) { return value } }
        return nil
    }
}
