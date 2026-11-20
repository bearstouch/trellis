import Foundation

/// Copying and moving files dropped on the Files view, between this Mac and a remote workspace's host (FR-FB10–FR-FB14).
/// The engine knows nothing of either side: a ``TransferSource`` reads, a ``TransferDestination`` writes, and tests inject both.

public enum TransferItemKind: String, Equatable, Sendable { case file, directory, symlink, other }

/// One entry as its source sees it; a link is a link, never what it points to.
public struct TransferItem: Equatable, Sendable {
    public let path: String
    public let kind: TransferItemKind
    public let size: Int64
    /// Permission bits.
    public let mode: Int
    /// A link's target, when the source can copy links.
    public let linkTarget: String?
    public var name: String { (path as NSString).lastPathComponent }
    public init(path: String, kind: TransferItemKind, size: Int64 = 0, mode: Int? = nil, linkTarget: String? = nil) {
        self.path = path; self.kind = kind; self.size = size; self.mode = mode ?? (kind == .directory ? 0o755 : 0o644); self.linkTarget = linkTarget
    }
}

public struct TransferChunk: Equatable, Sendable {
    public let data: Data
    /// The whole file's size and modification time (nanoseconds), so a change between chunks is noticed.
    public let size: Int64
    public let modified: Int64
    public init(data: Data, size: Int64, modified: Int64) { self.data = data; self.size = size; self.modified = modified }
}

/// SCREAMING_SNAKE, as the helper says them (FR-RW20).
public enum FileTransferFailure: String, Error, Equatable, Sendable {
    case tooLarge = "TOO_LARGE", tooManyItems = "TOO_MANY_ITEMS", disconnected = "DISCONNECTED", changed = "CHANGED", exists = "EXISTS", intoItself = "INTO_ITSELF"
    case missing = "NOT_FOUND", notAllowed = "NOT_ALLOWED", unreadable = "UNREADABLE", unwritable = "UNWRITABLE", noSpace = "NO_SPACE", crossDevice = "CROSS_DEVICE"

    public init(code: String) { self = Self(rawValue: code) ?? .unwritable }
}

public protocol TransferSource: Sendable {
    /// Each path's own facts; a path that isn't there is left out.
    func describe(_ paths: [String]) async throws(FileTransferFailure) -> [TransferItem]
    func children(of folder: String) async throws(FileTransferFailure) -> [TransferItem]
    /// Up to `length` bytes of a regular file from `offset`.
    func read(_ path: String, offset: Int64, length: Int) async throws(FileTransferFailure) -> TransferChunk
}

public protocol TransferDestination: Sendable {
    /// The entries already in `folder`, by name.
    func existing(in folder: String) async throws(FileTransferFailure) -> [String: TransferItemKind]
    func makeDirectory(_ path: String, mode: Int) async throws(FileTransferFailure)
    /// A new, empty temporary file in `folder`; its name is passed back to the calls below.
    func begin(in folder: String) async throws(FileTransferFailure) -> String
    func write(_ temp: String, in folder: String, offset: Int64, data: Data) async throws(FileTransferFailure)
    /// Moves a complete temporary file of `size` bytes to `name`; without `replace`, a taken name throws `exists` and the
    /// temporary file stays for another name.
    func finish(_ temp: String, in folder: String, name: String, mode: Int, size: Int64, replace: Bool) async throws(FileTransferFailure)
    func abort(_ temp: String, in folder: String) async
    /// Moves an entry on the same machine; never replaces one unless `replace` and ``movesReplace``.
    func move(_ path: String, to target: String, replace: Bool) async throws(FileTransferFailure)
    /// Whether a move can replace an entry (this Mac) or only take a free name (a host).
    var movesReplace: Bool { get }
    /// Whether links are copied as links; elsewhere they are skipped.
    var makesLinks: Bool { get }
    func makeLink(_ path: String, target: String, replace: Bool) async throws(FileTransferFailure)
    /// Fills a temporary file from a file on the same Mac in one step (keeping its metadata); false when it can't.
    func copyLocalFile(_ source: String, into temp: String, in folder: String) async throws(FileTransferFailure) -> Int64?
    /// Removes a folder left empty by a merging move.
    func removeEmptyFolder(_ path: String) async
}

extension TransferDestination {
    public var movesReplace: Bool { false }
    public var makesLinks: Bool { false }
    public func makeLink(_ path: String, target: String, replace: Bool) async throws(FileTransferFailure) { throw .notAllowed }
    public func copyLocalFile(_ source: String, into temp: String, in folder: String) async throws(FileTransferFailure) -> Int64? { nil }
    public func removeEmptyFolder(_ path: String) async {}
}

