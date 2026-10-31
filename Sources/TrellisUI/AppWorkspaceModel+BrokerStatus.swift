import Foundation
import TrellisBroker
import TrellisTerminal

/// One host's broker, as Settings → Sessions lists it.
public struct RemoteBrokerStatus: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let hostName: String
    public let processID: Int32
    public let protocolVersion: Int
    /// "Linux aarch64".
    public let platform: String?
    public let running: Int
    public let ended: Int
}

/// The session brokers this Trellis uses (FR-R07, FR-RW13): this Mac's, and each connected host's. Read on demand; nothing
/// is started or connected to find out.
extension AppWorkspaceModel {
    public func sessionBrokerStatus() async -> (local: BrokerStatus, remote: [RemoteBrokerStatus]) {
        let local = await sessionBroker?.status() ?? .notRunning
        var remote: [RemoteBrokerStatus] = []
        for hostID in remoteHosts?.connectedWorkspaceHosts ?? [] {
            guard let connection = remoteHosts?.workspaceConnection(hostID) else { continue }
            var records: [BrokerSessionRecord] = []
            if case .sessions(let listed)? = try? await connection.request(.list) { records = listed }
            let platform = connection.hostInfo.map { ($0.os == "darwin" ? "macOS" : $0.os == "linux" ? "Linux" : $0.os) + " " + $0.arch }
            remote.append(
                RemoteBrokerStatus(
                    id: hostID, hostName: remoteHostName(hostID), processID: connection.brokerPID, protocolVersion: connection.protocolVersion, platform: platform,
                    running: records.filter(\.running).count, ended: records.filter { !$0.running }.count))
        }
        return (local, remote.sorted { $0.hostName.localizedStandardCompare($1.hostName) == .orderedAscending })
    }
}
