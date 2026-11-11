import Foundation
import TrellisControl
import TrellisCore

/// The protocol 2 domain adapter (docs/api/v2/implementation.md). Calls arrive validated and authorized from the
/// catalog; each area lives in its own file here and calls the same `AppWorkspaceModel` actions as the UI, so the UI and
/// the API stay one path. Constructed only when the app runs with `--automation-v2`.
public final class AutomationServiceV2: ControlDomainV2, @unchecked Sendable {
    let model: AppWorkspaceModel
    let hosts: HostListModel
    let instanceID: UUID

    @MainActor public init(model: AppWorkspaceModel, hosts: HostListModel, instanceID: UUID = UUID()) {
        self.model = model; self.hosts = hosts; self.instanceID = instanceID
    }

    public func snapshot() async -> WorkspaceSnapshot { await model.snapshotForAutomation() }
    public func host(_ id: UUID) async -> SavedHost? { await hosts.host(id) }

    public func perform(_ call: CallV2) async -> Result<JSONValue, ControlError> {
        switch call.spec.area {
        case "system": await performSystem(call)
        default: .failure(.methodNotFound)
        }
    }
}
