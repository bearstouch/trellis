import Foundation
import TrellisControl
import TrellisCore

extension AutomationServiceV2 {
    @MainActor func performSystem(_ call: CallV2) -> Result<JSONValue, ControlError> {
        switch call.spec.name {
        case "system.info": .success(ResultsV2.systemInfo(appVersion: AppVersion.bundled ?? "development", instanceID: instanceID))
        default: .failure(.methodNotFound)
        }
    }
}
