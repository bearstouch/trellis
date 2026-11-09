import Foundation

/// Declarative layout v1: structure and safe launch references only, never
/// commands. Parsed from JSON by the control layer.
public struct LayoutDocument: Equatable, Sendable {
    public var spaces: [LayoutSpace]
    public init(spaces: [LayoutSpace]) { self.spaces = spaces }
}

public struct LayoutSpace: Equatable, Sendable {
    public var key: String, name: String, tabs: [LayoutTab]
    /// A remote workspace's saved host (FR-R02, FR-RW01); only exports carry it, never API layouts.
    public var remoteHostID: UUID?
    public init(key: String, name: String, tabs: [LayoutTab], remoteHostID: UUID? = nil) {
        self.key = key; self.name = name; self.tabs = tabs; self.remoteHostID = remoteHostID
    }
}

public struct LayoutTab: Equatable, Sendable {
    public var key: String, title: String, root: LayoutNode
    /// Nil leaves an existing tab's label alone, so API layouts never wipe one (FR-T04).
    public var color: TabColor?
    public init(key: String, title: String, color: TabColor? = nil, root: LayoutNode) { self.key = key; self.title = title; self.color = color; self.root = root }
}

public enum LayoutLaunch: Equatable, Sendable {
    /// `directory` is as written: absolute, `~`, or `~/…`.
    case shell(directory: String?)
    case host(UUID)
}

public indirect enum LayoutNode: Equatable, Sendable {
    case pane(key: String, title: String?, launch: LayoutLaunch)
    case split(key: String, axis: SplitAxis, ratio: Double, children: [LayoutNode])

    public var key: String {
        switch self {
        case .pane(let key, _, _), .split(let key, _, _, _): key
        }
    }
}

public enum LayoutResourceKind: String, Codable, Sendable {
    case space, tab, split, pane

    /// Bindings saved before windows were renamed spaces say `window`; they still bind the same space.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let kind = Self(rawValue: raw == "window" ? "space" : raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown layout resource kind")
        }
        self = kind
    }
}

/// A namespace's key → resource mapping; keys never change resource type.
public struct LayoutBinding: Codable, Equatable, Sendable {
    public let kind: LayoutResourceKind
    public let id: UUID
    public init(kind: LayoutResourceKind, id: UUID) { self.kind = kind; self.id = id }
}

public struct LayoutIssue: Equatable, Sendable {
    public let key: String?
    public let message: String
    public init(key: String?, _ message: String) { self.key = key; self.message = message }
    /// `key: message`, or the message alone, as error messages show it.
    public var text: String { (key.map { "\($0): " } ?? "") + message }
}

public struct LayoutPlan: Equatable, Sendable {
    public let baseRevision: UInt64
    public var errors: [LayoutIssue] = []
    public var warnings: [LayoutIssue] = []
    public var conflicts: [LayoutIssue] = []
    public var creates: [(kind: LayoutResourceKind, key: String)] = []
    public var updates: [(kind: LayoutResourceKind, key: String)] = []
    public var unmanaged: [UUID] = []
    /// The full post-apply state; nil when the plan has errors or conflicts.
    public var target: WorkspaceSnapshot?
    public var bindings: [String: LayoutBinding] = [:]
    /// Created panes in document order, for optional `startNew`.
    public var createdPanes: [(key: String, id: UUID)] = []

    public var canApply: Bool { errors.isEmpty && conflicts.isEmpty && target != nil }

    public static func == (a: Self, b: Self) -> Bool {
        a.baseRevision == b.baseRevision && a.errors == b.errors && a.warnings == b.warnings && a.conflicts == b.conflicts
            && a.creates.map { "\($0.kind)\($0.key)" } == b.creates.map { "\($0.kind)\($0.key)" }
            && a.updates.map { "\($0.kind)\($0.key)" } == b.updates.map { "\($0.kind)\($0.key)" } && a.unmanaged == b.unmanaged
            && a.target == b.target && a.bindings == b.bindings && a.createdPanes.map(\.id) == b.createdPanes.map(\.id)
    }
}