public struct FileTransferLimits: Equatable, Sendable {
    public var totalBytes: Int64
    public var entries: Int
    public var chunk: Int
    public init(totalBytes: Int64 = 2 << 30, entries: Int = 10_000, chunk: Int = 524_288) { self.totalBytes = totalBytes; self.entries = entries; self.chunk = chunk }
}

public enum FileTransferChoice: String, Equatable, Sendable { case replace, merge, keepBoth, skip }

/// A name already taken in the folder an item goes to (FR-FB12).
public struct FileTransferConflict: Equatable, Sendable {
    public let name: String
    public let folder: String
    public let incoming: TransferItemKind
    public let existing: TransferItemKind
    /// What may be chosen: never a replace that would delete a folder, so nothing is ever removed recursively.
    public let choices: [FileTransferChoice]
    public init(name: String, folder: String, incoming: TransferItemKind, existing: TransferItemKind, choices: [FileTransferChoice]) {
        self.name = name; self.folder = folder; self.incoming = incoming; self.existing = existing; self.choices = choices
    }
}

public struct FileTransferDecision: Equatable, Sendable {
    public let choice: FileTransferChoice
    /// Used for the rest of the conflicts of the same kind (file onto file, folder onto folder, or mixed).
    public let applyToAll: Bool
    public init(_ choice: FileTransferChoice, applyToAll: Bool = false) { self.choice = choice; self.applyToAll = applyToAll }
}

public struct FileTransferProgress: Equatable, Sendable {
    public var itemsDone = 0, itemsTotal = 0
    public var bytesDone: Int64 = 0, bytesTotal: Int64 = 0
    public var currentName = ""
    public init() {}
    public var fraction: Double { bytesTotal > 0 ? min(1, Double(bytesDone) / Double(bytesTotal)) : itemsTotal > 0 ? Double(itemsDone) / Double(itemsTotal) : 0 }
}

public struct FileTransferReport: Equatable, Sendable {
    /// Files, folders and links written.
    public var copied = 0
    public var skipped = 0
    public var linksSkipped = 0
    public var failures: [String: FileTransferFailure] = [:]
    public var cancelled = false
    /// Why the whole copy stopped: too large, too many items, or the link went down.
    public var stopped: FileTransferFailure?
    /// Where the first dropped item ended up, to select it.
    public var firstPlaced: String?
    public init() {}
}

/// "report 2.pdf", "a 2.tar.gz", "docs 2", ".env 2": the first free name, as Finder's Keep Both makes them.
public enum FileTransferNaming {
    public static func keepBoth(_ name: String, taken: Set<String>, isFolder: Bool = false) -> String {
        let (stem, suffix) = split(name, isFolder: isFolder)
        var number = 2
        while taken.contains("\(stem) \(number)\(suffix)") { number += 1 }
        return "\(stem) \(number)\(suffix)"
    }

    /// The stem and the extension(s) kept after the number: `.tar.gz` and the like stay whole; a dot-file has none.
    static func split(_ name: String, isFolder: Bool) -> (String, String) {
        guard !isFolder, let dot = name.dropFirst().firstIndex(of: ".") else { return (name, "") }
        let compound = [".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst"].first { name.lowercased().hasSuffix($0) && name.count > $0.count }
        if let compound { return (String(name.dropLast(compound.count)), String(name.suffix(compound.count))) }
        let last = name.lastIndex(of: ".") ?? dot
        return (String(name[..<last]), String(name[last...]))
    }
}

