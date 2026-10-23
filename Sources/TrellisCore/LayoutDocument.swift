import Foundation

/// Declarative layout v1: structure and safe launch references only, never
/// commands. Parsed from JSON by the control layer.
public struct LayoutDocument: Equatable, Sendable {
    public var windows: [LayoutWindow]
    public init(windows: [LayoutWindow]) { self.windows = windows }
}

public struct LayoutWindow: Equatable, Sendable {
    public var key: String, name: String, tabs: [LayoutTab]
    public init(key: String, name: String, tabs: [LayoutTab]) { self.key = key; self.name = name; self.tabs = tabs }
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

public enum LayoutResourceKind: String, Codable, Sendable { case window, tab, split, pane }

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
    public static func plan(
        _ document: LayoutDocument, bindings existing: [String: LayoutBinding], snapshot: WorkspaceSnapshot, home: String,
        hostExists: (UUID) -> Bool, directoryExists: (String) -> Bool, keepLiveLaunches: Bool = false, makeID: () -> UUID = { UUID() }
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
        if document.windows.count > 10 { plan.errors.append(LayoutIssue(key: nil, "Use at most 10 windows.")) }
        for window in document.windows {
            checkKey(window.key)
            if window.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || window.name.count > 200 { plan.errors.append(LayoutIssue(key: window.key, "Window names need 1–200 characters.")) }
            if window.tabs.isEmpty || window.tabs.count > 50 { plan.errors.append(LayoutIssue(key: window.key, "Windows need 1–50 tabs.")) }
            for tab in window.tabs {
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
        func launch(_ value: LayoutLaunch) -> SessionLaunch {
            switch value {
            case .shell(let directory): .shell(directory: directory.flatMap { expand($0, home: home) })
            case .host(let id): .host(id)
            }
        }

        var managedWindows: [UUID] = []
        for declared in document.windows {
            let windowID: UUID
            var managedTabs: [UUID] = []
            if let id = bound(declared.key, .window) {
                windowID = id
                if next.windows.first(where: { $0.id == id })?.name != declared.name { plan.updates.append((.window, declared.key)) }
            } else {
                windowID = makeID()
                plan.creates.append((.window, declared.key))
            }
            bindings[declared.key] = LayoutBinding(kind: .window, id: windowID)
            for tab in declared.tabs {
                let tabID: UUID
                let existingTab = bound(tab.key, .tab).flatMap { next.tabs[$0] }
                if let existingTab, existingTab.windowID != windowID {
                    plan.conflicts.append(LayoutIssue(key: tab.key, "Tabs cannot move between windows; close and recreate it instead."))
                    continue
                }
                tabID = existingTab?.id ?? makeID()
                bindings[tab.key] = LayoutBinding(kind: .tab, id: tabID)
                var used = Set<UUID>()
                func build(_ node: LayoutNode) -> PaneLayout? {
                    switch node {
                    case .pane(let key, let title, let desired):
                        let desiredLaunch = launch(desired)
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
                                // Live sessions keep their launch; inactive ones may be reconfigured. Project files
                                // (FR-WF04) leave live panes running where they are instead of conflicting.
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
                guard let root = build(tab.root) else { continue }
                if let existingTab {
                    // Managed tabs are fully declared; unmanaged panes cannot be placed.
                    let leftovers = existingTab.root.paneIDs.filter { !used.contains($0) }
                    if !leftovers.isEmpty {
                        plan.conflicts.append(LayoutIssue(key: tab.key, "This tab has panes the document omits; include them or close them first."))
                        continue
                    }
                    var updated = existingTab
                    let changed = updated.title != tab.title || updated.root != root || (tab.color != nil && updated.color != tab.color)
                    updated.title = tab.title
                    updated.color = tab.color ?? updated.color
                    updated.root = root
                    if !root.paneIDs.contains(updated.activePaneID) { updated.activePaneID = root.paneIDs[0] }
                    next.tabs[tabID] = updated
                    if changed { plan.updates.append((.tab, tab.key)) }
                } else {
                    next.tabs[tabID] = WorkspaceTab(id: tabID, windowID: windowID, title: tab.title, color: tab.color, root: root, activePaneID: root.paneIDs[0])
                    plan.creates.append((.tab, tab.key))
                }
                managedTabs.append(tabID)
            }
            if let index = next.windows.firstIndex(where: { $0.id == windowID }) {
                var window = next.windows[index]
                let unmanaged = window.tabIDs.filter { !managedTabs.contains($0) }
                plan.unmanaged += unmanaged
                // Managed tabs follow document order in the slots they occupied; new ones append.
                var queue = managedTabs.filter { window.tabIDs.contains($0) }
                window.tabIDs =
                    window.tabIDs.map { id in managedTabs.contains(id) && !queue.isEmpty ? queue.removeFirst() : id }
                    + managedTabs.filter { !window.tabIDs.contains($0) }
                window.name = declared.name
                next.windows[index] = window
            } else if let first = managedTabs.first {
                next.windows.append(ManagedWindow(id: windowID, name: declared.name, tabIDs: managedTabs, activeTabID: first))
            }
            managedWindows.append(windowID)
        }
        plan.unmanaged += next.windows.map(\.id).filter { !managedWindows.contains($0) }
        // Managed windows take document order within the slots they already hold.
        let existingIDs = snapshot.windows.map(\.id)
        var queue = managedWindows.filter { existingIDs.contains($0) }
        let reordered = next.windows.map { window in
            managedWindows.contains(window.id) && existingIDs.contains(window.id) && !queue.isEmpty ? queue.removeFirst() : window.id
        }
        let byID = Dictionary(uniqueKeysWithValues: next.windows.map { ($0.id, $0) })
        next.windows = reordered.compactMap { byID[$0] }
        if next.activeWindowID == nil { next.activeWindowID = next.windows.first?.id }
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
        let windows = Set(snapshot.windows.map(\.id)), branches = Set(snapshot.tabs.values.flatMap { branchIDs($0.root) })
        return bindings.filter { _, binding in
            switch binding.kind {
            case .window: windows.contains(binding.id)
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

    static func branchIDs(_ layout: PaneLayout) -> [UUID] {
        guard case .split(let id, _, _, let children) = layout else { return [] }
        return [id] + children.flatMap(branchIDs)
    }
}
