import Foundation
import TrellisControl
import TrellisCore

/// How imported hosts that match an existing host are handled. There is no
/// default: a collision always needs an explicit choice.
public enum HostCollisionPolicy: String, CaseIterable, Sendable {
    case useExisting, keepBoth, replaceExisting

    public var title: String {
        switch self {
        case .useExisting: "Use my existing hosts"
        case .keepBoth: "Keep both (import as new hosts)"
        case .replaceExisting: "Replace my existing hosts"
        }
    }
}

public enum PortableImportError: Error, Equatable, Sendable {
    case invalid([LayoutIssue])
    case decisionRequired
    case hosts(String)
    case workspace(String)

    public var message: String {
        switch self {
        case .invalid(let issues): issues.map(\.message).joined(separator: " ")
        case .decisionRequired: "Some imported hosts match hosts you already have. Choose how to handle them."
        case .hosts(let reason), .workspace(let reason): reason
        }
    }
}

public struct PortableImportSummary: Equatable, Sendable {
    public let hostsCreated: Int
    public let hostsReplaced: Int
    public var projectsCreated = 0
    /// Windows in a version 1 file, which are not imported.
    public var skippedSpaces = 0
}

/// Interactive import/export of projects and saved hosts (FR-R02). Imports always create fresh IDs; nothing is
/// changed until the whole file validates, and a failure leaves nothing half-imported.
@MainActor
public final class PortableTransfer {
    private let hosts: HostListModel
    private let projects: ProjectListModel?

    public init(hosts: HostListModel, projects: ProjectListModel? = nil) { self.hosts = hosts; self.projects = projects }

    public func exportData() async -> Data {
        let document = PortableDocument.export(hosts: await hosts.library.hosts, projects: await projects?.library.projects ?? [])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(document)) ?? Data()
    }

    public func preview(_ data: Data) async -> Result<(PortableDocument.Parsed, PortableDocument.Preview), PortableImportError> {
        guard data.count <= 4_194_304, let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return .failure(.invalid([LayoutIssue(key: nil, "The file is not valid JSON or is larger than 4 MB.")]))
        }
        switch PortableDocument.parse(value) {
        case .failure(let error): return .failure(.invalid(error.issues))
        case .success(let parsed):
            var preview = PortableDocument.preview(parsed, existing: await hosts.library.hosts, existingProjects: await projects?.library.projects ?? [])
            // Commit requires identity files to exist here; surface that before Import.
            for host in parsed.hosts {
                let path = host.draft.identityFile.trimmingCharacters(in: .whitespacesAndNewlines)
                var isDirectory: ObjCBool = false
                if !path.isEmpty, !(FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue) {
                    preview.errors.append(LayoutIssue(key: nil, "“\(host.draft.name)” uses identity file \(path), which does not exist on this Mac."))
                }
            }
            return .success((parsed, preview))
        }
    }

    /// Commits hosts atomically, then projects in one write; a project failure reverts the host import. Never starts a
    /// process or opens a space.
    public func commit(_ parsed: PortableDocument.Parsed, policy: HostCollisionPolicy?) async -> Result<PortableImportSummary, PortableImportError> {
        let existing = await hosts.library.hosts
        let preview = PortableDocument.preview(parsed, existing: existing)
        guard preview.errors.isEmpty else { return .failure(.invalid(preview.errors)) }
        guard preview.collisions.isEmpty || policy != nil else { return .failure(.decisionRequired) }
        var changes = HostLibrary.ImportChanges()
        for (index, host) in parsed.hosts.enumerated() {
            if let collision = preview.collisions.first(where: { $0.imported == index }), let current = existing.first(where: { $0.id == collision.existing }) {
                switch policy {
                case .useExisting?: continue
                case .replaceExisting?:
                    guard !changes.replacements.contains(where: { $0.id == current.id }) else {
                        return .failure(.invalid([LayoutIssue(key: nil, "Several imported hosts match your “\(current.name)”; choose another option or keep one of them in the file.")]))
                    }
                    changes.replacements.append((current.id, host.draft, current.revision))
                default: changes.creates.append((UUID(), host.draft))
                }
            } else {
                changes.creates.append((UUID(), host.draft))
            }
        }
        let undo: HostLibrary.ImportUndo
        do { undo = try await hosts.library.applyImport(changes) } catch {
            switch error {
            case .invalid(let validation):
                return .failure(.hosts("An imported host is invalid: " + validation.fields.values.sorted().joined(separator: " ") + " Nothing was imported."))
            case .conflict: return .failure(.hosts("Your hosts changed while importing. Nothing was imported; try again."))
            default: return .failure(.hosts("Saved hosts could not be updated. Nothing was imported."))
            }
        }
        var summary = PortableImportSummary(hostsCreated: changes.creates.count, hostsReplaced: changes.replacements.count, skippedSpaces: parsed.skippedSpaces)
        // Projects never replace one you have: a project named like an existing one is added as "… (imported)".
        if let projects, !parsed.projects.isEmpty {
            await projects.library.load()
            var taken = Set(await projects.library.projects.map { $0.name.lowercased() })
            let renamed = parsed.projects.map { project in
                var copy = project
                copy.name = PortableDocument.importedName(project.name, taken: taken)
                taken.insert(copy.name.lowercased())
                return copy
            }
            guard let created = try? await projects.library.createAll(renamed) else {
                let reverted = (try? await hosts.library.revertImport(undo)) != nil
                await hosts.load()
                return .failure(
                    .workspace(
                        reverted
                            ? "The project library could not be written. Nothing was imported."
                            : "The project library could not be written, and the imported hosts could not be removed. Review Saved Hosts."))
            }
            await projects.load()
            summary.projectsCreated = created.count
        }
        await hosts.load()
        return .success(summary)
    }
}
