import Foundation

/// A project's `.trellis/launch.json` (FR-TK01): named one-line tasks the Tasks menu types into the active
/// pane's shell. Like a workspace file it is shared through the repository, so its tasks only run once the
/// exact bytes are trusted (FR-TK06).
public struct LaunchFile: Equatable, Sendable {
    public static let fileName = "launch.json"
    public static let maximumBytes = 65_536
    public static let maximumTasks = 100
    public static let maximumVariables = 50

    /// The document's `$schema`, kept so adding a task doesn't drop the editor's validation.
    public var schema: String?
    /// Applies to every task; a task's own variables win.
    public var env: [String: String]
    public var tasks: [LaunchTask]
    public init(schema: String? = nil, env: [String: String] = [:], tasks: [LaunchTask] = []) { self.schema = schema; self.env = env; self.tasks = tasks }

    public static func url(projectRoot: String) -> URL {
        URL(fileURLWithPath: projectRoot, isDirectory: true).appendingPathComponent(WorkspaceFile.directoryName, isDirectory: true)
            .appendingPathComponent(fileName)
    }

    public func task(named name: String) -> LaunchTask? { tasks.first { $0.name == name } }

    /// The variables `task` runs with, sorted by name so the typed line is stable (FR-TK09).
    public func environment(for task: LaunchTask) -> [(name: String, value: String)] {
        env.merging(task.env) { $1 }.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    /// Appends `task` unless one with the same command exists; a taken name gets a number (FR-TK04).
    public func adding(_ task: LaunchTask) -> (file: LaunchFile, added: Bool) {
        guard !tasks.contains(where: { $0.command == task.command && $0.cwd == task.cwd }) else { return (self, false) }
        var task = task, suffix = 2
        let base = task.name
        while self.task(named: task.name) != nil { task.name = "\(base) \(suffix)"; suffix += 1 }
        var copy = self
        copy.tasks.append(task)
        return (copy, true)
    }

    /// Rules the JSON shape can't express.
    public var issues: [LayoutIssue] {
        var issues: [LayoutIssue] = []
        if tasks.count > Self.maximumTasks { issues.append(LayoutIssue(key: nil, "Use at most \(Self.maximumTasks) tasks.")) }
        issues += Self.variableIssues(env, key: nil)
        var seen = Set<String>()
        for task in tasks {
            let key = task.name
            if let problem = WorkspaceFile.textProblem(task.name, limit: 100) { issues.append(LayoutIssue(key: key, "The task name \(problem)")) }
            if !seen.insert(task.name).inserted { issues.append(LayoutIssue(key: key, "Task names must be unique.")) }
            if let problem = WorkspaceFile.commandProblem(task.command) { issues.append(LayoutIssue(key: key, "The command \(problem)")) }
            if let cwd = task.cwd, cwd != ".", WorkspaceFile.relativeDirectory(cwd) == nil {
                issues.append(LayoutIssue(key: key, "cwd must be relative to the project folder, without .., ~, $ or backticks."))
            }
            issues += Self.variableIssues(task.env, key: key)
            if environment(for: task).count > Self.maximumVariables {
                issues.append(LayoutIssue(key: key, "A task can use at most \(Self.maximumVariables) variables."))
            }
        }
        return issues
    }

    static func variableIssues(_ env: [String: String], key: String?) -> [LayoutIssue] {
        env.sorted { $0.key < $1.key }.compactMap { name, value in
            if !isVariableName(name) { return LayoutIssue(key: key, "The variable name “\(name)” must match [A-Za-z_][A-Za-z0-9_]*.") }
            if value.count > WorkspaceFile.maximumCommandLength || WorkspaceFile.hasHiddenCharacters(value)
                || value.unicodeScalars.contains(where: \.properties.isDefaultIgnorableCodePoint)
            {
                return LayoutIssue(key: key, "The value of \(name) must be one line of at most \(WorkspaceFile.maximumCommandLength) characters without control characters.")
            }
            return nil
        }
    }

    public static func isVariableName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, name.utf8.count <= 255, first.isASCII, first == "_" || first.properties.isAlphabetic else { return false }
        return name.unicodeScalars.allSatisfy { $0.isASCII && ($0 == "_" || $0.properties.isAlphabetic || ("0"..."9").contains($0)) }
    }
}

public enum TaskGroup: String, CaseIterable, Sendable { case build, test, run }

public struct LaunchTask: Equatable, Sendable {
    public var name: String
    public var command: String
    /// Relative to the project folder; nil is the folder itself.
    public var cwd: String?
    public var group: TaskGroup?
    public var env: [String: String]
    public init(name: String, command: String, cwd: String? = nil, group: TaskGroup? = nil, env: [String: String] = [:]) {
        self.name = name; self.command = command; self.cwd = cwd; self.group = group; self.env = env
    }

    /// The absolute folder the task runs in. Call only on a file without issues.
    public func directory(projectRoot: String) -> String {
        let relative = cwd.flatMap(WorkspaceFile.relativeDirectory) ?? ""
        return relative.isEmpty ? projectRoot : projectRoot + "/" + relative
    }
}

/// The line Run types (FR-TK05, FR-TK09), quoted for the shell that reads it.
public enum TaskCommand {
    /// One single-quoted word. POSIX shells can't escape inside single quotes, so a quote closes and reopens them;
    /// fish treats `\\` and `\'` as escapes there instead.
    public static func shellQuote(_ text: String, kind: ShellIntegrationKind) -> String {
        switch kind {
        case .zsh, .bash: "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
        case .fish: "'" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
        }
    }

    /// `command`, after a `cd` when the shell is elsewhere, and wrapped in `env … shell -c` when it has variables so they
    /// cover the whole line. Nil when a part can't be typed safely or the line is too long.
    public static func compose(
        command: String, directory: String, currentDirectory: String?, environment: [(name: String, value: String)], shell: String?, kind: ShellIntegrationKind
    ) -> String? {
        guard directory.hasPrefix("/"), !WorkspaceFile.hasHiddenCharacters(directory) else { return nil }
        var line = command
        if !environment.isEmpty {
            // `env` reads every leading `NAME=value` word as a variable, so the shell path must not look like one.
            guard let shell, shell.hasPrefix("/"), !shell.contains("="), !WorkspaceFile.hasHiddenCharacters(shell),
                environment.allSatisfy({ LaunchFile.isVariableName($0.name) })
            else { return nil }
            let assignments = environment.map { $0.name + "=" + shellQuote($0.value, kind: kind) }
            line = (["/usr/bin/env"] + assignments + [shellQuote(shell, kind: kind), "-c", shellQuote(command, kind: kind)]).joined(separator: " ")
        }
        if currentDirectory.map(standardized) != standardized(directory) { line = "cd " + shellQuote(directory, kind: kind) + " && " + line }
        return WorkspaceFile.commandProblem(line) == nil ? line : nil
    }

    private static func standardized(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }
}
