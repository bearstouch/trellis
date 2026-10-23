import Foundation
import TrellisCore

/// Strict `.trellis/launch.json` v1 parsing and stable encoding (FR-TK01). Unknown fields are errors; `$schema` is
/// the only extra a document may carry.
public enum LaunchFileJSON {
    public static func parse(_ data: Data) -> Result<LaunchFile, LayoutParseError> {
        guard data.count <= LaunchFile.maximumBytes else { return .failure(LayoutParseError(issues: [LayoutIssue(key: nil, "launch.json is limited to 64 KB.")])) }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return .failure(LayoutParseError(issues: [LayoutIssue(key: nil, "launch.json is not valid JSON.")]))
        }
        return parse(value)
    }

    public static func parse(_ value: JSONValue) -> Result<LaunchFile, LayoutParseError> {
        var issues: [LayoutIssue] = []
        func fail(_ key: String?, _ message: String) { issues.append(LayoutIssue(key: key, message)) }
        func object(_ value: JSONValue?, _ allowed: Set<String>, _ required: Set<String>, _ context: String, key: String? = nil) -> [String: JSONValue]? {
            guard case .object(let fields)? = value else { fail(key, "\(context) must be an object."); return nil }
            let unknown = Set(fields.keys).subtracting(allowed)
            if !unknown.isEmpty { fail(key, "\(context) has unsupported fields: \(unknown.sorted().joined(separator: ", ")).") }
            let missing = required.subtracting(fields.keys)
            if !missing.isEmpty { fail(key, "\(context) is missing: \(missing.sorted().joined(separator: ", ")).") }
            return unknown.isEmpty && missing.isEmpty ? fields : nil
        }
        func string(_ value: JSONValue?, _ key: String?, _ name: String) -> String? {
            guard case .string(let text)? = value else { fail(key, "\(name) must be a string."); return nil }
            return text
        }
        func variables(_ value: JSONValue?, _ key: String?) -> [String: String]? {
            guard let value else { return [:] }
            guard case .object(let fields) = value else { fail(key, "env must be an object of strings."); return nil }
            var result: [String: String] = [:]
            for (name, raw) in fields {
                guard case .string(let text) = raw else { fail(key, "env value \(name) must be a string."); return nil }
                result[name] = text
            }
            return result
        }
        guard let root = object(value, ["$schema", "version", "env", "tasks"], ["version", "tasks"], "launch.json") else {
            return .failure(LayoutParseError(issues: issues))
        }
        guard root["version"] == .number(1) else { return .failure(LayoutParseError(issues: issues + [LayoutIssue(key: nil, "Only launch.json version 1 is supported.")])) }
        let schema = root["$schema"].flatMap { string($0, nil, "$schema") }
        let env = variables(root["env"], nil)
        guard case .array(let rawTasks)? = root["tasks"] else { return .failure(LayoutParseError(issues: issues + [LayoutIssue(key: nil, "tasks must be an array.")])) }
        if rawTasks.count > LaunchFile.maximumTasks { fail(nil, "Use at most \(LaunchFile.maximumTasks) tasks.") }
        var tasks: [LaunchTask] = []
        for (index, rawTask) in rawTasks.prefix(LaunchFile.maximumTasks + 1).enumerated() {
            // Issues name the task, or its position when the name itself is unusable.
            var key = "task \(index + 1)"
            if case .object(let fields) = rawTask, case .string(let name)? = fields["name"] { key = name }
            guard let fields = object(rawTask, ["name", "command", "cwd", "group", "env"], ["name", "command"], "A task", key: key) else { continue }
            let name = string(fields["name"], key, "name"), command = string(fields["command"], key, "command")
            let cwd = fields["cwd"].flatMap { string($0, key, "cwd") }
            var group: TaskGroup?
            if let raw = fields["group"].flatMap({ string($0, key, "group") }) {
                group = TaskGroup(rawValue: raw)
                if group == nil { fail(key, "group must be one of \(TaskGroup.allCases.map(\.rawValue).joined(separator: ", ")).") }
            }
            guard let name, let command, let taskEnv = variables(fields["env"], key) else { continue }
            tasks.append(LaunchTask(name: name, command: command, cwd: cwd, group: group, env: taskEnv))
        }
        guard issues.isEmpty, let env else { return .failure(LayoutParseError(issues: issues)) }
        let file = LaunchFile(schema: schema, env: env, tasks: tasks)
        let semantic = file.issues
        return semantic.isEmpty ? .success(file) : .failure(LayoutParseError(issues: semantic))
    }

    /// `$schema` (when present), `version`, `env`, `tasks`; each task `name`, `command`, `cwd`, `group`, `env`; variables sorted by name.
    public static func encode(_ file: LaunchFile) -> Data {
        func variables(_ env: [String: String]) -> StableJSON.Value { .object(env.sorted { $0.key < $1.key }.map { ($0.key, .string($0.value)) }) }
        let tasks: [StableJSON.Value] = file.tasks.map { task in
            var fields: [(String, StableJSON.Value)] = [("name", .string(task.name)), ("command", .string(task.command))]
            if let cwd = task.cwd { fields.append(("cwd", .string(cwd))) }
            if let group = task.group { fields.append(("group", .string(group.rawValue))) }
            if !task.env.isEmpty { fields.append(("env", variables(task.env))) }
            return .object(fields)
        }
        var document: [(String, StableJSON.Value)] = file.schema.map { [("$schema", .string($0))] } ?? []
        document.append(("version", .number(1)))
        if !file.env.isEmpty { document.append(("env", variables(file.env))) }
        document.append(("tasks", .array(tasks)))
        return StableJSON.render(.object(document))
    }

    /// One issue per line for an alert or the menu.
    public static func describe(_ error: LayoutParseError) -> String {
        error.text
    }
}
