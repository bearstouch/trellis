import Foundation

public struct SessionLaunchRequest: Equatable, Sendable {
    public let sessionID: UUID
    public let paneID: UUID
    public let attemptID: UUID
    public let launch: SessionLaunch
}

public enum LaunchOutcome: Equatable, Sendable {
    case started(processID: Int32)
    case failed(message: String)
}

public enum WorkspaceEffect: Equatable, Sendable {
    case start(SessionLaunchRequest)
}

/// Both UI and automation use this command boundary. No command performs I/O.
public enum WorkspaceCommand: Sendable {
    case createWindow(name: String)
    /// A window bound to a saved host (FR-RW01); its panes run that host's login shell.
    case createRemoteWindow(name: String, hostID: UUID)
    case renameWindow(id: UUID, name: String)
    case closeAllWindows
    case selectWindow(id: UUID)
    case reorderWindows(ids: [UUID])
    case deleteWindow(id: UUID)
    case recordSessionExit(sessionID: UUID, code: Int32?)
    case markSessionClosing(sessionID: UUID)
    case restartSession(paneID: UUID)
    case configureStoppedSession(paneID: UUID, launch: SessionLaunch)
    case splitPane(id: UUID, axis: SplitAxis, availableSize: TerminalSize)
    case deletePane(id: UUID)
    case selectPane(id: UUID)
    case resizeSplit(tabID: UUID, splitID: UUID, ratio: Double, canvas: CanvasDimensions)
    case createTab(windowID: UUID)
    case selectTab(id: UUID)
    case reorderTabs(windowID: UUID, ids: [UUID])
    case duplicateTab(id: UUID)
    case deleteTab(id: UUID)
    case renameTab(id: UUID, title: String)
    /// nil removes the label.
    case setTabColor(id: UUID, color: TabColor?)
    case replaceTabLayout(id: UUID, root: PaneLayout)
    case startSession(paneID: UUID, resolvedLaunch: SessionLaunch? = nil)
    case completeLaunch(sessionID: UUID, attemptID: UUID, outcome: LaunchOutcome)
    /// A restored stopped session whose process the broker kept running (FR-R03). No attempt, nothing is spawned.
    case adoptRunningSession(sessionID: UUID, processID: Int32)
    /// Declarative layout target computed by `LayoutPlanner` from this store's
    /// state. The store re-checks that nothing is deleted and live sessions are untouched.
    case applyLayout(target: WorkspaceSnapshot)
}

/// Optimistic concurrency for one resource, checked atomically with the command.
public enum ResourceExpectation: Equatable, Sendable {
    case window(UUID, revision: UInt64)
    case tab(UUID, revision: UInt64)
    /// The whole collection (for example window order).
    case workspace(revision: UInt64)

    /// Throws `notFound` or `conflict` when `snapshot` does not match.
    public func verify(in snapshot: WorkspaceSnapshot) throws {
        switch self {
        case .window(let id, let revision):
            guard let window = snapshot.windows.first(where: { $0.id == id }) else { throw WorkspaceError.notFound }
            guard window.revision == revision else { throw WorkspaceError.conflict(expected: revision, actual: window.revision) }
        case .tab(let id, let revision):
            guard let tab = snapshot.tabs[id] else { throw WorkspaceError.notFound }
            guard tab.revision == revision else { throw WorkspaceError.conflict(expected: revision, actual: tab.revision) }
        case .workspace(let revision):
            guard revision == snapshot.revision else { throw WorkspaceError.conflict(expected: revision, actual: snapshot.revision) }
        }
    }
}

public struct WorkspaceCommandResult: Equatable, Sendable {
    public let snapshot: WorkspaceSnapshot
    public let effects: [WorkspaceEffect]
    public let createdWindowID: UUID?
    public let createdTabID: UUID?
    public let createdPaneID: UUID?
}

