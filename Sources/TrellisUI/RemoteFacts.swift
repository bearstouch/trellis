import Foundation
import TrellisBroker
import TrellisCore

/// A host's files as Trellis's project and task logic sees them (FR-RW10, FR-RW11). That logic asks synchronous
/// questions (does this exist, read that file); `evaluate` runs it with what is known, fetches what it asked for in one
/// round trip, and runs it again until it asks nothing new. Reads go through the helper's allow-list, which refuses
/// symlinks and other users' files, exactly as local reads do (FR-RW12).
@MainActor
final class RemoteFacts {
    /// What `evaluate`'s body may ask.
    struct Lookup {
        let exists: (String) -> Bool
        let isDirectory: (String) -> Bool
        let read: (String, Int) -> Data?
    }

    enum ReadFailure: Error, Equatable { case missing, refused(String) }

    let connection: BrokerConnection
    private var entries: [String: BrokerPathInfo] = [:]
    private var contents: [String: Result<Data, ReadFailure>] = [:]
    private static let rounds = 4

    init(connection: BrokerConnection) { self.connection = connection }

    func evaluate<T>(_ body: (Lookup) -> T) async -> T {
        for round in 1...Self.rounds {
            var stats = Set<String>(), reads: [String: Int] = [:]
            let lookup = Lookup(
                exists: { path in
                    if let entry = self.entries[path] { return entry.kind != .missing }
                    stats.insert(path)
                    return false
                },
                isDirectory: { path in
                    // Like `fileExists(isDirectory:)`, a link counts by what it points to, which is asked about in turn.
                    guard let entry = self.entries[path] else { stats.insert(path); return false }
                    guard entry.kind == .symlink else { return entry.kind == .directory }
                    guard let target = entry.realPath else { return false }
                    if let resolved = self.entries[target] { return resolved.kind == .directory }
                    stats.insert(target)
                    return false
                },
                read: { path, limit in
                    if let known = self.contents[path] { return try? known.get() }
                    reads[path] = limit
                    return nil
                })
            let result = body(lookup)
            guard round < Self.rounds, !(stats.isEmpty && reads.isEmpty) else { return result }
            await fetch(stats: stats, reads: reads)
        }
        preconditionFailure("unreachable")
    }

    func entry(_ path: String) async -> BrokerPathInfo? {
        if entries[path] == nil { await fetch(stats: [path], reads: [:]) }
        return entries[path]
    }

    /// The bytes, or why there are none: missing, or refused by the helper (a symlink, another user's file, too large).
    func read(_ path: String, limit: Int) async -> Result<Data, ReadFailure> {
        if contents[path] == nil { await fetch(stats: [], reads: [path: limit]) }
        return contents[path] ?? .failure(.refused("UNREADABLE"))
    }

    private func fetch(stats: Set<String>, reads: [String: Int]) async {
        let paths = Array(stats.filter { entries[$0] == nil }).sorted()
        for start in stride(from: 0, to: paths.count, by: BrokerProtocol.statLimit) {
            let chunk = Array(paths[start..<min(start + BrokerProtocol.statLimit, paths.count)])
            guard case .pathInfo(let infos)? = try? await connection.request(.stat(paths: chunk)) else { continue }
            for info in infos { entries[info.path] = info }
        }
        for (path, limit) in reads.sorted(by: { $0.key < $1.key }) where contents[path] == nil {
            // Names the helper never reads are answered here, without a round trip.
            guard BrokerRemoteFiles.isAllowed(path) else { contents[path] = .failure(.refused("NOT_ALLOWED")); continue }
            switch try? await connection.request(.readFile(path: path, limit: limit)) {
            case .fileData(let data)?: contents[path] = .success(data)
            case .failed("NOT_FOUND", _)?: contents[path] = .failure(.missing)
            case .failed(let code, _)?: contents[path] = .failure(.refused(code))
            default: contents[path] = .failure(.refused("UNREADABLE"))
            }
        }
    }
}
