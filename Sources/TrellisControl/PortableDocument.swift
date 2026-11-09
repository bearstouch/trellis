import Foundation
import TrellisCore

/// Versioned, portable exchange of the project library and saved-host metadata (FR-R02). Spaces are what a project
/// becomes when loaded, so they are not exported. It never contains runtime IDs, output, environment values, tokens,
/// key contents, or the folders a project was launched in.
///
/// Version 1 (from before windows were renamed spaces) also carried a layout of windows; it is still read, its hosts and
/// projects are imported, and its windows are skipped and counted.
public enum PortableDocument {
    public static let format = "trellis.portable"
    public static let version = 2

    public struct PortableHost: Equatable, Sendable {
        /// The host's reference inside this document only (version 1 layouts point at it); never a host ID of this Mac.
        public let reference: UUID
        public let draft: HostDraft
    }

    public struct Parsed: Equatable, Sendable {
        public let hosts: [PortableHost]
        /// Library projects (FR-PL05), without identity or launch history; each gets a new identity on import.
        public var projects: [ProjectDefinition] = []
        /// Windows in a version 1 file, which are not imported.
        public var skippedSpaces = 0
    }

    public enum Collision: Equatable, Sendable {
        case name, destination
    }

    public struct Preview: Equatable, Sendable {
        public var hosts = 0, projects = 0, skippedSpaces = 0
        /// Imported host index → existing host it collides with.
        public var collisions: [(imported: Int, existing: UUID, reason: Collision)] = []
        /// One line per collision naming both hosts, so the policy is chosen knowingly.
        public var collisionDetails: [String] = []
        /// Imported projects named like one you have; they are kept as copies named "… (imported)".
        public var projectCollisions: [String] = []
        public var errors: [LayoutIssue] = []

        public static func == (a: Self, b: Self) -> Bool {
            a.hosts == b.hosts && a.projects == b.projects && a.skippedSpaces == b.skippedSpaces
                && a.collisions.map { "\($0.imported)\($0.existing)\($0.reason)" } == b.collisions.map { "\($0.imported)\($0.existing)\($0.reason)" }
                && a.collisionDetails == b.collisionDetails && a.projectCollisions == b.projectCollisions && a.errors == b.errors
        }
    }

    // MARK: Export

    /// Exports every saved host and every library project.
    public static func export(hosts: [SavedHost], projects: [ProjectDefinition]) -> JSONValue {
        let hostList: JSONValue = .array(
            hosts.map { host in
                var object: [String: JSONValue] = ["name": .string(host.name), "destination": .string(host.destination), "tags": .array(host.tags.map(JSONValue.string))]
                if let user = host.user { object["user"] = .string(user) }
                if let port = host.port { object["port"] = .number(Double(port)) }
                if let identity = host.identityFile { object["identityFile"] = .string(identity) }
                return .object(object)
            })
        // In the library's JSON form; folders a project was launched in belong to this Mac and its hosts, so they stay.
        let projectList = projects.compactMap { try? JSONDecoder().decode(JSONValue.self, from: ProjectJSON.encode($0)) }
        return .object(["format": .string(format), "version": .number(Double(version)), "hosts": hostList, "projects": .array(projectList)])
    }

    // MARK: Import

    public static func parse(_ value: JSONValue) -> Result<Parsed, LayoutParseError> {
        func failure(_ message: String) -> Result<Parsed, LayoutParseError> { .failure(LayoutParseError(issues: [LayoutIssue(key: nil, message)])) }
        guard case .object(let root) = value else { return failure("The file is not a Trellis export.") }
        guard root["format"] == .string(format) else { return failure("The file is not a Trellis portable export.") }
        guard case .number(let fileVersion)? = root["version"], fileVersion == 1 || fileVersion == Double(version) else {
            return failure("This export uses an unsupported version. Update Trellis to import it.")
        }
        let legacy = fileVersion == 1
        let unknown = Set(root.keys).subtracting(legacy ? ["format", "version", "layout", "hosts", "projects"] : ["format", "version", "hosts", "projects"])
        guard unknown.isEmpty else { return failure("Unsupported fields: \(unknown.sorted().joined(separator: ", ")).") }
        var hosts: [PortableHost] = []
        if case .array(let entries)? = root["hosts"] {
            guard entries.count <= 1_000 else { return failure("Exports are limited to 1,000 hosts.") }
            for (index, entry) in entries.enumerated() {
                guard case .object(let fields) = entry, Set(fields.keys).isSubset(of: ["id", "name", "destination", "user", "port", "identityFile", "tags"]),
                    case .string(let name)? = fields["name"], case .string(let destination)? = fields["destination"]
                else { return failure("Host \(index + 1) is malformed.") }
                // Version 1 layouts refer to hosts by `id`; version 2 has nothing that refers to them.
                var reference = UUID()
                if let raw = fields["id"] {
                    guard case .string(let text) = raw, let id = UUID(uuidString: text) else { return failure("Host \(index + 1) is malformed.") }
                    guard !hosts.contains(where: { $0.reference == id }) else { return failure("Host \(index + 1) repeats a host reference.") }
                    reference = id
                } else if legacy {
                    return failure("Host \(index + 1) is malformed.")
                }
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
        var parsed = Parsed(hosts: hosts, projects: projects)
        if legacy {
            // The windows aren't imported, but a malformed file is still refused rather than half-read.
            switch LayoutJSON.parse(root["layout"] ?? .object(["version": .number(1), "windows": .array([])]), allowRemoteHosts: true) {
            case .success(let layout): parsed.skippedSpaces = layout.spaces.count
            case .failure(let error): return .failure(error)
            }
        }
        return .success(parsed)
    }

    /// Counts and collisions. Performs no mutation.
    public static func preview(_ parsed: Parsed, existing: [SavedHost], existingProjects: [ProjectDefinition] = []) -> Preview {
        var preview = Preview()
        preview.hosts = parsed.hosts.count
        preview.projects = parsed.projects.count
        preview.skippedSpaces = parsed.skippedSpaces
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
        let names = Set(existingProjects.map { $0.name.lowercased() })
        preview.projectCollisions = parsed.projects.map(\.name).filter { names.contains($0.lowercased()) }
        return preview
    }

    /// The name an imported project gets when one you have is already called that; at most 200 characters.
    public static func importedName(_ name: String, taken: Set<String>) -> String {
        guard taken.contains(name.lowercased()) else { return name }
        let suffix = " (imported)"
        var candidate = String(name.prefix(200 - suffix.count)) + suffix, number = 2
        while taken.contains(candidate.lowercased()) {
            let numbered = " (imported \(number))"
            candidate = String(name.prefix(200 - numbered.count)) + numbered; number += 1
        }
        return candidate
    }
}
