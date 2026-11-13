import Foundation
import TrellisCore

/// Strict layout parsing (the committed JSON Schema): unknown fields, wrong types, and executable content such as
/// `process` launches are errors.
public struct LayoutParseError: Error, Equatable, Sendable {
    public let issues: [LayoutIssue]
    /// The document's `version` isn't one this build reads (UNSUPPORTED_VERSION rather than an invalid document).
    public var unsupportedVersion = false
    /// Every issue, for one error message.
    public var text: String { issues.map(\.text).joined(separator: " ") }
}

public enum LayoutJSON {
    /// The version `layout.export` writes and older documents are read as.
    public static let currentVersion = 3
    public static let supportedVersions = [1, 2, 3]

    /// `allowRemoteHosts` reads a portable export's layout (FR-R02): versions 1 (`windows`) and 2, whose spaces may carry
    /// `remoteHostId`. Otherwise it reads an API layout (docs/api/layouts.md): version 3, or 1 and 2 read as 3 (a `host`
    /// launch is an `ssh` one); the list must be named `spaces`, and only version 3 has `machine`, `projectId` and `agent`.
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
        func uuid(_ value: JSONValue?, _ key: String?, _ name: String) -> UUID? {
            guard case .string(let text)? = value, let id = UUID(uuidString: text) else { fail(key, "\(name) must be a UUID."); return nil }
            return id
        }
        guard case .object(let top)? = value, case .number(let number)? = top["version"] else {
            _ = object(value, ["version", "spaces"], ["version", "spaces"], "The layout document")
            if issues.isEmpty { fail(nil, "version must be a number.") }
            return .failure(LayoutParseError(issues: issues))
        }
        let readable = allowRemoteHosts ? [1, 2] : supportedVersions
        guard let version = readable.first(where: { Double($0) == number }) else {
            let list = readable.map(String.init).joined(separator: ", ")
            return .failure(LayoutParseError(issues: [LayoutIssue(key: nil, "Only layout versions \(list) are supported.")], unsupportedVersion: true))
        }
        let current = version == currentVersion && !allowRemoteHosts
        // Version 1 named the list `windows`. Portable exports still read it; API layouts refuse it (migration.md).
        let listKey = allowRemoteHosts && version == 1 ? "windows" : "spaces"
        if !allowRemoteHosts, top["windows"] != nil {
            return .failure(LayoutParseError(issues: [LayoutIssue(key: nil, "windows is no longer accepted: name the list spaces (layout version 3).")]))
        }
        func node(_ value: JSONValue?, depth: Int) -> LayoutNode? {
            // Bound recursion before descending (the planner re-checks nesting).
            guard depth <= LayoutPlanner.maxNesting + 1 else { fail(nil, "Split nesting exceeds \(LayoutPlanner.maxNesting)."); return nil }
            guard case .object(let fields)? = value, case .string(let type)? = fields["type"] else { fail(nil, "A node needs a type of pane or split."); return nil }
            switch type {
            case "pane":
                guard let fields = object(value, current ? ["type", "key", "title", "launch", "agent"] : ["type", "key", "title", "launch"], ["type", "key", "launch"], "pane"),
                    let key = string(fields["key"], nil, "key")
                else { return nil }
                let title = fields["title"].flatMap { string($0, key, "title") }
                guard let launchFields = object(fields["launch"], ["kind", "directory", "hostId"], ["kind"], "launch \(key)"),
                    let kind = string(launchFields["kind"], key, "launch.kind")
                else { return nil }
                let agent = fields["agent"].flatMap { string($0, key, "agent") }
                // Version 3 names a saved-host launch `ssh`, as sessions do; versions 1 and 2 called it `host`.
                let hostKind = current ? "ssh" : "host"
                switch kind {
                case "shell":
                    if launchFields["hostId"] != nil { fail(key, "Shell launches do not take hostId.") }
                    let directory = launchFields["directory"].flatMap { string($0, key, "launch.directory") }
                    if let agent { return .pane(key: key, title: title, launch: .agent(agent, directory: directory)) }
                    return .pane(key: key, title: title, launch: .shell(directory: directory))
                case hostKind:
                    if launchFields["directory"] != nil { fail(key, "\(hostKind) launches do not take a directory.") }
                    if agent != nil { fail(key, "Only a shell launch can carry an agent.") }
                    guard let id = uuid(launchFields["hostId"], key, "launch.hostId") else { return nil }
                    return .pane(key: key, title: title, launch: .host(id))
                default:
                    fail(key, "Only shell and \(hostKind) launches are allowed in layouts; commands and processes are not.")
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
        guard let root = object(value, ["version", listKey], ["version", listKey], "The layout document") else { return .failure(LayoutParseError(issues: issues)) }
        guard case .array(let rawSpaces)? = root[listKey] else { return .failure(LayoutParseError(issues: issues + [LayoutIssue(key: nil, "\(listKey) must be an array.")])) }
        let spaceFields: Set<String> =
            allowRemoteHosts ? ["key", "name", "tabs", "remoteHostId"] : current ? ["key", "name", "tabs", "machine", "projectId"] : ["key", "name", "tabs"]
        var spaces: [LayoutSpace] = []
        for rawSpace in rawSpaces.prefix(11) {
            guard let fields = object(rawSpace, spaceFields, ["key", "name", "tabs"], "space"), let key = string(fields["key"], nil, "key"),
                let name = string(fields["name"], key, "name")
            else { continue }
            var remoteHostID: UUID?, projectID: UUID?
            if let raw = fields["remoteHostId"] {
                guard let id = uuid(raw, key, "remoteHostId") else { continue }
                remoteHostID = id
            }
            if let raw = fields["machine"] {
                guard let machine = object(raw, ["kind", "hostId"], ["kind"], "machine \(key)") else { continue }
                switch machine["kind"] {
                case .string("local")?: if machine["hostId"] != nil { fail(key, "A local machine takes no hostId.") }
                case .string("remote")?:
                    guard let id = uuid(machine["hostId"], key, "machine.hostId") else { continue }
                    remoteHostID = id
                default: fail(key, "machine.kind must be local or remote."); continue
                }
            }
            if let raw = fields["projectId"] {
                guard let id = uuid(raw, key, "projectId") else { continue }
                projectID = id
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
            spaces.append(LayoutSpace(key: key, name: name, tabs: tabs, remoteHostID: remoteHostID, projectID: projectID))
        }
        if rawSpaces.count > 10 { fail(nil, "Use at most 10 spaces.") }
        return issues.isEmpty ? .success(LayoutDocument(spaces: spaces)) : .failure(LayoutParseError(issues: issues))
    }

    /// The `version` a document declares, when it is one `parse` reads; `layout.validate` reports older ones as upgraded.
    public static func declaredVersion(_ value: JSONValue?) -> Int? {
        guard case .number(let number)? = value?["version"] else { return nil }
        return supportedVersions.first { Double($0) == number }
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
