import Foundation
import TrellisCore

/// Whether an agent is on one machine (resources.md#agent-definition). This Mac's status comes from its login PATH check;
/// a host's only from a launch there that didn't find it, so it is `missing` or `unknown`.
public struct AgentAvailabilityV2: Sendable, Equatable {
    public enum Status: String, Sendable { case checking, installed, missing, unsupported, unknown }
    /// nil: this Mac; otherwise a remote workspace host.
    public var hostID: UUID?
    public var status: Status
    /// The definition has an installer for the machine's platform that agent.install can run.
    public var installable: Bool
    public init(hostID: UUID? = nil, status: Status, installable: Bool) { self.hostID = hostID; self.status = status; self.installable = installable }

    public var json: JSONValue {
        var object = ResultObjectV2()
        var machine = ResultObjectV2()
        machine.set("kind", hostID == nil ? "local" : "remote")
        machine.set("hostId", hostID)
        object.set("machine", machine.json)
        object.set("status", status.rawValue)
        if status != .installed { object.set("installable", installable) }
        return object.json
    }
}

extension ProjectionV2 {
    // MARK: Agent definition

    /// resources.md#agent-definition: `executable` and the install commands need session.execute; availability lists this
    /// Mac and the hosts the grant can read (host.read and the host in scope), others are left out.
    public func agent(_ definition: AgentDefinition, revision: UInt64, availability: [AgentAvailabilityV2]) -> JSONValue {
        var object = ResultObjectV2()
        object.set("id", definition.id)
        object.set("name", definition.name)
        object.set("builtIn", definition.isBuiltIn)
        object.set("revision", revision)
        object.set("integration", definition.integration.rawValue)
        object.set("resumable", !definition.resumeArguments.isEmpty)
        if capabilities.contains(.sessionExecute) {
            object.set("executable", definition.executable)
            if !definition.install.isEmpty {
                var install: [String: JSONValue] = [:]
                for (platform, recipe) in definition.install {
                    var entry = ResultObjectV2()
                    entry.set("command", recipe.command)
                    if !recipe.requires.isEmpty { entry.set("requires", JSONValue.array(recipe.requires.map(JSONValue.string))) }
                    install[platform] = entry.json
                }
                object.set("install", JSONValue.object(install))
            }
        }
        object.set("availability", JSONValue.array(availability.filter { $0.hostID.map(showsHost) ?? true }.map(\.json)))
        return object.json
    }

    // MARK: Agent run

    /// resources.md#agent-run: the agent the pane's current session runs, or nil. Its ID is the session's.
    public func agentRun(paneID: UUID) -> JSONValue? {
        guard let pane = snapshot.panes[paneID], let agent = runtime.panes[paneID]?.agent else { return nil }
        var object = ResultObjectV2()
        object.set("sessionId", pane.sessionID)
        object.set("paneId", paneID)
        object.set("spaceId", snapshot.tabs[pane.tabID]?.spaceID)
        object.set("agentId", agent.agentID)
        object.set("origin", agent.managed ? "managed" : "detected")
        object.set("state", agent.state.rawValue)
        object.set("since", agent.since)
        object.set("unseen", agent.unseen)
        var settings = ResultObjectV2()
        settings.set("model", agent.settings.model)
        settings.set("effort", agent.settings.effort)
        if !settings.fields.isEmpty { object.set("settings", settings.json) }
        return object.json
    }

    /// Every run in the visible spaces, in sidebar order.
    public func agentRuns(space: UUID? = nil, state: AgentState? = nil) -> [JSONValue] {
        visibleSpaces().filter { space == nil || $0.id == space }.flatMap { space in
            space.tabIDs.compactMap { snapshot.tabs[$0] }.flatMap(\.root.paneIDs).compactMap { id -> JSONValue? in
                guard state == nil || runtime.panes[id]?.agent?.state == state else { return nil }
                return agentRun(paneID: id)
            }
        }
    }
}