public enum LayoutPlanner {
    public static let maxNesting = 16
    public static let maxPanes = 100

    /// Key pattern from the v1 schema.
    public static func isValidKey(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first, key.utf8.count <= 64 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return CharacterSet.alphanumerics.contains(first) && first.isASCII && key.unicodeScalars.allSatisfy(allowed.contains)
    }

    /// `~` only as the whole first segment; absolute otherwise; no expansion syntax.
    public static func expand(_ directory: String, home: String) -> String? {
        guard !directory.isEmpty, directory.utf8.count <= 4096,
            !directory.unicodeScalars.contains(where: { "$`".unicodeScalars.contains($0) || $0.properties.generalCategory == .control }),
            !directory.split(separator: "/").contains("..")
        else { return nil }
        if directory == "~" { return home }
        if directory.hasPrefix("~/") { return home + directory.dropFirst() }
        return directory.hasPrefix("/") ? directory : nil
    }

    /// Validates the document and reconciles it with `snapshot` under the
    /// namespace `bindings`. Never mutates; the target is applied atomically.
    /// `keepOmittedPanes` leaves a bound tab's live panes the document omits where they are (project launches, FR-PL08).
    /// `projectID` is set by project launches (FR-W08): its spaces record the project, and the tabs it declares their key,
    /// so any other tab in such a space reads as temporary.
    public static func plan(
        _ document: LayoutDocument, bindings existing: [String: LayoutBinding], snapshot: WorkspaceSnapshot, home: String,
        hostExists: (UUID) -> Bool, directoryExists: (String) -> Bool, keepLiveLaunches: Bool = false, keepOmittedPanes: Bool = false,
        remoteHostID: UUID? = nil, projectID: UUID? = nil, makeID: () -> UUID = { UUID() }
    ) -> LayoutPlan {
        var plan = LayoutPlan(baseRevision: snapshot.revision)
        // Structural validation first; nothing is reconciled on errors.
        var seen = Set<String>(), panes = 0
        func check(_ node: LayoutNode, depth: Int) {
            guard depth <= maxNesting else { plan.errors.append(LayoutIssue(key: node.key, "Split nesting exceeds \(maxNesting).")); return }
            checkKey(node.key)
            switch node {
            case .pane(let key, let title, let launch):
                panes += 1
                if let title, title.count > 200 { plan.errors.append(LayoutIssue(key: key, "Pane titles are limited to 200 characters.")) }
                switch launch {
                case .shell(let directory?):
                    if let path = expand(directory, home: home) {
                        if !directoryExists(path) { plan.warnings.append(LayoutIssue(key: key, "Directory \(directory) does not exist yet; starting will fail until it does.")) }
                    } else {
                        plan.errors.append(LayoutIssue(key: key, "Use an absolute directory or one starting with ~/; relative paths and shell expansion are not allowed."))
                    }
                case .shell(nil): break
                case .host(let id): if !hostExists(id) { plan.errors.append(LayoutIssue(key: key, "Saved host \(id.uuidString) does not exist.")) }
                }
            case .split(let key, _, let ratio, let children):
                if !(ratio.isFinite && (0.1...0.9).contains(ratio)) { plan.errors.append(LayoutIssue(key: key, "Ratios must be within 0.1–0.9.")) }
                if children.count != 2 { plan.errors.append(LayoutIssue(key: key, "A split needs exactly two children.")) }
                children.forEach { check($0, depth: depth + 1) }
            }
        }
        func checkKey(_ key: String) {
            if !isValidKey(key) { plan.errors.append(LayoutIssue(key: key, "Keys must match ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$.")) }
            if !seen.insert(key).inserted { plan.errors.append(LayoutIssue(key: key, "Keys must be unique across the document.")) }
        }
        if document.spaces.count > 10 { plan.errors.append(LayoutIssue(key: nil, "Use at most 10 spaces.")) }
        for space in document.spaces {
            checkKey(space.key)
            if space.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || space.name.count > 200 { plan.errors.append(LayoutIssue(key: space.key, "Space names need 1–200 characters.")) }
            if space.tabs.isEmpty || space.tabs.count > 50 { plan.errors.append(LayoutIssue(key: space.key, "Spaces need 1–50 tabs.")) }
            for tab in space.tabs {
                checkKey(tab.key)
                if tab.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || tab.title.count > 200 { plan.errors.append(LayoutIssue(key: tab.key, "Tab titles need 1–200 characters.")) }
                check(tab.root, depth: 0)
            }
        }
        if panes > maxPanes { plan.errors.append(LayoutIssue(key: nil, "Layouts are limited to \(maxPanes) panes.")) }
        guard plan.errors.isEmpty else { return plan }

        var next = snapshot
        var bindings = live(existing, in: snapshot)
        func bound(_ key: String, _ kind: LayoutResourceKind) -> UUID? {
            guard let binding = bindings[key] else { return nil }
            guard binding.kind == kind else {
                plan.conflicts.append(LayoutIssue(key: key, "This key was a \(binding.kind.rawValue); a key cannot change resource type."))
                return nil
            }
            return binding.id
        }
        // A remote space's layout opens on its host (FR-RW10): every shell is that host's, in a path there.
        func launch(_ value: LayoutLaunch, on host: UUID?) -> SessionLaunch {
            switch value {
            case .shell(let directory) where host != nil: .remoteShell(hostID: host!, directory: directory.flatMap { expand($0, home: home) })
            case .shell(let directory): .shell(directory: directory.flatMap { expand($0, home: home) })
            case .host(let id): .host(id)
            }
        }

        var managedSpaces: [UUID] = []
        for declared in document.spaces {
            let spaceID: UUID
            var managedTabs: [UUID] = []
            if let id = bound(declared.key, .space) {
                spaceID = id
                if next.spaces.first(where: { $0.id == id })?.name != declared.name { plan.updates.append((.space, declared.key)) }
            } else {
                spaceID = makeID()
                plan.creates.append((.space, declared.key))
            }
            bindings[declared.key] = LayoutBinding(kind: .space, id: spaceID)
            // An existing space keeps its own binding; a new one takes the document's, or the plan's.
            let spaceHost = next.spaces.first { $0.id == spaceID }.map(\.remoteHostID) ?? declared.remoteHostID ?? remoteHostID
            for tab in declared.tabs {
                let tabID: UUID
                let existingTab = bound(tab.key, .tab).flatMap { next.tabs[$0] }
                if let existingTab, existingTab.spaceID != spaceID {
                    plan.conflicts.append(LayoutIssue(key: tab.key, "Tabs cannot move between spaces; close and recreate it instead."))
                    continue
                }
                tabID = existingTab?.id ?? makeID()
                bindings[tab.key] = LayoutBinding(kind: .tab, id: tabID)
                var used = Set<UUID>()
                func build(_ node: LayoutNode) -> PaneLayout? {
                    switch node {
                    case .pane(let key, let title, let desired):
                        let desiredLaunch = launch(desired, on: spaceHost)
                        if let id = bound(key, .pane), let pane = next.panes[id] {
                            guard pane.tabID == tabID else {
                                plan.conflicts.append(LayoutIssue(key: key, "Panes cannot move between tabs; close and recreate it instead."))
                                return nil
                            }
                            used.insert(id)
                            var updated = pane
                            updated.title = title
                            var changed = pane.title != title
                            if var session = next.sessions[pane.sessionID], !sameLaunch(session.launch, desiredLaunch) {
                                // Live sessions keep their launch; inactive ones may be reconfigured. Project launches
                                // (FR-PL08) leave live panes running where they are instead of conflicting.
                                if [.stopped, .exited, .failed].contains(session.state) {
                                    session.launch = desiredLaunch
                                    next.sessions[session.id] = session
                                    changed = true
                                } else if !keepLiveLaunches {
                                    plan.conflicts.append(
                                        LayoutIssue(key: key, "This pane's session is \(session.state.rawValue); its launch cannot change. Close and recreate it instead."))
                                    return .pane(id)
                                }
                            }
                            next.panes[id] = updated
                            if changed { plan.updates.append((.pane, key)) }
                            bindings[key] = LayoutBinding(kind: .pane, id: id)
                            return .pane(id)
                        }
                        let id = makeID(), sessionID = makeID()
                        next.panes[id] = WorkspacePane(id: id, tabID: tabID, sessionID: sessionID, title: title)
                        next.sessions[sessionID] = WorkspaceSession(id: sessionID, launch: desiredLaunch)
                        used.insert(id)
                        bindings[key] = LayoutBinding(kind: .pane, id: id)
                        plan.creates.append((.pane, key))
                        plan.createdPanes.append((key, id))
                        return .pane(id)
                    case .split(let key, let axis, let ratio, let children):
                        let built = children.compactMap(build)
                        guard built.count == 2 else { return nil }
                        // A split ID is reused only inside its own tab, so IDs never repeat across tabs.
                        let id = bound(key, .split).flatMap { id in existingTab.map { branchIDs($0.root).contains(id) } == true ? id : nil } ?? makeID()
                        bindings[key] = LayoutBinding(kind: .split, id: id)
                        return .split(id: id, axis: axis, ratio: ratio, children: built)
                    }
                }
                guard var root = build(tab.root) else { continue }
                if let existingTab {
                    // Managed tabs are fully declared, unless omitted panes may stay where they are.
                    let leftovers = existingTab.root.paneIDs.filter { !used.contains($0) }
                    if !leftovers.isEmpty {
                        guard keepOmittedPanes, let merged = merging(root, into: existingTab.root) else {
                            plan.conflicts.append(LayoutIssue(key: tab.key, "This tab has panes the document omits; include them or close them first."))
                            continue
                        }
                        root = merged
                    }
                    var updated = existingTab
                    let projectKey = projectID == nil ? updated.projectKey : tab.key
                    let changed =
                        updated.title != tab.title || updated.root != root || (tab.color != nil && updated.color != tab.color) || updated.projectKey != projectKey
                    updated.title = tab.title
                    updated.color = tab.color ?? updated.color
                    updated.root = root
                    updated.projectKey = projectKey
                    if !root.paneIDs.contains(updated.activePaneID) { updated.activePaneID = root.paneIDs[0] }
                    next.tabs[tabID] = updated
                    if changed { plan.updates.append((.tab, tab.key)) }
                } else {
                    next.tabs[tabID] = WorkspaceTab(
                        id: tabID, spaceID: spaceID, title: tab.title, color: tab.color, root: root, activePaneID: root.paneIDs[0], projectKey: projectID.map { _ in tab.key })
                    plan.creates.append((.tab, tab.key))
                }
                managedTabs.append(tabID)
            }
            if let index = next.spaces.firstIndex(where: { $0.id == spaceID }) {
                var space = next.spaces[index]
                let unmanaged = space.tabIDs.filter { !managedTabs.contains($0) }
                plan.unmanaged += unmanaged
                // A tab the project no longer declares stays where it is but becomes temporary (FR-W08).
                if projectID != nil { for id in unmanaged where next.tabs[id]?.projectKey != nil { next.tabs[id]?.projectKey = nil } }
                // Managed tabs follow document order in the slots they occupied; new ones append.
                var queue = managedTabs.filter { space.tabIDs.contains($0) }
                space.tabIDs =
                    space.tabIDs.map { id in managedTabs.contains(id) && !queue.isEmpty ? queue.removeFirst() : id }
                    + managedTabs.filter { !space.tabIDs.contains($0) }
                space.name = declared.name
                if let projectID, space.projectID != projectID {
                    space.projectID = projectID
                    if !plan.updates.contains(where: { $0.kind == .space && $0.key == declared.key }) { plan.updates.append((.space, declared.key)) }
                }
                next.spaces[index] = space
            } else if let first = managedTabs.first {
                next.spaces.append(Space(id: spaceID, name: declared.name, tabIDs: managedTabs, activeTabID: first, remoteHostID: spaceHost, projectID: projectID))
            }
            managedSpaces.append(spaceID)
        }
        plan.unmanaged += next.spaces.map(\.id).filter { !managedSpaces.contains($0) }
        // Managed spaces take document order within the slots they already hold.
        let existingIDs = snapshot.spaces.map(\.id)
        var queue = managedSpaces.filter { existingIDs.contains($0) }
        let reordered = next.spaces.map { space in
            managedSpaces.contains(space.id) && existingIDs.contains(space.id) && !queue.isEmpty ? queue.removeFirst() : space.id
        }
        let byID = Dictionary(uniqueKeysWithValues: next.spaces.map { ($0.id, $0) })
        next.spaces = reordered.compactMap { byID[$0] }
        if next.activeSpaceID == nil { next.activeSpaceID = next.spaces.first?.id }
        guard plan.conflicts.isEmpty else { return plan }
        guard next.panes.count <= maxPanes else {
            plan.conflicts.append(LayoutIssue(key: nil, "Applying would exceed \(maxPanes) panes in the workspace."))
            return plan
        }
        plan.bindings = bindings
        plan.target = next
        return plan
    }