public actor WorkspaceStore {
    private var state: WorkspaceSnapshot
    private let makeID: @Sendable () -> UUID
    private let now: @Sendable () -> Date

    public init(
        snapshot: WorkspaceSnapshot = WorkspaceSnapshot(),
        makeID: @escaping @Sendable () -> UUID = { UUID() },
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        try snapshot.validate()
        self.state = snapshot
        self.makeID = makeID
        self.now = now
    }

    public func restoreStoppedSnapshot(_ snapshot: WorkspaceSnapshot) throws {
        guard state.windows.isEmpty, snapshot.sessions.values.allSatisfy({ $0.state == .stopped }) else { throw WorkspaceError.invalidTransition }
        try snapshot.validate()
        state = snapshot
    }

    public func snapshot() -> WorkspaceSnapshot { state }

    public func execute(_ command: WorkspaceCommand, expectedRevision: UInt64? = nil, expecting: ResourceExpectation? = nil) throws -> WorkspaceCommandResult {
        if let expectedRevision, expectedRevision != state.revision {
            throw WorkspaceError.conflict(expected: expectedRevision, actual: state.revision)
        }
        try expecting?.verify(in: state)
        guard state.revision < UInt64.max else { throw WorkspaceError.revisionExhausted }
        var next = state
        next.revision += 1
        var effects: [WorkspaceEffect] = []
        var createdWindowID: UUID?
        var createdTabID: UUID?
        var createdPaneID: UUID?
        switch command {
        case .createWindow(let rawName), .createRemoteWindow(let rawName, _):
            let name = try validatedName(rawName)
            let windowID = makeID(), tabID = makeID(), paneID = makeID(), sessionID = makeID()
            var remoteHostID: UUID?
            if case .createRemoteWindow(_, let hostID) = command { remoteHostID = hostID }
            let window = ManagedWindow(id: windowID, name: name, tabIDs: [tabID], activeTabID: tabID, revision: next.revision, remoteHostID: remoteHostID)
            next.windows.append(window)
            next.tabs[tabID] = WorkspaceTab(id: tabID, windowID: windowID, title: WorkspaceTab.defaultTitle, root: .pane(paneID), activePaneID: paneID, revision: next.revision)
            next.panes[paneID] = WorkspacePane(id: paneID, tabID: tabID, sessionID: sessionID)
            next.sessions[sessionID] = WorkspaceSession(id: sessionID, launch: window.defaultLaunch, createdAt: now())
            next.activeWindowID = windowID
            createdWindowID = windowID
        case .closeAllWindows:
            guard !next.sessions.values.contains(where: { [.starting, .running, .closing].contains($0.state) }) else {
                throw WorkspaceError.invalidTransition
            }
            next.windows = []
            next.tabs = [:]
            next.panes = [:]
            next.sessions = [:]
            next.activeWindowID = nil
        case .selectWindow(let id):
            guard next.windows.contains(where: { $0.id == id }) else { throw WorkspaceError.notFound }
            guard next.activeWindowID != id else { return unchanged() }
            next.activeWindowID = id
        case .reorderWindows(let order):
            guard order.count == next.windows.count, Set(order).count == order.count,
                Set(order) == Set(next.windows.map(\.id))
            else {
                throw WorkspaceError.invalidState("Window order must contain every window exactly once")
            }
            guard order != next.windows.map(\.id) else { return unchanged() }
            let windows = Dictionary(uniqueKeysWithValues: next.windows.map { ($0.id, $0) })
            next.windows = order.compactMap { windows[$0] }
        case .deleteWindow(let id):
            guard let index = next.windows.firstIndex(where: { $0.id == id }) else { throw WorkspaceError.notFound }
            let window = next.windows[index]
            let paneIDs = window.tabIDs.flatMap { next.tabs[$0]?.root.paneIDs ?? [] }
            let sessionIDs = paneIDs.compactMap { next.panes[$0]?.sessionID }
            guard
                sessionIDs.allSatisfy({ sessionID in
                    guard let session = next.sessions[sessionID] else { return false }
                    return ![SessionState.starting, .running, .closing].contains(session.state)
                })
            else { throw WorkspaceError.invalidTransition }
            for sessionID in sessionIDs { next.sessions.removeValue(forKey: sessionID) }
            for paneID in paneIDs { next.panes.removeValue(forKey: paneID) }
            for tabID in window.tabIDs { next.tabs.removeValue(forKey: tabID) }
            next.windows.remove(at: index)
            if next.activeWindowID == id {
                next.activeWindowID = next.windows.isEmpty ? nil : next.windows[min(index, next.windows.count - 1)].id
            }
        case .markSessionClosing(let id):
            guard var session = next.sessions[id] else { throw WorkspaceError.notFound }
            guard session.state != .closing else { return unchanged() }
            guard session.state == .running else { throw WorkspaceError.invalidTransition }
            session.state = .closing
            next.sessions[id] = session
        case .configureStoppedSession(let paneID, let launch):
            guard let pane = next.panes[paneID], var session = next.sessions[pane.sessionID] else { throw WorkspaceError.notFound }
            guard session.state == .stopped else { throw WorkspaceError.invalidTransition }
            session.launch = launch
            next.sessions[session.id] = session
        case .restartSession(let paneID):
            guard var pane = next.panes[paneID], let old = next.sessions[pane.sessionID] else { throw WorkspaceError.notFound }
            guard old.state == .exited || old.state == .failed else { throw WorkspaceError.invalidTransition }
            let sessionID = makeID()
            next.sessions.removeValue(forKey: old.id)
            next.sessions[sessionID] = WorkspaceSession(id: sessionID, launch: old.launch, createdAt: now())
            pane.sessionID = sessionID
            next.panes[paneID] = pane
        case .recordSessionExit(let id, let code):
            guard var session = next.sessions[id] else { throw WorkspaceError.notFound }
            if session.state == .exited { return unchanged() }
            guard session.state == .running || session.state == .closing else { throw WorkspaceError.invalidTransition }
            session.state = .exited
            session.processID = nil
            session.exitCode = code
            session.endedAt = now()
            next.sessions[id] = session
        case .renameWindow(let id, let rawName):
            guard let index = next.windows.firstIndex(where: { $0.id == id }) else { throw WorkspaceError.notFound }
            let name = try validatedName(rawName)
            guard name != next.windows[index].name else { return unchanged() }
            next.windows[index].name = name
            next.windows[index].revision = next.revision
        case .splitPane(let id, let axis, let available):
            guard let pane = next.panes[id], var tab = next.tabs[pane.tabID] else { throw WorkspaceError.notFound }
            guard available.columns >= (axis == .x ? 40 : 20), available.rows >= (axis == .y ? 10 : 5) else {
                throw WorkspaceError.invalidState("Split requires at least 20 columns and 5 rows for each pane")
            }
            let newPaneID = makeID(), sessionID = makeID()
            tab.root = tab.root.splitting(paneID: id, branchID: makeID(), newPaneID: newPaneID, axis: axis)
            tab.activePaneID = newPaneID
            tab.revision = next.revision
            next.tabs[tab.id] = tab
            next.panes[newPaneID] = WorkspacePane(id: newPaneID, tabID: tab.id, sessionID: sessionID, profileID: pane.profileID)
            let launch = next.windows.first { $0.id == tab.windowID }?.defaultLaunch ?? .shell(directory: nil)
            next.sessions[sessionID] = WorkspaceSession(id: sessionID, launch: launch, createdAt: now())
            createdPaneID = newPaneID
        case .resizeSplit(let tabID, let splitID, let ratio, let canvas):
            guard var tab = next.tabs[tabID] else { throw WorkspaceError.notFound }
            guard ratio.isFinite, (0.1...0.9).contains(ratio), canvas.width.isFinite, canvas.height.isFinite,
                canvas.width > 0, canvas.height > 0
            else { throw WorkspaceError.invalidState("Invalid divider allocation") }
            guard PaneGeometry(layout: tab.root, canvas: canvas).branches[splitID] != nil else { throw WorkspaceError.notFound }
            let root = tab.root.resizing(splitID: splitID, ratio: ratio)
            let minimum = CanvasDimensions.minimum(for: root)
            guard canvas.width + 0.001 >= minimum.width, canvas.height + 0.001 >= minimum.height else {
                throw WorkspaceError.invalidState("Divider allocation would make a pane smaller than 20 columns by 5 rows")
            }
            guard root != tab.root else { return unchanged() }
            tab.root = root
            tab.revision = next.revision
            next.tabs[tabID] = tab
        case .selectPane(let id):
            guard let pane = next.panes[id], var tab = next.tabs[pane.tabID] else { throw WorkspaceError.notFound }
            guard tab.activePaneID != id else { return unchanged() }
            tab.activePaneID = id
            tab.revision = next.revision
            next.tabs[tab.id] = tab
        case .deletePane(let id):
            guard let pane = next.panes[id], var tab = next.tabs[pane.tabID], let session = next.sessions[pane.sessionID] else { throw WorkspaceError.notFound }
            guard ![SessionState.starting, .running, .closing].contains(session.state) else { throw WorkspaceError.invalidTransition }
            guard let root = tab.root.removing(paneID: id) else {
                // The single leaf owns its tab; reuse the tab/window cascade below.
                return try execute(.deleteTab(id: tab.id), expectedRevision: expectedRevision)
            }
            next.panes.removeValue(forKey: id)
            next.sessions.removeValue(forKey: pane.sessionID)
            if tab.activePaneID == id { tab.activePaneID = tab.root.siblingPaneID(whenRemoving: id) ?? root.paneIDs[0] }
            tab.root = root
            tab.revision = next.revision
            next.tabs[tab.id] = tab
        case .createTab(let windowID):
            guard let index = next.windows.firstIndex(where: { $0.id == windowID }) else { throw WorkspaceError.notFound }
            let tabID = makeID(), paneID = makeID(), sessionID = makeID()
            next.tabs[tabID] = WorkspaceTab(id: tabID, windowID: windowID, title: WorkspaceTab.defaultTitle, root: .pane(paneID), activePaneID: paneID, revision: next.revision)
            next.panes[paneID] = WorkspacePane(id: paneID, tabID: tabID, sessionID: sessionID)
            next.sessions[sessionID] = WorkspaceSession(id: sessionID, launch: next.windows[index].defaultLaunch, createdAt: now())
            next.windows[index].tabIDs.append(tabID)
            next.windows[index].activeTabID = tabID
            next.windows[index].revision = next.revision
            createdTabID = tabID
        case .selectTab(let id):
            guard let tab = next.tabs[id], let index = next.windows.firstIndex(where: { $0.id == tab.windowID }) else { throw WorkspaceError.notFound }
            guard next.windows[index].activeTabID != id else { return unchanged() }
            next.windows[index].activeTabID = id
            next.windows[index].revision = next.revision
        case .reorderTabs(let windowID, let order):
            guard let index = next.windows.firstIndex(where: { $0.id == windowID }) else { throw WorkspaceError.notFound }
            let existing = next.windows[index].tabIDs
            guard order.count == existing.count, Set(order).count == order.count, Set(order) == Set(existing) else {
                throw WorkspaceError.invalidState("Tab order must contain each tab in this window exactly once")
            }
            guard existing != order else { return unchanged() }
            next.windows[index].tabIDs = order
            next.windows[index].revision = next.revision
        case .duplicateTab(let id):
            guard let original = next.tabs[id], let index = next.windows.firstIndex(where: { $0.id == original.windowID }) else { throw WorkspaceError.notFound }
            let newTabID = makeID()
            var mapping: [UUID: UUID] = [:]
            func clone(_ layout: PaneLayout) throws -> PaneLayout {
                switch layout {
                case .pane(let oldID):
                    guard let oldPane = next.panes[oldID], let oldSession = next.sessions[oldPane.sessionID] else { throw WorkspaceError.notFound }
                    let paneID = makeID(), sessionID = makeID()
                    mapping[oldID] = paneID
                    next.panes[paneID] = WorkspacePane(id: paneID, tabID: newTabID, sessionID: sessionID, profileID: oldPane.profileID, title: oldPane.title)
                    next.sessions[sessionID] = WorkspaceSession(id: sessionID, launch: oldSession.launch, createdAt: now())
                    return .pane(paneID)
                case .split(_, let axis, let ratio, let children):
                    return .split(id: makeID(), axis: axis, ratio: ratio, children: try children.map(clone))
                }
            }
            let root = try clone(original.root)
            guard let activePane = mapping[original.activePaneID] else { throw WorkspaceError.notFound }
            next.tabs[newTabID] = WorkspaceTab(id: newTabID, windowID: original.windowID, title: original.title, color: original.color, root: root, activePaneID: activePane, revision: next.revision)
            let position = next.windows[index].tabIDs.firstIndex(of: id) ?? next.windows[index].tabIDs.count - 1
            next.windows[index].tabIDs.insert(newTabID, at: position + 1)
            next.windows[index].activeTabID = newTabID
            next.windows[index].revision = next.revision
            createdTabID = newTabID
        case .deleteTab(let id):
            guard let tab = next.tabs[id], let index = next.windows.firstIndex(where: { $0.id == tab.windowID }),
                let position = next.windows[index].tabIDs.firstIndex(of: id)
            else { throw WorkspaceError.notFound }
            let paneIDs = tab.root.paneIDs
            let sessionIDs = paneIDs.compactMap { next.panes[$0]?.sessionID }
            guard sessionIDs.allSatisfy({ ![SessionState.starting, .running, .closing].contains(next.sessions[$0]!.state) }) else { throw WorkspaceError.invalidTransition }
            for session in sessionIDs { next.sessions.removeValue(forKey: session) }
            for pane in paneIDs { next.panes.removeValue(forKey: pane) }
            next.tabs.removeValue(forKey: id)
            next.windows[index].tabIDs.remove(at: position)
            if next.windows[index].tabIDs.isEmpty {
                let windowID = next.windows.remove(at: index).id
                if next.activeWindowID == windowID { next.activeWindowID = next.windows.isEmpty ? nil : next.windows[min(index, next.windows.count - 1)].id }
            } else {
                if next.windows[index].activeTabID == id {
                    next.windows[index].activeTabID = next.windows[index].tabIDs[min(position, next.windows[index].tabIDs.count - 1)]
                }
                next.windows[index].revision = next.revision
            }
        case .renameTab(let id, let rawTitle):
            guard var tab = next.tabs[id] else { throw WorkspaceError.notFound }
            let title = try validatedName(rawTitle)
            guard title != tab.title else { return unchanged() }
            tab.title = title
            tab.revision = next.revision
            next.tabs[id] = tab
        case .setTabColor(let id, let color):
            guard var tab = next.tabs[id] else { throw WorkspaceError.notFound }
            guard color != tab.color else { return unchanged() }
            tab.color = color
            tab.revision = next.revision
            next.tabs[id] = tab
        case .replaceTabLayout(let id, let root):
            guard var tab = next.tabs[id] else { throw WorkspaceError.notFound }
            guard tab.root != root else { return unchanged() }
            tab.root = root
            tab.revision = next.revision
            next.tabs[id] = tab
        case .startSession(let paneID, let resolvedLaunch):
            guard let pane = next.panes[paneID], var session = next.sessions[pane.sessionID] else { throw WorkspaceError.notFound }
            guard session.state == .stopped else { throw WorkspaceError.invalidTransition }
            let attempt = makeID()
            session.state = .starting
            if let resolvedLaunch { session.launch = resolvedLaunch }
            session.launchAttemptID = attempt
            next.sessions[session.id] = session
            effects = [.start(SessionLaunchRequest(sessionID: session.id, paneID: paneID, attemptID: attempt, launch: session.launch))]
        case .applyLayout(let target):
            // Reapplying an identical document changes nothing and keeps revisions.
            guard target != state else { return unchanged() }
            let keptWindows = Set(next.windows.map(\.id)).isSubset(of: Set(target.windows.map(\.id)))
            guard keptWindows, Set(next.tabs.keys).isSubset(of: Set(target.tabs.keys)), Set(next.panes.keys).isSubset(of: Set(target.panes.keys)),
                Set(next.sessions.keys).isSubset(of: Set(target.sessions.keys))
            else { throw WorkspaceError.invalidState("A layout apply cannot delete resources") }
            for (id, session) in target.sessions {
                if let current = next.sessions[id] {
                    // Runtime ownership never changes; only an inactive launch may.
                    let live = [SessionState.starting, .running, .closing].contains(current.state)
                    guard session.state == current.state, session.processID == current.processID, session.launchAttemptID == current.launchAttemptID,
                        session.exitCode == current.exitCode, !live || session.launch == current.launch
                    else { throw WorkspaceError.invalidTransition }
                } else {
                    guard session.state == .stopped, session.processID == nil, session.launchAttemptID == nil else { throw WorkspaceError.invalidTransition }
                }
            }
            for (id, pane) in target.panes {
                if let current = next.panes[id], current.tabID != pane.tabID || current.sessionID != pane.sessionID { throw WorkspaceError.invalidTransition }
            }
            for (id, tab) in target.tabs { if let current = next.tabs[id], current.windowID != tab.windowID { throw WorkspaceError.invalidTransition } }
            guard target.activeWindowID == nil || target.windows.contains(where: { $0.id == target.activeWindowID }) else { throw WorkspaceError.invalidTransition }
            for window in target.windows {
                if let current = next.windows.first(where: { $0.id == window.id }), current.remoteHostID != window.remoteHostID {
                    throw WorkspaceError.invalidState("A window's remote host never changes")
                }
            }
            var applied = target
            // A layout written for local panes runs on the host when it lands in a remote workspace (FR-RW10).
            for window in applied.windows {
                guard let host = window.remoteHostID else { continue }
                for paneID in window.tabIDs.flatMap({ applied.tabs[$0]?.root.paneIDs ?? [] }) {
                    guard let sessionID = applied.panes[paneID]?.sessionID, next.sessions[sessionID] == nil,
                        case .shell(let directory)? = applied.sessions[sessionID]?.launch
                    else { continue }
                    applied.sessions[sessionID]?.launch = .remoteShell(hostID: host, directory: directory)
                }
            }
            applied.revision = next.revision
            for index in applied.windows.indices where next.windows.first(where: { $0.id == applied.windows[index].id }).map({ $0 != applied.windows[index] }) ?? true {
                applied.windows[index].revision = next.revision
            }
            for (id, tab) in applied.tabs where next.tabs[id].map({ $0 != tab }) ?? true { applied.tabs[id]?.revision = next.revision }
            next = applied
        case .adoptRunningSession(let id, let pid):
            guard var session = next.sessions[id] else { throw WorkspaceError.notFound }
            guard session.state == .stopped, session.launchAttemptID == nil else { throw WorkspaceError.invalidTransition }
            guard pid > 0 else { throw WorkspaceError.invalidState("Invalid process ID") }
            session.state = .running
            session.processID = pid
            session.exitCode = nil
            session.startedAt = now()
            next.sessions[id] = session
        case .completeLaunch(let id, let attempt, let outcome):
            guard var session = next.sessions[id] else { throw WorkspaceError.notFound }
            guard session.state == .starting, session.launchAttemptID == attempt else { throw WorkspaceError.staleLaunch }
            session.launchAttemptID = nil
            switch outcome {
            case .started(let pid):
                guard pid > 0 else { throw WorkspaceError.invalidState("Invalid process ID") }
                session.state = .running
                session.processID = pid
                session.startedAt = now()
            case .failed(let message):
                session.state = .failed
                session.failureMessage = message
                session.endedAt = now()
            }
            next.sessions[id] = session
        }
        try next.validate()
        state = next
        return WorkspaceCommandResult(snapshot: next, effects: effects, createdWindowID: createdWindowID, createdTabID: createdTabID, createdPaneID: createdPaneID)
    }

    /// Runs `command` and an optional follow-up derived from its result as one
    /// unit: if the follow-up fails, the first command is rolled back too.
    public func execute(
        _ command: WorkspaceCommand, expecting: ResourceExpectation? = nil, then follow: @Sendable (WorkspaceCommandResult) -> WorkspaceCommand?
    ) throws -> WorkspaceCommandResult {
        let saved = state
        let first = try execute(command, expecting: expecting)
        guard let next = follow(first) else { return first }
        do {
            let second = try execute(next)
            return WorkspaceCommandResult(
                snapshot: second.snapshot, effects: first.effects + second.effects, createdWindowID: first.createdWindowID, createdTabID: first.createdTabID,
                createdPaneID: first.createdPaneID)
        } catch {
            state = saved
            throw error
        }
    }

    private func unchanged() -> WorkspaceCommandResult {
        WorkspaceCommandResult(snapshot: state, effects: [], createdWindowID: nil, createdTabID: nil, createdPaneID: nil)
    }

    private func validatedName(_ name: String) throws -> String {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 200 else { throw WorkspaceError.invalidState("Name must contain 1...200 characters") }
        return value
    }
}

/// A shared facade; effect execution belongs to the session manager, never the
/// store actor. Callers must feed outcomes back with the matching attempt ID.
public struct WorkspaceCommandService: Sendable {
    public let store: WorkspaceStore
    public init(store: WorkspaceStore) { self.store = store }

    public func execute(_ command: WorkspaceCommand, expectedRevision: UInt64? = nil, expecting: ResourceExpectation? = nil) async throws
        -> WorkspaceCommandResult
    {
        try await store.execute(command, expectedRevision: expectedRevision, expecting: expecting)
    }

    public func execute(
        _ command: WorkspaceCommand, expecting: ResourceExpectation? = nil, then follow: @escaping @Sendable (WorkspaceCommandResult) -> WorkspaceCommand?
    ) async throws -> WorkspaceCommandResult {
        try await store.execute(command, expecting: expecting, then: follow)
    }
}
