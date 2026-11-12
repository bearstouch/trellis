import Foundation
import TrellisCore

/// The catalog's remote workspaces (docs/api/methods.md#remote-workspaces): remote workspaces and the helper on each host.
/// Each may wait on the host or on the person, so the socket answers them out of order (`waits`).
extension MethodCatalogV2 {
    private static let hostID = ParamV2("hostId", .uuid, required: true, "The saved host; it must be in the grant's host scope at its current connection.")
    private static let hostRule = ResourceRuleV2(.host, "hostId")
    private static let remoteErrors: Set<APIErrorCode> = [.invalidState, .confirmationRequired, .remoteDisconnected]

    static let remote: [MethodSpecV2] = [
        MethodSpecV2(
            "remote.open", "Open a saved host as a remote workspace space; with start, connect first and start its shell on the host.",
            params: [
                hostID, ParamV2("name", .string(maxBytes: 800), "Space name, 1–200 characters; default the host's name."),
                ParamV2("start", .boolean, "Connect and start the shell (needs session.start); default false leaves the pane stopped.")
            ], capabilities: [.remoteConnect, .workspaceWrite], conditional: [ConditionalCapabilityV2(.sessionStart, if: .present("start"))],
            resources: [hostRule], createsSpace: true, effect: .mutating(revision: .container("workspace")), errors: remoteErrors.union([.launchFailed]), waits: true),
        MethodSpecV2("remote.status", "A host's helper status and remote workspace link, as last observed; nothing is probed.", params: [hostID], capabilities: [.hostRead], resources: [hostRule]),
        MethodSpecV2(
            "remote.reconnect", "Reconnect a remote workspace host whose link is down, as Retry Now does, or as Reconnect… with interactive.",
            params: [hostID, ParamV2("interactive", .boolean, "Let ssh ask in the app's connection console (a password, a host key); default false never prompts.")],
            capabilities: [.remoteConnect], resources: [hostRule], effect: .mutating(revision: .resource(param: "hostId")), errors: remoteErrors, waits: true),
        MethodSpecV2(
            "remote.helper.install", "Install this build's helper on a host, or update an older one, verified by its SHA-256 there.", params: [hostID],
            capabilities: [.remoteManage], resources: [hostRule], effect: .mutating(revision: .resource(param: "hostId"), destructive: true), errors: remoteErrors, waits: true),
        MethodSpecV2(
            "remote.helper.remove", "Remove the helper from a host (~/.trellis/remote and ~/.trellis/run) for every Mac using it.",
            params: [hostID, ParamV2("stopSessions", .boolean, "Stop this Mac's sessions still running there first (needs session.close).")],
            capabilities: [.remoteManage], conditional: [ConditionalCapabilityV2(.sessionClose, if: .present("stopSessions"))], resources: [hostRule],
            effect: .mutating(revision: .resource(param: "hostId"), destructive: true), errors: remoteErrors, waits: true)
    ]
}
