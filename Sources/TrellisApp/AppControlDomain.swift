import Foundation
import TrellisControl
import TrellisCore
import TrellisUI

/// Bridges authorized control requests to the main-actor workspace model.
/// Resource methods arrive in S023; until then only `system.info` executes.
final class AppControlDomain: ControlDomain, @unchecked Sendable {
    private let model: AppWorkspaceModel
    private let hosts: HostListModel

    @MainActor init(model: AppWorkspaceModel, hosts: HostListModel) { self.model = model; self.hosts = hosts }

    func snapshot() async -> WorkspaceSnapshot { await MainActor.run { model.snapshot } }

    func host(_ id: UUID) async -> SavedHost? { await hosts.host(id) }

    func execute(_ method: String, params: JSONValue?, access: GrantAccess) async -> Result<JSONValue, ControlError> {
        switch method {
        case "system.info":
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
            return .success(
                .object([
                    "apiVersion": .number(1), "appVersion": .string(version),
                    "capabilities": .array(access.grant.capabilities.sorted().map { .string($0.rawValue) }),
                    "limits": .object(["maxFrameBytes": .number(Double(ControlFramer.maximumFrame))])
                ]))
        default: return .failure(.methodNotFound)
        }
    }
}
