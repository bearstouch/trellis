import Foundation

/// Connection metadata only. Never holds passwords, key contents, or output;
/// `identityFile` is a path reference that OpenSSH reads, not the app.
public struct SavedHost: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var name: String
    /// An SSH config alias or a hostname/IP address.
    public var destination: String
    public var user: String?
    public var port: Int?
    public var identityFile: String?
    public var tags: [String]
    public var revision: UInt64
    /// Advances only when a launch-affecting field (destination, user, port,
    /// identity file) changes. Automation host approvals bind to it.
    public var connectionRevision: UInt64

    public init(id: UUID, draft: HostDraft.Valid, revision: UInt64, connectionRevision: UInt64? = nil) {
        self.id = id; self.revision = revision; self.connectionRevision = connectionRevision ?? revision
        name = draft.name; destination = draft.destination; user = draft.user
        port = draft.port; identityFile = draft.identityFile; tags = draft.tags
    }

    private enum CodingKeys: String, CodingKey { case id, name, destination, user, port, identityFile, tags, revision, connectionRevision }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        destination = try values.decode(String.self, forKey: .destination)
        user = try values.decodeIfPresent(String.self, forKey: .user)
        port = try values.decodeIfPresent(Int.self, forKey: .port)
        identityFile = try values.decodeIfPresent(String.self, forKey: .identityFile)
        tags = try values.decode([String].self, forKey: .tags)
        revision = try values.decode(UInt64.self, forKey: .revision)
        // Files written before S022 have no separate connection revision.
        connectionRevision = try values.decodeIfPresent(UInt64.self, forKey: .connectionRevision) ?? revision
    }

    /// True when both hosts would spawn the same ssh arguments.
    public func sameConnection(as other: SavedHost) -> Bool { connectionLaunch == other.connectionLaunch }

    public var draft: HostDraft {
        HostDraft(
            name: name, destination: destination, user: user ?? "", port: port.map(String.init) ?? "",
            identityFile: identityFile ?? "", tags: tags.joined(separator: ", "))
    }

    /// The launch frozen into a session when it starts. Options precede `--`, so
    /// the destination can never be parsed as an ssh option.
    public var connectionLaunch: SessionLaunch {
        var arguments: [String] = []
        if let port { arguments += ["-p", String(port)] }
        if let user { arguments += ["-l", user] }
        if let identityFile { arguments += ["-i", identityFile] }
        return .process(executable: "/usr/bin/ssh", arguments: arguments + ["--", destination], directory: nil)
    }

    /// Case-insensitive; every whitespace-separated term must match a name,
    /// destination, user, or tag. Input order is preserved.
    public static func search(_ hosts: [SavedHost], query: String) -> [SavedHost] {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return hosts }
        return hosts.filter { host in
            let fields = ([host.name, host.destination, host.user ?? ""] + host.tags).map { $0.lowercased() }
            return terms.allSatisfy { term in fields.contains { $0.contains(term) } }
        }
    }
}

public enum HostField: String, CaseIterable, Sendable { case name, destination, user, port, identityFile, tags }

/// Field-keyed, user-facing errors for the host editor.
public struct HostValidationError: Error, Equatable, Sendable {
    public let fields: [HostField: String]
}

/// Raw text exactly as typed in the editor.
public struct HostDraft: Equatable, Sendable {
    public var name: String
    public var destination: String
    public var user: String
    public var port: String
    public var identityFile: String
    public var tags: String

    public init(name: String = "", destination: String = "", user: String = "", port: String = "", identityFile: String = "", tags: String = "") {
        self.name = name; self.destination = destination; self.user = user
        self.port = port; self.identityFile = identityFile; self.tags = tags
    }

    public struct Valid: Equatable, Sendable {
        public let name: String
        public let destination: String
        public let user: String?
        public let port: Int?
        public let identityFile: String?
        public let tags: [String]
    }

    /// `isRegularFile` checks the identity path without reading its contents.
    public func validated(isRegularFile: (String) -> Bool) throws(HostValidationError) -> Valid {
        var errors: [HostField: String] = [:]
        func hasControl(_ text: String) -> Bool { text.unicodeScalars.contains { $0.properties.generalCategory == .control || $0.value == 0x7F } }
        func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

        let name = trimmed(self.name)
        if name.isEmpty {
            errors[.name] = "Enter a display name."
        } else if name.count > 200 || hasControl(name) {
            errors[.name] = "Use up to 200 characters without control characters."
        }

        let destination = trimmed(self.destination)
        // Hostnames, IPv4/IPv6 literals, and ssh_config alias names. A leading
        // "-" would be read as an option and "@" belongs in the User field.
        let destinationAllowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_:[]%"))
        if destination.isEmpty {
            errors[.destination] = "Enter an SSH alias or hostname."
        } else if destination.hasPrefix("-") {
            errors[.destination] = "A destination cannot start with “-”."
        } else if destination.contains("@") {
            errors[.destination] = "Put the user name in the User field, not the destination."
        } else if destination.utf8.count > 255 || !destination.unicodeScalars.allSatisfy(destinationAllowed.contains) {
            errors[.destination] = "Use letters, digits, “.”, “-”, “_”, or an IP address, without spaces (up to 255 characters)."
        }

        let user = trimmed(self.user)
        if !user.isEmpty {
            // OpenSSH may expand the user into ProxyCommand/Match exec (%r) via a
            // shell, so shell metacharacters are refused like newer ssh does.
            if user.hasPrefix("-") || user.contains(where: { $0.isWhitespace || "@'`\"$;&<>|(){}\\".contains($0) }) || hasControl(user) || user.utf8.count > 255 {
                errors[.user] = "Use a user name without spaces, quotes, “@”, “$”, shell symbols, a leading “-”, or control characters."
            }
        }

        let portText = trimmed(self.port)
        var port: Int?
        if !portText.isEmpty {
            if let value = Int(portText), (1...65535).contains(value), portText.allSatisfy(\.isASCII) {
                port = value
            } else {
                errors[.port] = "Enter a port from 1 to 65535, or leave it empty for the SSH default."
            }
        }

        let identity = trimmed(self.identityFile)
        if !identity.isEmpty {
            if !identity.hasPrefix("/") {
                errors[.identityFile] = "Enter an absolute path, such as /Users/you/.ssh/id_ed25519."
            } else if hasControl(identity) || identity.utf8.count > 1024 || identity.split(separator: "/").contains("..") {
                errors[.identityFile] = "Use a normalized path without “..” or control characters."
            } else if !isRegularFile(identity) {
                errors[.identityFile] = "No readable key file exists at this path."
            }
        }

        var tags: [String] = []
        for raw in self.tags.split(separator: ",") {
            let tag = trimmed(String(raw))
            guard !tag.isEmpty else { continue }
            if tag.count > 64 || hasControl(tag) {
                errors[.tags] = "Tags are comma-separated, up to 64 characters each."
            } else if !tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
                tags.append(tag)
            }
        }
        if tags.count > 32 { errors[.tags] = "Use at most 32 tags." }

        guard errors.isEmpty else { throw HostValidationError(fields: errors) }
        return Valid(
            name: name, destination: destination, user: user.isEmpty ? nil : user, port: port,
            identityFile: identity.isEmpty ? nil : identity, tags: tags)
    }
}
