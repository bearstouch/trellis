import Foundation
import TrellisCore

/// Versioned, portable workspace exchange: a v1 layout plus saved-host
/// metadata. It never contains runtime IDs, output, environment values,
/// tokens, or key contents. Host references use fresh per-export UUIDs.
public enum PortableDocument {
    public static let format = "trellis.portable"
    public static let version = 1

    public struct PortableHost: Equatable, Sendable {
        /// Reference used by layout host launches inside this document only.
        public let reference: UUID
        public let draft: HostDraft
    }

    public struct Parsed: Equatable, Sendable {
        public let layout: LayoutDocument
        public let hosts: [PortableHost]
        /// Library projects (FR-PL05), without identity or launch history; each gets a new identity on import.
        public var projects: [ProjectDefinition] = []
    }

    public enum Collision: Equatable, Sendable {
        case name, destination
    }

    public struct Preview: Equatable, Sendable {
        public var windows = 0, tabs = 0, panes = 0, hosts = 0, projects = 0
        public var directories: [String] = []
        public var hostReferences: [String] = []
        /// Imported host index → existing host it collides with.
        public var collisions: [(imported: Int, existing: UUID, reason: Collision)] = []
        /// One line per collision naming both hosts, so the policy is chosen knowingly.
        public var collisionDetails: [String] = []
        public var errors: [LayoutIssue] = []

        public static func == (a: Self, b: Self) -> Bool {
            a.windows == b.windows && a.tabs == b.tabs && a.panes == b.panes && a.hosts == b.hosts && a.projects == b.projects && a.directories == b.directories
                && a.hostReferences == b.hostReferences && a.collisions.map { "\($0.imported)\($0.existing)\($0.reason)" } == b.collisions.map { "\($0.imported)\($0.existing)\($0.reason)" }
                && a.collisionDetails == b.collisionDetails && a.errors == b.errors
        }
    }

    // MARK: Export

    /// Exports every window and every saved host. Custom process panes become
    /// plain shells (their commands are never written), and are counted.
    public static func export(snapshot: WorkspaceSnapshot, hosts: [SavedHost], projects: [ProjectDefinition] = []) -> (document: JSONValue, convertedProcesses: Int) {
        var references: [UUID: UUID] = [:]
        for host in hosts { references[host.id] = UUID() }
        var counter = 0, converted = 0
        func key(_ prefix: String) -> JSONValue {
            counter += 1
            return .string("\(prefix)\(counter)")
        }
        func launch(_ paneID: UUID) -> JSONValue {
            switch snapshot.panes[paneID].flatMap({ snapshot.sessions[$0.sessionID] })?.launch {
            case .host(let id)? where references[id] != nil: return .object(["kind": .string("host"), "hostId": .string(references[id]!.uuidString)])
            case .shell(let directory?)?: return .object(["kind": .string("shell"), "directory": .string(directory)])
            case .process(_, let arguments, let directory?)? where arguments == ["-l"]: return .object(["kind": .string("shell"), "directory": .string(directory)])
            // A remote workspace's pane is a shell in a path on its host; the window carries the host (FR-R02).
            case .remoteShell(let host, let directory)? where references[host] != nil:
                return .object(directory.map { ["kind": .string("shell"), "directory": .string($0)] } ?? ["kind": .string("shell")])
            // An agent pane is exported as a plain shell: layouts carry no agent wiring (FR-AG04).
            case .process?, .remoteShell?, .agent?:
                converted += 1
                return .object(["kind": .string("shell")])
            default: return .object(["kind": .string("shell")])
            }
        }
        func node(_ layout: PaneLayout) -> JSONValue {
            switch layout {
            case .pane(let id):
                var object: [String: JSONValue] = ["type": .string("pane"), "key": key("p"), "launch": launch(id)]
                if let title = snapshot.panes[id]?.title { object["title"] = .string(title) }
                return .object(object)
            case .split(_, let axis, let ratio, let children):
                return .object(["type": .string("split"), "key": key("s"), "axis": .string(axis.rawValue), "ratio": .number(ratio), "children": .array(children.map(node))])
            }
        }
        let layout: JSONValue = .object([
            "version": .number(1),
            "windows": .array(
                snapshot.windows.map { window in
                    var object: [String: JSONValue] = [
                        "key": key("w"), "name": .string(window.name),
                        "tabs": .array(window.tabIDs.compactMap { snapshot.tabs[$0] }.map { tab in .object(["key": key("t"), "title": .string(tab.title), "root": node(tab.root)]) })
                    ]
                    if let host = window.remoteHostID.flatMap({ references[$0] }) { object["remoteHostId"] = .string(host.uuidString) }
                    return .object(object)
                })
        ])
        let hostList: JSONValue = .array(
            hosts.map { host in
                var object: [String: JSONValue] = [
                    "id": .string(references[host.id]!.uuidString), "name": .string(host.name), "destination": .string(host.destination),
                    "tags": .array(host.tags.map(JSONValue.string))
                ]
                if let user = host.user { object["user"] = .string(user) }
                if let port = host.port { object["port"] = .number(Double(port)) }
                if let identity = host.identityFile { object["identityFile"] = .string(identity) }
                return .object(object)
            })
        var document: [String: JSONValue] = ["format": .string(format), "version": .number(Double(version)), "layout": layout, "hosts": hostList]
        // In the library's JSON form; folders a project was launched in belong to this Mac and its hosts, so they stay.
        let projectList = projects.compactMap { try? JSONDecoder().decode(JSONValue.self, from: ProjectJSON.encode($0)) }
        if !projectList.isEmpty { document["projects"] = .array(projectList) }
        return (.object(document), converted)
    }