/// One drop's copy or move. Everything is checked against the limits before anything is written; then each item is
/// placed in turn, asking about taken names. A failure of one item is reported and the rest go on; a cancel, or a link
/// that went down, stops the run and keeps what was finished.
public actor FileTransferRun {
    public typealias Resolve = @Sendable (FileTransferConflict) async -> FileTransferDecision?
    public typealias Report = @Sendable (FileTransferProgress) -> Void

    private let source: any TransferSource
    private let destination: any TransferDestination
    /// Source and destination are the same machine's tree: a folder can't go into itself, and a move is possible.
    private let sameMachine: Bool
    /// Both are this Mac: links are copied as links and files in one step.
    private let bothLocal: Bool
    private let limits: FileTransferLimits
    private let resolve: Resolve
    private let report: Report
    private var progress = FileTransferProgress()
    private var result = FileTransferReport()
    private var known: [String: [String: TransferItemKind]] = [:]
    private var remembered: [String: FileTransferChoice] = [:]
    private var lastReport = ContinuousClock.now

    private final class Node: @unchecked Sendable {
        let item: TransferItem
        var children: [Node] = []
        init(_ item: TransferItem) { self.item = item }
    }

    public init(
        source: any TransferSource, destination: any TransferDestination, sameMachine: Bool, bothLocal: Bool = false, limits: FileTransferLimits = FileTransferLimits(),
        resolve: @escaping Resolve, progress: @escaping Report = { _ in }
    ) {
        self.source = source; self.destination = destination; self.sameMachine = sameMachine; self.bothLocal = bothLocal && sameMachine; self.limits = limits
        self.resolve = resolve; report = progress
    }

    // MARK: Copy

    public func copy(_ paths: [String], into folder: String) async -> FileTransferReport {
        // Plain `do` blocks and initialized vars here: Swift 6.3's optimizer crashed on typed-throws `do` blocks that
        // initialized a `let` declared outside them.
        var roots: [Node] = []
        do { roots = try await plan(paths, into: folder) } catch {
            result.stopped = Self.failure(error, or: .unreadable)
            return result
        }
        do {
            for root in roots {
                try Task.checkCancellation()
                if let placed = try await place(root, in: folder), result.firstPlaced == nil { result.firstPlaced = placed }
            }
        } catch is CancellationError {
            result.cancelled = true
        } catch let failure as FileTransferFailure {
            result.stopped = failure
        } catch {}
        report(progress)
        return result
    }

    /// The whole tree under the dropped items, refused past the limits before anything is written.
    private func plan(_ paths: [String], into folder: String) async throws(FileTransferFailure) -> [Node] {
        let described = try await source.describe(paths)
        for missing in Set(paths).subtracting(described.map(\.path)) { result.failures[missing] = .missing }
        var roots: [Node] = []
        for item in described {
            if sameMachine, item.kind == .directory, folder == item.path || folder.hasPrefix(item.path == "/" ? "/" : item.path + "/") {
                result.failures[item.path] = .intoItself
                continue
            }
            roots.append(Node(item))
        }
        var queue = roots, next = 0, entries = roots.count, bytes = roots.reduce(Int64(0)) { $0 + ($1.item.kind == .file ? $1.item.size : 0) }
        guard entries <= limits.entries else { throw .tooManyItems }
        guard bytes <= limits.totalBytes else { throw .tooLarge }
        while next < queue.count {
            let node = queue[next]
            next += 1
            guard node.item.kind == .directory else { continue }
            node.children = try await source.children(of: node.item.path).map(Node.init)
            entries += node.children.count
            bytes += node.children.reduce(Int64(0)) { $0 + ($1.item.kind == .file ? $1.item.size : 0) }
            guard entries <= limits.entries else { throw .tooManyItems }
            guard bytes <= limits.totalBytes else { throw .tooLarge }
            queue += node.children
        }
        (progress.itemsTotal, progress.bytesTotal) = (entries, bytes)
        report(progress)
        return roots
    }

    private func existing(in folder: String) async throws(FileTransferFailure) -> [String: TransferItemKind] {
        if let names = known[folder] { return names }
        let names = try await destination.existing(in: folder)
        known[folder] = names
        return names
    }

    private static func join(_ folder: String, _ name: String) -> String { folder == "/" ? "/" + name : folder + "/" + name }

    private func count(_ node: Node) -> Int { 1 + node.children.reduce(0) { $0 + count($1) } }

    private func bytes(_ node: Node) -> Int64 { (node.item.kind == .file ? node.item.size : 0) + node.children.reduce(Int64(0)) { $0 + bytes($1) } }

    private func skip(_ node: Node) {
        result.skipped += 1
        progress.itemsDone += count(node)
        progress.bytesDone += bytes(node)
    }

    /// The name an item takes in `folder`, nil to skip it; `merge` puts a folder's contents into the one already there.
    private func decide(_ item: TransferItem, in folder: String, move: Bool) async throws -> (name: String, replace: Bool, merge: Bool)? {
        let names = try await existing(in: folder)
        guard let taken = names[item.name] else { return (item.name, false, false) }
        // Dropped where it already is: a copy is kept beside it, as Finder duplicates; a move does nothing.
        if sameMachine, Self.join(folder, item.name) == item.path {
            return move ? nil : (FileTransferNaming.keepBoth(item.name, taken: Set(names.keys), isFolder: item.kind == .directory), false, false)
        }
        let folders = item.kind == .directory && taken == .directory, files = item.kind != .directory && taken != .directory
        var choices: [FileTransferChoice] = []
        if folders, !move || destination.movesReplace { choices.append(.merge) }
        if files, !move || destination.movesReplace { choices.append(.replace) }
        choices += [.keepBoth, .skip]
        let key = folders ? "folders" : files ? "files" : "mixed"
        let choice: FileTransferChoice
        if let saved = remembered[key], choices.contains(saved) {
            choice = saved
        } else {
            guard let decision = await resolve(FileTransferConflict(name: item.name, folder: folder, incoming: item.kind, existing: taken, choices: choices)) else {
                throw CancellationError()
            }
            guard choices.contains(decision.choice) else { return nil }
            choice = decision.choice
            if decision.applyToAll { remembered[key] = choice }
        }
        switch choice {
        case .skip: return nil
        case .merge: return (item.name, false, true)
        case .replace: return (item.name, true, false)
        case .keepBoth: return (FileTransferNaming.keepBoth(item.name, taken: Set(names.keys), isFolder: item.kind == .directory), false, false)
        }
    }

    /// Where the item went, nil when it was skipped or failed.
    private func place(_ node: Node, in folder: String) async throws -> String? {
        let item = node.item
        progress.currentName = item.name
        if item.kind == .other || (item.kind == .symlink && !(bothLocal && destination.makesLinks && item.linkTarget != nil)) {
            if item.kind == .symlink { result.linksSkipped += 1 } else { result.skipped += 1 }
            progress.itemsDone += 1
            return nil
        }
        var path = ""
        do {
            // A folder there that can't be listed fails this item alone, as a write would.
            guard let target = try await decide(item, in: folder, move: false) else { skip(node); return nil }
            path = Self.join(folder, target.name)
            switch item.kind {
            case .directory:
                if !target.merge {
                    do { try await destination.makeDirectory(path, mode: item.mode) } catch FileTransferFailure.exists {
                        // Made since the folder was listed: merged into, as if it had been chosen.
                    }
                    known[folder, default: [:]][target.name] = .directory
                    if known[path] == nil { known[path] = [:] }
                    result.copied += 1
                }
                progress.itemsDone += 1
                for child in node.children {
                    try Task.checkCancellation()
                    _ = try await place(child, in: path)
                }
            case .symlink:
                try await destination.makeLink(path, target: item.linkTarget ?? "", replace: target.replace)
                known[folder, default: [:]][target.name] = .symlink
                result.copied += 1
                progress.itemsDone += 1
            default:
                let placed = try await copyFile(item, to: target.name, in: folder, replace: target.replace)
                known[folder, default: [:]][placed] = .file
                path = Self.join(folder, placed)
                result.copied += 1
                progress.itemsDone += 1
            }
        } catch let failure as FileTransferFailure where failure != .disconnected {
            result.failures[item.path] = failure
            progress.itemsDone += count(node)
            return nil
        }
        tick()
        return path
    }

    /// The name the file took: another when `name` was taken since the folder was listed.
    /// Split in three small steps: Swift 6.3's `MandatoryAllocBoxToStack` crashed on these as one function (loops over
    /// awaits inside a `do` whose `catch` awaits too).
    private func copyFile(_ item: TransferItem, to name: String, in folder: String, replace: Bool) async throws -> String {
        let temp = try await destination.begin(in: folder)
        do {
            let written = try await fill(temp, in: folder, from: item)
            return try await settle(temp, in: folder, as: name, item: item, size: written, replace: replace)
        } catch {
            await destination.abort(temp, in: folder)
            throw error
        }
    }

    /// Writes the item's bytes into the temporary file; the bytes written.
    private func fill(_ temp: String, in folder: String, from item: TransferItem) async throws -> Int64 {
        if bothLocal, let size = try await destination.copyLocalFile(item.path, into: temp, in: folder) {
            progress.bytesDone += size
            return size
        }
        var written: Int64 = 0, size: Int64 = -1, modified: Int64 = -1, done = false
        while !done {
            try Task.checkCancellation()
            let chunk = try await source.read(item.path, offset: written, length: limits.chunk)
            if size >= 0, size != chunk.size || modified != chunk.modified { throw FileTransferFailure.changed }
            (size, modified) = (chunk.size, chunk.modified)
            if chunk.data.isEmpty { break }
            // A file that grew past what was planned can't take the copy over its limit.
            if progress.bytesDone + Int64(chunk.data.count) > limits.totalBytes { throw FileTransferFailure.tooLarge }
            try await destination.write(temp, in: folder, offset: written, data: chunk.data)
            written += Int64(chunk.data.count)
            progress.bytesDone += Int64(chunk.data.count)
            tick()
            done = written >= chunk.size
        }
        return written
    }

    /// Moves the finished temporary file to its name, or beside it when the name was taken since the folder was listed.
    private func settle(_ temp: String, in folder: String, as name: String, item: TransferItem, size: Int64, replace: Bool) async throws -> String {
        var name = name, attempts = 0
        while true {
            let taken = await finished(temp, in: folder, as: name, mode: item.mode, size: size, replace: replace)
            guard let taken else { return name }
            attempts += 1
            guard taken == .exists, attempts < 100 else { throw taken }
            known[folder, default: [:]][name] = .file
            name = FileTransferNaming.keepBoth(item.name, taken: Set(known[folder, default: [:]].keys))
        }
    }

    /// nil when the file is in place, else why not.
    private func finished(_ temp: String, in folder: String, as name: String, mode: Int, size: Int64, replace: Bool) async -> FileTransferFailure? {
        do {
            try await destination.finish(temp, in: folder, name: name, mode: mode, size: size, replace: replace)
            return nil
        } catch {
            return Self.failure(error, or: .unwritable)
        }
    }

    /// What a plain `do` caught, as a failure: Swift 6.4 infers the typed error there, 6.3 doesn't, so this reads the
    /// same (and warns on neither).
    private static func failure(_ error: any Error, or fallback: FileTransferFailure) -> FileTransferFailure { error as? FileTransferFailure ?? fallback }

    private func tick() {
        let now = ContinuousClock.now
        guard now - lastReport >= .milliseconds(100) else { return }
        lastReport = now
        report(progress)
    }

    // MARK: Move (same machine)

    /// Moves the dropped items into `folder`; only within one machine. A merged folder is emptied into the one there and
    /// removed when nothing is left in it.
    public func move(_ paths: [String], into folder: String) async -> FileTransferReport {
        guard sameMachine else { return await copy(paths, into: folder) }
        var items: [TransferItem] = []
        do { items = try await source.describe(paths) } catch {
            result.stopped = Self.failure(error, or: .unreadable)
            return result
        }
        for missing in Set(paths).subtracting(items.map(\.path)) { result.failures[missing] = .missing }
        progress.itemsTotal = items.count
        do {
            for item in items {
                try Task.checkCancellation()
                if item.kind == .directory, folder == item.path || folder.hasPrefix(item.path + "/") {
                    result.failures[item.path] = .intoItself
                    continue
                }
                if let placed = try await moveItem(item, into: folder), result.firstPlaced == nil { result.firstPlaced = placed }
                progress.itemsDone += 1
                tick()
            }
        } catch is CancellationError {
            result.cancelled = true
        } catch let failure as FileTransferFailure {
            result.stopped = failure
        } catch {}
        report(progress)
        return result
    }

    private func moveItem(_ item: TransferItem, into folder: String) async throws -> String? {
        progress.currentName = item.name
        let decided: (name: String, replace: Bool, merge: Bool)?
        do { decided = try await decide(item, in: folder, move: true) } catch let failure as FileTransferFailure where failure != .disconnected {
            result.failures[item.path] = failure
            return nil
        }
        guard let target = decided else {
            if Self.join(folder, item.name) != item.path { result.skipped += 1 }
            return nil
        }
        let path = Self.join(folder, target.name)
        if target.merge {
            var children: [TransferItem] = []
            do { children = try await source.children(of: item.path) } catch {
                result.failures[item.path] = Self.failure(error, or: .unreadable)
                return nil
            }
            for child in children {
                try Task.checkCancellation()
                _ = try await moveItem(child, into: path)
            }
            await destination.removeEmptyFolder(item.path)
            return path
        }
        do {
            try await destination.move(item.path, to: path, replace: target.replace)
            known[folder, default: [:]][target.name] = item.kind
            result.copied += 1
            return path
        } catch {
            let failure = Self.failure(error, or: .unwritable)
            if failure == .disconnected { throw failure }
            result.failures[item.path] = failure
            return nil
        }
    }
}
