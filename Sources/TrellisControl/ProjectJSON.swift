import Foundation
import TrellisCore

/// A library project as JSON (FR-PL03, FR-PL04): strict parsing (unknown fields are errors) and a stable encoding in
/// a fixed, readable field order. Identity, revision and launch history stay out of it.
public enum ProjectJSON {
    public static let maximumBytes = 262_144

    /// The project, or every problem found, each naming where it is.
    public static func parse(_ data: Data) -> Result<ProjectDefinition, ProjectJSONError> {
        guard data.count <= maximumBytes else { return .failure(ProjectJSONError(["Projects are limited to 256 KB of JSON."])) }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return .failure(ProjectJSONError(["The text is not valid JSON."])) }
        var problems: [String] = []
        func fail(_ where: String, _ message: String) { problems.append(`where`.isEmpty ? message : "\(`where`): \(message)") }
        func object(_ value: JSONValue?, _ allowed: Set<String>, _ required: Set<String>, _ where: String) -> [String: JSONValue]? {
            guard case .object(let fields)? = value else { fail(`where`, "must be an object."); return nil }
            let unknown = Set(fields.keys).subtracting(allowed), missing = required.subtracting(fields.keys)
            if !unknown.isEmpty { fail(`where`, "has unsupported fields: \(unknown.sorted().joined(separator: ", ")).") }
            if !missing.isEmpty { fail(`where`, "is missing: \(missing.sorted().joined(separator: ", ")).") }
            return unknown.isEmpty && missing.isEmpty ? fields : nil
        }
        func string(_ fields: [String: JSONValue], _ key: String, _ where: String) -> String? {
            guard let raw = fields[key] else { return nil }
            guard case .string(let text) = raw else { fail(`where`, "\(key) must be a string."); return nil }
            return text
        }
        func repository(_ fields: [String: JSONValue], _ where: String) -> ProjectRepository? {
            guard fields["repository"] != nil, let repo = object(fields["repository"], ["url", "branch"], ["url"], `where` + " repository") else { return nil }
            return string(repo, "url", `where`).map { ProjectRepository(url: $0, branch: string(repo, "branch", `where`)) }
        }
        func node(_ value: JSONValue?, _ where: String, depth: Int) -> ProjectNode? {
            guard depth <= ProjectDefinition.maximumDepth + 1 else { fail(`where`, "splits nest too deeply."); return nil }
            guard case .object(let raw)? = value, case .string(let type)? = raw["type"] else { fail(`where`, "a node needs a type of pane or split."); return nil }
            switch type {
            case "pane":
                guard let fields = object(value, ["type", "title", "directory", "command", "repository"], ["type"], `where`) else { return nil }
                return .pane(
                    ProjectPane(
                        title: string(fields, "title", `where`), directory: string(fields, "directory", `where`), command: string(fields, "command", `where`),
                        repository: repository(fields, `where`)))
            case "split":
                guard let fields = object(value, ["type", "axis", "ratio", "children"], ["type", "axis", "children"], `where`) else { return nil }
                guard let axis = string(fields, "axis", `where`).flatMap(SplitAxis.init(rawValue:)) else { fail(`where`, "axis must be x or y."); return nil }
                var ratio = 0.5
                if let raw = fields["ratio"] {
                    guard case .number(let number) = raw else { fail(`where`, "ratio must be a number."); return nil }
                    ratio = number
                }
                guard case .array(let children)? = fields["children"], children.count == 2 else { fail(`where`, "a split needs exactly two children."); return nil }
                guard let first = node(children[0], `where` + ".1", depth: depth + 1), let second = node(children[1], `where` + ".2", depth: depth + 1) else { return nil }
                return .split(axis: axis, ratio: ratio, first: first, second: second)
            default:
                fail(`where`, "a node's type is pane or split.")
                return nil
            }
        }
        guard let root = object(value, ["name", "notes", "repository", "tabs"], ["name", "tabs"], "The project") else { return .failure(ProjectJSONError(problems)) }
        let name = string(root, "name", "")
        let notes = string(root, "notes", "")
        let projectRepository = repository(root, "Project")
        guard case .array(let rawTabs)? = root["tabs"] else { return .failure(ProjectJSONError(problems + ["tabs must be an array."])) }
        var tabs: [ProjectTab] = []
        for (index, rawTab) in rawTabs.prefix(ProjectDefinition.maximumTabs + 1).enumerated() {
            let place = "Tab \(index + 1)"
            guard let fields = object(rawTab, ["title", "color", "directory", "repository", "root"], ["title", "root"], place) else { continue }
            var color: TabColor?
            if let raw = string(fields, "color", place) {
                color = TabColor(rawValue: raw)
                if color == nil { fail(place, "color must be one of \(TabColor.allCases.map(\.rawValue).joined(separator: ", ")).") }
            }
            guard let title = string(fields, "title", place), let root = node(fields["root"], place + " layout", depth: 0) else { continue }
            tabs.append(ProjectTab(title: title, color: color, directory: string(fields, "directory", place), repository: repository(fields, place), root: root))
        }
        guard problems.isEmpty, let name else { return .failure(ProjectJSONError(problems.isEmpty ? ["The project needs a name."] : problems)) }
        let project = ProjectDefinition(name: name, notes: notes, repository: projectRepository, tabs: tabs)
        let issues = project.issues
        return issues.isEmpty ? .success(project) : .failure(ProjectJSONError(issues.map { describe($0, in: project) }))
    }

    /// "Tab 2 “API”, pane 3: The command …".
    public static func describe(_ issue: ProjectDefinition.Issue, in project: ProjectDefinition) -> String {
        switch issue.place {
        case .project: return issue.message
        case .tab(let index): return "\(tabName(index, project)): \(issue.message)"
        case .node(let tab, let path):
            let panes = project.tabs.indices.contains(tab) ? project.tabs[tab].root.panes.map(\.path) : []
            let pane = panes.firstIndex(of: path).map { "pane \($0 + 1)" } ?? "split"
            return "\(tabName(tab, project)), \(pane): \(issue.message)"
        }
    }

    private static func tabName(_ index: Int, _ project: ProjectDefinition) -> String {
        project.tabs.indices.contains(index) ? "Tab \(index + 1) “\(project.tabs[index].title)”" : "Tab \(index + 1)"
    }

    public static func encode(_ project: ProjectDefinition) -> Data {
        func text(_ fields: inout [(String, StableJSON.Value)], _ key: String, _ value: String?) { if let value { fields.append((key, .string(value))) } }
        func repository(_ fields: inout [(String, StableJSON.Value)], _ repository: ProjectRepository?) {
            guard let repository else { return }
            var inner: [(String, StableJSON.Value)] = [("url", .string(repository.url))]
            text(&inner, "branch", repository.branch)
            fields.append(("repository", .object(inner)))
        }
        func encoded(_ node: ProjectNode) -> StableJSON.Value {
            switch node {
            case .pane(let pane):
                var fields: [(String, StableJSON.Value)] = [("type", .string("pane"))]
                text(&fields, "title", pane.title); text(&fields, "directory", pane.directory); text(&fields, "command", pane.command)
                repository(&fields, pane.repository)
                return .object(fields)
            case .split(let axis, let ratio, let first, let second):
                return .object([
                    ("type", .string("split")), ("axis", .string(axis.rawValue)), ("ratio", .number((ratio * 1000).rounded() / 1000)),
                    ("children", .array([encoded(first), encoded(second)]))
                ])
            }
        }
        var fields: [(String, StableJSON.Value)] = [("name", .string(project.name))]
        text(&fields, "notes", project.notes)
        repository(&fields, project.repository)
        fields.append(
            (
                "tabs",
                .array(
                    project.tabs.map { tab in
                        var inner: [(String, StableJSON.Value)] = [("title", .string(tab.title))]
                        text(&inner, "color", tab.color?.rawValue); text(&inner, "directory", tab.directory)
                        repository(&inner, tab.repository)
                        inner.append(("root", encoded(tab.root)))
                        return .object(inner)
                    })
            ))
        return StableJSON.render(.object(fields))
    }
}

public struct ProjectJSONError: Error, Equatable, Sendable {
    public let problems: [String]
    public init(_ problems: [String]) { self.problems = problems }
}
