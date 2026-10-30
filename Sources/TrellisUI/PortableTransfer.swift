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
    public let windows: Int
    public let hostsCreated: Int
    public let hostsReplaced: Int
    public var projectsCreated = 0
}

/// Interactive import/export. Imports always create fresh IDs and stopped
/// panes; nothing is changed until the whole file validates.
@MainActor
public final class PortableTransfer {
    private let model: AppWorkspaceModel
    private let hosts: HostListModel
    private let projects: ProjectListModel?

    public init(model: AppWorkspaceModel, hosts: HostListModel, projects: ProjectListModel? = nil) { self.model = model; self.hosts = hosts; self.projects = projects }

    public func exportData() async -> (data: Data, convertedProcesses: Int) {
        let library = await projects?.library.projects ?? []
        let (document, converted) = PortableDocument.export(snapshot: model.snapshot, hosts: await hosts.library.hosts, projects: library)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return ((try? encoder.encode(document)) ?? Data(), converted)
    }

    public func preview(_ data: Data) async -> Result<(PortableDocument.Parsed, PortableDocument.Preview), PortableImportError> {
        guard data.count <= 4_194_304, let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return .failure(.invalid([LayoutIssue(key: nil, "The file is not valid JSON or is larger than 4 MB.")]))
        }
        switch PortableDocument.parse(value) {
        case .failure(let error): return .failure(.invalid(error.issues))
        case .success(let parsed):
            var preview = PortableDocument.preview(parsed, existing: await hosts.library.hosts)
            let references = Set(parsed.hosts.map(\.reference))
            // Host references are checked by the document preview; this adds the layout limits.
            preview.errors += plan(parsed.layout, hostExists: references.contains).errors.filter { !$0.message.hasPrefix("Saved host ") }
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

    /// Empty bindings: every imported resource gets a fresh ID.
    private func plan(_ layout: LayoutDocument, hostExists: (UUID) -> Bool) -> LayoutPlan {
        LayoutPlanner.plan(
            layout, bindings: [:], snapshot: model.snapshot, home: FileManager.default.homeDirectoryForCurrentUser.path, hostExists: hostExists,
            directoryExists: { path in
                var isDirectory: ObjCBool = false; return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
            })
    }

    /// Validates hosts and layout together, commits hosts atomically, then the
    /// layout; a layout failure reverts the host import. Never starts a process.
    public func commit(_ parsed: PortableDocument.Parsed, policy: HostCollisionPolicy?) async -> Result<PortableImportSummary, PortableImportError> {
        let existing = await hosts.library.hosts
        let preview = PortableDocument.preview(parsed, existing: existing)
        guard preview.errors.isEmpty else { return .failure(.invalid(preview.errors)) }
        guard preview.collisions.isEmpty || policy != nil else { return .failure(.decisionRequired) }
        var changes = HostLibrary.ImportChanges()
        var mapping: [UUID: UUID] = [:]
        for (index, host) in parsed.hosts.enumerated() {
            if let collision = preview.collisions.first(where: { $0.imported == index }), let current = existing.first(where: { $0.id == collision.existing }) {
                switch policy {
                case .useExisting?: mapping[host.reference] = current.id
                case .replaceExisting?:
                    guard !changes.replacements.contains(where: { $0.id == current.id }) else {
                        return .failure(.invalid([LayoutIssue(key: nil, "Several imported hosts match your “\(current.name)”; choose another option or keep one of them in the file.")]))
                    }
                    changes.replacements.append((current.id, host.draft, current.revision))
                    mapping[host.reference] = current.id
                default:
                    let id = UUID()
                    changes.creates.append((id, host.draft))
                    mapping[host.reference] = id
                }
            } else {
                let id = UUID()
                changes.creates.append((id, host.draft))
                mapping[host.reference] = id
            }
        }
        func remap(_ node: LayoutNode) -> LayoutNode {
            switch node {
            case .pane(let key, let title, .host(let reference)): .pane(key: key, title: title, launch: .host(mapping[reference] ?? reference))
            case .pane: node
            case .split(let key, let axis, let ratio, let children): .split(key: key, axis: axis, ratio: ratio, children: children.map(remap))
            }
        }
        var layout = parsed.layout
        for window in layout.windows.indices {
            for tab in layout.windows[window].tabs.indices { layout.windows[window].tabs[tab].root = remap(layout.windows[window].tabs[tab].root) }
            // FR-R02: a remote workspace stays bound to its host, imported or matched like the panes' hosts.
            if let reference = layout.windows[window].remoteHostID { layout.windows[window].remoteHostID = mapping[reference] ?? reference }
        }
        let known = Set(existing.map(\.id)).union(mapping.values)
        let plan = plan(layout, hostExists: known.contains)
        guard plan.errors.isEmpty, plan.conflicts.isEmpty, let target = plan.target else { return .failure(.invalid(plan.errors + plan.conflicts)) }
        let undo: HostLibrary.ImportUndo
        do { undo = try await hosts.library.applyImport(changes) } catch {
            switch error {
            case .invalid(let validation):
                return .failure(.hosts("An imported host is invalid: " + validation.fields.values.sorted().joined(separator: " ") + " Nothing was imported."))
            case .conflict: return .failure(.hosts("Your hosts changed while importing. Nothing was imported; try again."))
            default: return .failure(.hosts("Saved hosts could not be updated. Nothing was imported."))
            }
        }
        if !parsed.layout.windows.isEmpty {
            do {
                _ = try await model.automationExecute(.applyLayout(target: target), expecting: .workspace(revision: plan.baseRevision))
            } catch {
                let reverted = (try? await hosts.library.revertImport(undo)) != nil
                await hosts.load()
                return .failure(
                    .workspace(
                        reverted
                            ? "The workspace changed while importing. Nothing was imported; try again."
                            : "The workspace changed while importing, and the imported hosts could not be removed. Review Saved Hosts."))
            }
        }
        await hosts.load()
        var summary = PortableImportSummary(windows: parsed.layout.windows.count, hostsCreated: changes.creates.count, hostsReplaced: changes.replacements.count)
        // Projects come last and are added together; they never replace one you have, so a failure here keeps what was imported.
        if let projects, !parsed.projects.isEmpty {
            await projects.library.load()
            guard let created = try? await projects.library.createAll(parsed.projects) else {
                return .failure(.workspace("Windows and hosts were imported, but the project library could not be written, so the file's projects weren't added."))
            }
            await projects.load()
            summary.projectsCreated = created.count
        }
        return .success(summary)
    }
}