    // MARK: Import

    public static func parse(_ value: JSONValue) -> Result<Parsed, LayoutParseError> {
        func failure(_ message: String) -> Result<Parsed, LayoutParseError> { .failure(LayoutParseError(issues: [LayoutIssue(key: nil, message)])) }
        guard case .object(let root) = value else { return failure("The file is not a Trellis export.") }
        guard root["format"] == .string(format) else { return failure("The file is not a Trellis portable export.") }
        guard root["version"] == .number(Double(version)) else { return failure("This export uses an unsupported version. Update Trellis to import it.") }
        let unknown = Set(root.keys).subtracting(["format", "version", "layout", "hosts", "projects"])
        guard unknown.isEmpty else { return failure("Unsupported fields: \(unknown.sorted().joined(separator: ", ")).") }
        var hosts: [PortableHost] = []
        if case .array(let entries)? = root["hosts"] {
            guard entries.count <= 1_000 else { return failure("Exports are limited to 1,000 hosts.") }
            for (index, entry) in entries.enumerated() {
                guard case .object(let fields) = entry, Set(fields.keys).isSubset(of: ["id", "name", "destination", "user", "port", "identityFile", "tags"]),
                    case .string(let rawID)? = fields["id"], let reference = UUID(uuidString: rawID),
                    case .string(let name)? = fields["name"], case .string(let destination)? = fields["destination"]
                else { return failure("Host \(index + 1) is malformed.") }
                func text(_ key: String) -> String {
                    if case .string(let value)? = fields[key] { return value }
                    return ""
                }
                var port = ""
                if case .number(let value)? = fields["port"] { port = value.rounded() == value && abs(value) < 1e9 ? String(Int(value)) : "invalid" }
                var tags = ""
                if case .array(let values)? = fields["tags"] {
                    tags = values.compactMap { if case .string(let tag) = $0, !tag.contains(",") { tag } else { nil } }.joined(separator: ",")
                }
                guard !hosts.contains(where: { $0.reference == reference }) else { return failure("Host \(index + 1) repeats a host reference.") }
                hosts.append(PortableHost(reference: reference, draft: HostDraft(name: name, destination: destination, user: text("user"), port: port, identityFile: text("identityFile"), tags: tags)))
            }
        } else if root["hosts"] != nil {
            return failure("hosts must be an array.")
        }
        var projects: [ProjectDefinition] = []
        if case .array(let entries)? = root["projects"] {
            guard entries.count <= 1_000 else { return failure("Exports are limited to 1,000 projects.") }
            for (index, entry) in entries.enumerated() {
                guard let data = try? JSONEncoder().encode(entry) else { return failure("Project \(index + 1) is malformed.") }
                switch ProjectJSON.parse(data) {
                case .success(let project): projects.append(project)
                case .failure(let error): return failure("Project \(index + 1): " + error.problems.joined(separator: " "))
                }
            }
        } else if root["projects"] != nil {
            return failure("projects must be an array.")
        }
        switch LayoutJSON.parse(root["layout"] ?? .object(["version": .number(1), "windows": .array([])]), allowRemoteHosts: true) {
        case .success(let layout): return .success(Parsed(layout: layout, hosts: hosts, projects: projects))
        case .failure(let error): return .failure(error)
        }
    }

    /// Counts, launch references, and collisions. Performs no mutation.
    public static func preview(_ parsed: Parsed, existing: [SavedHost]) -> Preview {
        var preview = Preview()
        preview.windows = parsed.layout.windows.count
        preview.hosts = parsed.hosts.count
        preview.projects = parsed.projects.count
        func reference(_ reference: UUID, _ what: String) {
            let name = parsed.hosts.first { $0.reference == reference }?.draft.name ?? "Missing host \(reference.uuidString)"
            if !preview.hostReferences.contains(name) { preview.hostReferences.append(name) }
            if !parsed.hosts.contains(where: { $0.reference == reference }) {
                preview.errors.append(LayoutIssue(key: nil, "A \(what) refers to a host that is not in this export."))
            }
        }
        // A remote workspace's folders are paths on its host, not on this Mac, so they aren't listed as local folders.
        func walk(_ node: LayoutNode, remote: Bool) {
            switch node {
            case .pane(_, _, let launch):
                preview.panes += 1
                switch launch {
                case .shell(let directory?) where !remote: if !preview.directories.contains(directory) { preview.directories.append(directory) }
                case .shell: break
                case .host(let host): reference(host, "pane")
                }
            case .split(_, _, _, let children): children.forEach { walk($0, remote: remote) }
            }
        }
        for window in parsed.layout.windows {
            preview.tabs += window.tabs.count
            if let host = window.remoteHostID { reference(host, "remote workspace window") }
            window.tabs.forEach { walk($0.root, remote: window.remoteHostID != nil) }
        }
        for (index, host) in parsed.hosts.enumerated() {
            let destination = host.draft.destination.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = host.draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let match: (SavedHost, Collision)? =
                existing.first { $0.destination.caseInsensitiveCompare(destination) == .orderedSame }.map { ($0, .destination) }
                ?? existing.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map { ($0, .name) }
            if let (current, reason) = match {
                preview.collisions.append((index, current.id, reason))
                preview.collisionDetails.append("“\(name)” (\(destination)) matches your “\(current.name)” (\(current.destination))")
            }
            if (try? host.draft.validated(isRegularFile: { _ in true })) == nil {
                preview.errors.append(LayoutIssue(key: nil, "Host \(index + 1) (\(name)) has invalid fields."))
            }
        }
        return preview
    }
}