    /// Bindings whose resources still exist; the rest are pruned.
    public static func live(_ bindings: [String: LayoutBinding], in snapshot: WorkspaceSnapshot) -> [String: LayoutBinding] {
        let spaces = Set(snapshot.spaces.map(\.id)), branches = Set(snapshot.tabs.values.flatMap { branchIDs($0.root) })
        return bindings.filter { _, binding in
            switch binding.kind {
            case .space: spaces.contains(binding.id)
            case .tab: snapshot.tabs[binding.id] != nil
            case .pane: snapshot.panes[binding.id] != nil
            case .split: branches.contains(binding.id)
            }
        }
    }

    /// A stored shell launch resolves to `-l` in the default directory on
    /// start; a shell without a directory therefore matches any resolved one.
    public static func sameLaunch(_ actual: SessionLaunch, _ desired: SessionLaunch) -> Bool {
        if actual == desired { return true }
        switch (actual, desired) {
        case (.process(_, let arguments, let directory), .shell(let wanted)): return arguments == ["-l"] && (wanted == nil || directory == wanted)
        default: return false
        }
    }

    /// `live` with `declared` in place of the live panes it names, keeping the other live panes in their
    /// splits. Nil when `declared` doesn't fit around them (it regroups panes the live splits keep apart).
    static func merging(_ declared: PaneLayout, into live: PaneLayout) -> PaneLayout? {
        let livePanes = Set(live.paneIDs)
        func merge(_ live: PaneLayout, _ declared: PaneLayout) -> PaneLayout? {
            let named = Set(declared.paneIDs)
            // A live subtree the document names whole takes its declared subtree, which may add new panes around it.
            if named.intersection(livePanes) == Set(live.paneIDs) { return declared }
            guard case .split(let id, let axis, let ratio, let children) = live, children.count == 2 else { return nil }
            switch (named.isDisjoint(with: children[0].paneIDs), named.isDisjoint(with: children[1].paneIDs)) {
            case (true, false): return merge(children[1], declared).map { .split(id: id, axis: axis, ratio: ratio, children: [children[0], $0]) }
            case (false, true): return merge(children[0], declared).map { .split(id: id, axis: axis, ratio: ratio, children: [$0, children[1]]) }
            case (false, false):
                guard case .split(let declaredID, let declaredAxis, let declaredRatio, let parts) = declared, parts.count == 2,
                    let first = merge(children[0], parts[0]), let second = merge(children[1], parts[1])
                else { return nil }
                return .split(id: declaredID, axis: declaredAxis, ratio: declaredRatio, children: [first, second])
            case (true, true): return nil
            }
        }
        guard let merged = merge(live, declared) else { return nil }
        let panes = merged.paneIDs, branches = branchIDs(merged)
        // Every pane once, and a reused split ID never doubles up with one kept around an omitted pane.
        guard Set(panes).count == panes.count, Set(panes) == livePanes.union(declared.paneIDs), Set(branches).count == branches.count else { return nil }
        return merged
    }

    static func branchIDs(_ layout: PaneLayout) -> [UUID] {
        guard case .split(let id, _, _, let children) = layout else { return [] }
        return [id] + children.flatMap(branchIDs)
    }
}
