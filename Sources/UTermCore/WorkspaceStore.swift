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
    case renameWindow(id: UUID, name: String)
    case closeAllWindows
    case selectWindow(id: UUID)
    case reorderWindows(ids: [UUID])
    case deleteWindow(id: UUID)
    case recordSessionExit(sessionID: UUID, code: Int32?)
    case renameTab(id: UUID, title: String)
    case replaceTabLayout(id: UUID, root: PaneLayout)
    case startSession(paneID: UUID)
    case completeLaunch(sessionID: UUID, attemptID: UUID, outcome: LaunchOutcome)
}

public struct WorkspaceCommandResult: Equatable, Sendable {
    public let snapshot: WorkspaceSnapshot
    public let effects: [WorkspaceEffect]
    public let createdWindowID: UUID?
}

public actor WorkspaceStore {
    private var state: WorkspaceSnapshot
    private let makeID: @Sendable () -> UUID
    private let now: @Sendable () -> Date

    public init(snapshot: WorkspaceSnapshot = WorkspaceSnapshot(),
                makeID: @escaping @Sendable () -> UUID = { UUID() },
                now: @escaping @Sendable () -> Date = { Date() }) throws {
        try snapshot.validate()
        self.state = snapshot
        self.makeID = makeID
        self.now = now
    }

    public func snapshot() -> WorkspaceSnapshot { state }

    public func execute(_ command: WorkspaceCommand, expectedRevision: UInt64? = nil) throws -> WorkspaceCommandResult {
        if let expectedRevision, expectedRevision != state.revision {
            throw WorkspaceError.conflict(expected: expectedRevision, actual: state.revision)
        }
        guard state.revision < UInt64.max else { throw WorkspaceError.revisionExhausted }
        var next = state
        next.revision += 1
        var effects: [WorkspaceEffect] = []
        var createdWindowID: UUID?
        switch command {
        case .createWindow(let rawName):
            let name = try validatedName(rawName)
            let windowID = makeID(), tabID = makeID(), paneID = makeID(), sessionID = makeID()
            let window = ManagedWindow(id: windowID, name: name, tabIDs: [tabID], activeTabID: tabID, revision: next.revision)
            next.windows.append(window)
            next.tabs[tabID] = WorkspaceTab(id: tabID, windowID: windowID, title: "Terminal", root: .pane(paneID), activePaneID: paneID, revision: next.revision)
            next.panes[paneID] = WorkspacePane(id: paneID, tabID: tabID, sessionID: sessionID)
            next.sessions[sessionID] = WorkspaceSession(id: sessionID, createdAt: now())
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
                  Set(order) == Set(next.windows.map(\.id)) else {
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
            guard sessionIDs.allSatisfy({ sessionID in
                guard let session = next.sessions[sessionID] else { return false }
                return ![SessionState.starting, .running, .closing].contains(session.state)
            }) else { throw WorkspaceError.invalidTransition }
            for sessionID in sessionIDs { next.sessions.removeValue(forKey: sessionID) }
            for paneID in paneIDs { next.panes.removeValue(forKey: paneID) }
            for tabID in window.tabIDs { next.tabs.removeValue(forKey: tabID) }
            next.windows.remove(at: index)
            if next.activeWindowID == id {
                next.activeWindowID = next.windows.isEmpty ? nil : next.windows[min(index, next.windows.count - 1)].id
            }
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
        case .renameTab(let id, let rawTitle):
            guard var tab = next.tabs[id] else { throw WorkspaceError.notFound }
            let title = try validatedName(rawTitle)
            guard title != tab.title else { return unchanged() }
            tab.title = title
            tab.revision = next.revision
            next.tabs[id] = tab
        case .replaceTabLayout(let id, let root):
            guard var tab = next.tabs[id] else { throw WorkspaceError.notFound }
            guard tab.root != root else { return unchanged() }
            tab.root = root
            tab.revision = next.revision
            next.tabs[id] = tab
        case .startSession(let paneID):
            guard let pane = next.panes[paneID], var session = next.sessions[pane.sessionID] else { throw WorkspaceError.notFound }
            guard session.state == .stopped else { throw WorkspaceError.invalidTransition }
            let attempt = makeID()
            session.state = .starting
            session.launchAttemptID = attempt
            next.sessions[session.id] = session
            effects = [.start(SessionLaunchRequest(sessionID: session.id, paneID: paneID, attemptID: attempt, launch: session.launch))]
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
        return WorkspaceCommandResult(snapshot: next, effects: effects, createdWindowID: createdWindowID)
    }

    private func unchanged() -> WorkspaceCommandResult {
        WorkspaceCommandResult(snapshot: state, effects: [], createdWindowID: nil)
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

    public func execute(_ command: WorkspaceCommand, expectedRevision: UInt64? = nil) async throws -> WorkspaceCommandResult {
        try await store.execute(command, expectedRevision: expectedRevision)
    }
}
