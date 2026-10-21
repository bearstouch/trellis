import Foundation
import TrellisCore

/// Strict `.trellis/project.json` v1 parsing and stable, diff-friendly encoding (FR-WF01).
/// Unknown fields are errors; `$schema` is the only extra a document may carry.
public enum ProjectFileJSON {
    public static func parse(_ data: Data) -> Result<ProjectFile, LayoutParseError> {
        guard data.count <= ProjectFile.maximumBytes else { return .failure(LayoutParseError(issues: [LayoutIssue(key: nil, "Project files are limited to 256 KB.")])) }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return .failure(LayoutParseError(issues: [LayoutIssue(key: nil, "The project file is not valid JSON.")]))
        }
        return parse(value)
    }

    public static func parse(_ value: JSONValue) -> Result<ProjectFile, LayoutParseError> {
        var issues: [LayoutIssue] = []
        func fail(_ key: String?, _ message: String) { issues.append(LayoutIssue(key: key, message)) }
        func object(_ value: JSONValue?, _ allowed: Set<String>, _ required: Set<String>, _ context: String) -> [String: JSONValue]? {
            guard case .object(let fields)? = value else { fail(nil, "\(context) must be an object."); return nil }
            let unknown = Set(fields.keys).subtracting(allowed)
            if !unknown.isEmpty { fail(nil, "\(context) has unsupported fields: \(unknown.sorted().joined(separator: ", ")).") }
            let missing = required.subtracting(fields.keys)
            if !missing.isEmpty { fail(nil, "\(context) is missing: \(missing.sorted().joined(separator: ", ")).") }
            return unknown.isEmpty && missing.isEmpty ? fields : nil
        }
        func string(_ value: JSONValue?, _ key: String?, _ name: String) -> String? {
            guard case .string(let text)? = value else { fail(key, "\(name) must be a string."); return nil }
            return text
        }
        func optional(_ fields: [String: JSONValue], _ field: String, _ key: String?) -> String? {
            fields[field].flatMap { string($0, key, field) }
        }
        func node(_ value: JSONValue?, depth: Int) -> ProjectFile.Node? {
            guard depth <= LayoutPlanner.maxNesting + 1 else { fail(nil, "Split nesting exceeds \(LayoutPlanner.maxNesting)."); return nil }
            guard case .object(let fields)? = value, case .string(let type)? = fields["type"] else { fail(nil, "A node needs a type of pane or split."); return nil }
            switch type {
            case "pane":
                guard let fields = object(value, ["type", "key", "title", "directory", "command"], ["type"], "pane") else { return nil }
                let key = optional(fields, "key", nil)
                return .pane(
                    ProjectFile.Pane(
                        key: key, title: optional(fields, "title", key), directory: optional(fields, "directory", key), command: optional(fields, "command", key)))
            case "split":
                guard let fields = object(value, ["type", "key", "axis", "ratio", "children"], ["type", "axis", "children"], "split") else { return nil }
                let key = optional(fields, "key", nil)
                let axis: SplitAxis
                switch fields["axis"] {
                case .string("x")?: axis = .x
                case .string("y")?: axis = .y
                default: fail(key, "axis must be x or y."); return nil
                }
                var ratio = 0.5
                if let raw = fields["ratio"] {
                    guard case .number(let value) = raw else { fail(key, "ratio must be a number."); return nil }
                    ratio = value
                }
                guard case .array(let children)? = fields["children"], children.count == 2 else { fail(key, "A split needs exactly two children."); return nil }
                let built = children.compactMap { node($0, depth: depth + 1) }
                return built.count == 2 ? .split(key: key, axis: axis, ratio: ratio, children: built) : nil
            default:
                fail(nil, "Node type must be pane or split.")
                return nil
            }
        }
        guard let root = object(value, ["$schema", "version", "name", "tabs"], ["version", "name", "tabs"], "The project file") else {
            return .failure(LayoutParseError(issues: issues))
        }
        guard root["version"] == .number(1) else { return .failure(LayoutParseError(issues: issues + [LayoutIssue(key: nil, "Only project file version 1 is supported.")])) }
        if let schema = root["$schema"] { _ = string(schema, nil, "$schema") }
        let name = string(root["name"], nil, "name")
        guard case .array(let rawTabs)? = root["tabs"], !rawTabs.isEmpty else {
            return .failure(LayoutParseError(issues: issues + [LayoutIssue(key: nil, "tabs must be a non-empty array.")]))
        }
        if rawTabs.count > 50 { fail(nil, "Use at most 50 tabs.") }
        var tabs: [ProjectFile.Tab] = []
        for rawTab in rawTabs.prefix(51) {
            guard let fields = object(rawTab, ["key", "title", "color", "root"], ["title", "root"], "tab") else { continue }
            let key = optional(fields, "key", nil)
            var color: TabColor?
            if let raw = optional(fields, "color", key) {
                color = TabColor(rawValue: raw)
                if color == nil { fail(key, "color must be one of \(TabColor.allCases.map(\.rawValue).joined(separator: ", ")).") }
            }
            guard let title = string(fields["title"], key, "title"), let root = node(fields["root"], depth: 0) else { continue }
            tabs.append(ProjectFile.Tab(key: key, title: title, color: color, root: root))
        }
        guard issues.isEmpty, let name else { return .failure(LayoutParseError(issues: issues)) }
        let file = ProjectFile(name: name, tabs: tabs)
        let semantic = file.issues
        return semantic.isEmpty ? .success(file) : .failure(LayoutParseError(issues: semantic))
    }

    /// Fields in a fixed, readable order with two-space indentation and a final newline, so saving the same
    /// window twice produces identical bytes and reviews show only real changes.
    public static func encode(_ file: ProjectFile) -> Data {
        func encoded(_ node: ProjectFile.Node) -> StableJSON.Value {
            switch node {
            case .pane(let pane):
                var fields: [(String, StableJSON.Value)] = [("type", .string("pane"))]
                if let key = pane.key { fields.append(("key", .string(key))) }
                if let title = pane.title { fields.append(("title", .string(title))) }
                if let directory = pane.directory { fields.append(("directory", .string(directory))) }
                if let command = pane.command { fields.append(("command", .string(command))) }
                return .object(fields)
            case .split(let key, let axis, let ratio, let children):
                var fields: [(String, StableJSON.Value)] = [("type", .string("split"))]
                if let key { fields.append(("key", .string(key))) }
                fields += [("axis", .string(axis.rawValue)), ("ratio", .number(ratio)), ("children", .array(children.map(encoded)))]
                return .object(fields)
            }
        }
        let tabs: [StableJSON.Value] = file.tabs.map { tab in
            var fields: [(String, StableJSON.Value)] = []
            if let key = tab.key { fields.append(("key", .string(key))) }
            fields.append(("title", .string(tab.title)))
            if let color = tab.color { fields.append(("color", .string(color.rawValue))) }
            fields.append(("root", encoded(tab.root)))
            return .object(fields)
        }
        return StableJSON.render(.object([("version", .number(1)), ("name", .string(file.name)), ("tabs", .array(tabs))]))
    }
}
