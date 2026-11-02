import Foundation
import TrellisCore

/// Strict v1 layout parsing (the committed JSON Schema): unknown fields,
/// wrong types, and executable content such as `process` launches are errors.
public struct LayoutParseError: Error, Equatable, Sendable {
    public let issues: [LayoutIssue]
    /// Every issue, for one error message.
    public var text: String { issues.map(\.text).joined(separator: " ") }
}

public enum LayoutJSON {
    /// `allowRemoteHosts`: exports (FR-R02) may bind a window to a host reference; API layouts never can (FR-RW15).
    public static func parse(_ value: JSONValue?, allowRemoteHosts: Bool = false) -> Result<LayoutDocument, LayoutParseError> {
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
        func node(_ value: JSONValue?, depth: Int) -> LayoutNode? {
            // Bound recursion before descending (the planner re-checks nesting).
            guard depth <= LayoutPlanner.maxNesting + 1 else { fail(nil, "Split nesting exceeds \(LayoutPlanner.maxNesting)."); return nil }
            guard case .object(let fields)? = value, case .string(let type)? = fields["type"] else { fail(nil, "A node needs a type of pane or split."); return nil }
            switch type {
            case "pane":
                guard let fields = object(value, ["type", "key", "title", "launch"], ["type", "key", "launch"], "pane"),
                    let key = string(fields["key"], nil, "key")
                else { return nil }
                let title = fields["title"].flatMap { string($0, key, "title") }
                guard let launchFields = object(fields["launch"], ["kind", "directory", "hostId"], ["kind"], "launch \(key)"),
                    let kind = string(launchFields["kind"], key, "launch.kind")
                else { return nil }
                switch kind {
                case "shell":
                    if launchFields["hostId"] != nil { fail(key, "Shell launches do not take hostId.") }
                    let directory = launchFields["directory"].flatMap { string($0, key, "launch.directory") }
                    return .pane(key: key, title: title, launch: .shell(directory: directory))
                case "host":
                    if launchFields["directory"] != nil { fail(key, "Host launches do not take a directory.") }
                    guard let raw = string(launchFields["hostId"], key, "launch.hostId"), let id = UUID(uuidString: raw) else {
                        fail(key, "launch.hostId must be a UUID.")
                        return nil
                    }
                    return .pane(key: key, title: title, launch: .host(id))
                default:
                    fail(key, "Only shell and host launches are allowed in layouts; commands and processes are not.")
                    return nil
                }
            case "split":
                guard let fields = object(value, ["type", "key", "axis", "ratio", "children"], ["type", "key", "axis", "ratio", "children"], "split"),
                    let key = string(fields["key"], nil, "key")
                else { return nil }
                let axis: SplitAxis
                switch fields["axis"] {
                case .string("x")?: axis = .x
                case .string("y")?: axis = .y
                default: fail(key, "axis must be x or y."); return nil
                }
                guard case .number(let ratio)? = fields["ratio"] else { fail(key, "ratio must be a number."); return nil }
                guard case .array(let children)? = fields["children"], children.count == 2 else { fail(key, "A split needs exactly two children."); return nil }
                let built = children.compactMap { node($0, depth: depth + 1) }
                return built.count == 2 ? .split(key: key, axis: axis, ratio: ratio, children: built) : nil
            default:
                fail(nil, "Node type must be pane or split.")
                return nil
            }
        }
        guard let root = object(value, ["version", "windows"], ["version", "windows"], "The layout document") else { return .failure(LayoutParseError(issues: issues)) }
        guard root["version"] == .number(1) else { return .failure(LayoutParseError(issues: issues + [LayoutIssue(key: nil, "Only layout version 1 is supported.")])) }
        guard case .array(let rawWindows)? = root["windows"] else { return .failure(LayoutParseError(issues: issues + [LayoutIssue(key: nil, "windows must be an array.")])) }
        var windows: [LayoutWindow] = []
        for rawWindow in rawWindows.prefix(11) {
            guard let fields = object(rawWindow, allowRemoteHosts ? ["key", "name", "tabs", "remoteHostId"] : ["key", "name", "tabs"], ["key", "name", "tabs"], "window"),
                let key = string(fields["key"], nil, "key"), let name = string(fields["name"], key, "name")
            else { continue }
            var remoteHostID: UUID?
            if let raw = fields["remoteHostId"] {
                guard case .string(let text) = raw, let id = UUID(uuidString: text) else { fail(key, "remoteHostId must be a UUID."); continue }
                remoteHostID = id
            }
            guard case .array(let rawTabs)? = fields["tabs"] else { fail(key, "tabs must be an array."); continue }
            var tabs: [LayoutTab] = []
            for rawTab in rawTabs.prefix(51) {
                guard let tabFields = object(rawTab, ["key", "title", "root"], ["key", "title", "root"], "tab"),
                    let tabKey = string(tabFields["key"], nil, "key"), let title = string(tabFields["title"], tabKey, "title"),
                    let root = node(tabFields["root"], depth: 0)
                else { continue }
                tabs.append(LayoutTab(key: tabKey, title: title, root: root))
            }
            windows.append(LayoutWindow(key: key, name: name, tabs: tabs, remoteHostID: remoteHostID))
        }
        if rawWindows.count > 10 { fail(nil, "Use at most 10 windows.") }
        return issues.isEmpty ? .success(LayoutDocument(windows: windows)) : .failure(LayoutParseError(issues: issues))
    }

    public static func issuesJSON(_ issues: [LayoutIssue]) -> JSONValue {
        .array(
            issues.map { issue in
                var object: [String: JSONValue] = ["message": .string(issue.message)]
                if let key = issue.key { object["key"] = .string(key) }
                return .object(object)
            })
    }
}
