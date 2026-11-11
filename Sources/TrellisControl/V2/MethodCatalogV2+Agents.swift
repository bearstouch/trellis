import Foundation
import TrellisCore

/// Phase 5 of the catalog (docs/api/v2/methods.md#agents): agent definitions, runs, starting, answering and installing.
extension MethodCatalogV2 {
    private static let agentID = ParamV2("agentId", .string(maxBytes: 64), required: true, "The agent definition's ID, as agent.list names it.")
    private static let sessionID = ParamV2("sessionId", .uuid, required: true, "The agent run's session.")
    static let agentStateNames = ["ready", "working", "needsInput", "done", "error"]

    /// Where an agent runs (methods.md#agents). The machine is the space's or the pane's: a remote workspace runs it on its host.
    static let agentPlacement = ParamV2(
        "placement",
        .structure(
            ObjectSchemaV2(
                [
                    ParamV2("kind", .string(values: ["tab", "split", "pane"]), "A new tab, a split beside a pane, or a pane that isn't running."),
                    ParamV2("spaceId", .uuid, "The space that gets a new tab."),
                    ParamV2("paneId", .uuid, "The pane to split, or the stopped, exited or failed pane the agent runs in."),
                    ParamV2("axis", .string(values: ["x", "y"]), "x splits left/right (default), y top/bottom.")
                ], tag: "kind",
                variants: [
                    .init("tab", allowed: ["spaceId"], required: ["spaceId"]), .init("split", allowed: ["paneId", "axis"], required: ["paneId"]),
                    .init("pane", allowed: ["paneId"], required: ["paneId"])
                ])), required: true, "Where the agent runs; the machine is that space's or pane's.")
    private static let placementRules = [ResourceRuleV2(.space, "placement.spaceId"), ResourceRuleV2(.pane, "placement.paneId")]
    /// The space that gets the tab, or the pane that is split or used.
    private static let placementRevision = RevisionTargetV2.anyResource(["placement.spaceId", "placement.paneId"])

    private static let machine = ParamV2(
        "machine",
        .structure(
            ObjectSchemaV2(
                [ParamV2("kind", .string(values: ["local", "remote"]), "This Mac, or a remote workspace host."), ParamV2("hostId", .uuid, "The host (needs host.read).")],
                tag: "kind", variants: [.init("local"), .init("remote", allowed: ["hostId"], required: ["hostId"])])), "Only this machine's availability.")

    static let agents: [MethodSpecV2] = [
        MethodSpecV2(
            "agent.list", "Agent definitions with their availability on this Mac and on the remote workspace hosts in scope.", params: [machine],
            capabilities: [.workspaceRead], conditional: [ConditionalCapabilityV2(.hostRead, if: .present("machine.hostId"))],
            resources: [ResourceRuleV2(.host, "machine.hostId")], paginated: true),
        MethodSpecV2(
            "agent.get", "One agent definition with its availability.", params: [ParamV2("id", .string(maxBytes: 64), required: true, "The agent definition's ID.")],
            capabilities: [.workspaceRead], errors: [.notFound]),
        MethodSpecV2(
            "agent.runs", "Agents running in panes in scope, started as agent panes or typed in a shell, in sidebar order.",
            params: [ParamV2("spaceId", .uuid, "Only this space's runs."), ParamV2("state", .string(values: agentStateNames), "Only runs in this state.")],
            capabilities: [.workspaceRead], resources: [ResourceRuleV2(.space, "spaceId")]),
        MethodSpecV2(
            "agent.start", "Start an agent in a new tab, a split or a pane that isn't running, on that space's machine.",
            params: [
                agentID, agentPlacement, ParamV2("directory", .string(maxBytes: 4_096), "Absolute folder to start in (needs session.execute); default the pane's folder."),
                ParamV2("resume", .boolean, "Continue the agent's last conversation in that folder.")
            ], capabilities: [.agentControl, .workspaceWrite], conditional: [ConditionalCapabilityV2(.sessionExecute, if: .present("directory"))],
            resources: [ResourceRuleV2(.agent, "agentId")] + placementRules, effect: .mutating(revision: placementRevision),
            errors: [.invalidState, .launchFailed, .agentUnavailable]),
        MethodSpecV2(
            "agent.restart", "Start an agent pane again with a new session, after its agent exited; resume continues its last conversation.",
            params: [sessionID, ParamV2("resume", .boolean, "Continue the agent's last conversation.")], capabilities: [.agentControl],
            resources: [ResourceRuleV2(.session, "sessionId")], effect: .mutating(revision: .resource(param: "sessionId")),
            errors: [.invalidState, .launchFailed, .agentUnavailable]),
        MethodSpecV2(
            "agent.respond", "Answer an agent that needs input: approve (1 and Return), reject (Escape) or reply (text and Return).",
            params: [
                sessionID, ParamV2("action", .string(values: ["approve", "reject", "reply"]), required: true, "approve, reject or reply."),
                ParamV2("text", .string(maxBytes: 16_384), "reply only: one line of text, without control characters."),
                ParamV2("expectedState", .string(values: agentStateNames), "Answer only while the run is in this state; default needsInput.")
            ], anyOf: [[.agentRespond, .sessionInput]], resources: [ResourceRuleV2(.session, "sessionId")],
            effect: .mutating(revision: .resource(param: "sessionId"), destructive: true), errors: [.invalidState, .remoteDisconnected]),
        MethodSpecV2(
            "agent.install", "Run an agent's installer in a pane on that space's machine, then the agent, as the app's Install and Launch does.",
            params: [agentID, agentPlacement], capabilities: [.agentInstall, .sessionExecute, .agentControl, .workspaceWrite],
            resources: [ResourceRuleV2(.agent, "agentId")] + placementRules, effect: .mutating(revision: placementRevision),
            errors: [.invalidState, .launchFailed, .agentUnavailable])
    ]
}
