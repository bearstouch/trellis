import Foundation
import TrellisCore

/// Revisions for panes and sessions (API2-02: every resource has one that increases on every change). The store versions
/// spaces and tabs; panes and sessions are versioned here, on the main actor, from each published snapshot. One counter
/// serves both, so a revision only ever grows. A pane changes with its record, its place or focus in the tab, and
/// maximizing; a session with its record (state, launch, times, exit). Live status (shell marks, attention, agents)
/// doesn't count, as it doesn't for tabs. Runtime only: revisions start again after a relaunch.
struct AutomationRevisions: Equatable {
    private(set) var panes: [UUID: UInt64] = [:]
    private(set) var sessions: [UUID: UInt64] = [:]
    private var counter: UInt64 = 0

    private mutating func next() -> UInt64 {
        counter += 1
        return counter
    }

    mutating func record(_ previous: WorkspaceSnapshot, _ next: WorkspaceSnapshot) {
        for (id, pane) in next.panes {
            let before = previous.panes[id]
            let oldTab = before.flatMap { previous.tabs[$0.tabID] }, newTab = next.tabs[pane.tabID]
            let placeChanged = oldTab?.root != newTab?.root || (oldTab?.activePaneID == id) != (newTab?.activePaneID == id)
            if panes[id] == nil || before != pane || placeChanged { panes[id] = self.next() }
        }
        for (id, session) in next.sessions where sessions[id] == nil || previous.sessions[id] != session { sessions[id] = self.next() }
        if panes.count != next.panes.count { panes = panes.filter { next.panes[$0.key] != nil } }
        if sessions.count != next.sessions.count { sessions = sessions.filter { next.sessions[$0.key] != nil } }
    }

    /// Panes that were or became maximized changed; panes already gone are left out.
    mutating func maximizedChanged(from old: [UUID: UUID], to new: [UUID: UUID]) {
        for id in Set(old.values).symmetricDifference(Set(new.values)) where panes[id] != nil { panes[id] = next() }
    }
}
