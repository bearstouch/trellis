import Foundation

/// The filesystem effects of managing the CLI link, injected so tests use fixtures.
public struct CLILinkEffects {
    /// Resolves symlinks in the existing part of a path, so a link directory such
    /// as `~/bin -> /usr/local/bin` is judged by where it really points.
    public var resolvePath: (String) -> String
    public var linkState: (String) -> CLILinkPlanner.Existing
    public var createLink: (String, String) throws -> Void
    public var removeLink: (String) throws -> Void
    public var isExecutable: (String) -> Bool

    public init(
        resolvePath: @escaping (String) -> String, linkState: @escaping (String) -> CLILinkPlanner.Existing, createLink: @escaping (String, String) throws -> Void,
        removeLink: @escaping (String) throws -> Void, isExecutable: @escaping (String) -> Bool
    ) {
        self.resolvePath = resolvePath; self.linkState = linkState; self.createLink = createLink; self.removeLink = removeLink; self.isExecutable = isExecutable
    }

    public static var live: CLILinkEffects {
        CLILinkEffects(
            resolvePath: { path in
                var existing = path, rest: [String] = []
                // A relative path shrinks to "", never to "/", so it must stop there too.
                while !FileManager.default.fileExists(atPath: existing), existing != "/", !existing.isEmpty {
                    rest.insert((existing as NSString).lastPathComponent, at: 0); existing = (existing as NSString).deletingLastPathComponent
                }
                return NSString.path(withComponents: [URL(fileURLWithPath: existing).resolvingSymlinksInPath().path] + rest)
            },
            linkState: { path in
                if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path) { return .symlink(to: target) }
                return FileManager.default.fileExists(atPath: path) ? .otherFile : .nothing
            },
            createLink: { link, target in
                try FileManager.default.createDirectory(atPath: (link as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
            },
            // unlink(2), never a recursive delete, even if the path changed since it was inspected.
            removeLink: { path in
                guard unlink(path) == 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path]) }
            },
            // A directory named `trellis` has the execute bit too, but a shell won't run it.
            isExecutable: { path in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue && FileManager.default.isExecutableFile(atPath: path)
            })
    }
}

/// Carries out the explicit CLI link install for both `trellis cli install-link` and the app (MAC-10, MAC-15).
public enum CLILinkInstaller {
    public static let defaultDirectory = "~/.local/bin"
    public static let bundledCLISuffix = ".app/Contents/Helpers/\(CLILinkPlanner.linkName)"

    public enum Outcome: Equatable, Sendable {
        case installed(link: String), replaced(link: String), alreadyInstalled(link: String)
        /// The directory itself is not allowed; nothing was inspected there.
        case invalidDirectory(String)
        /// Something that isn't a Trellis link is in the way; it was left alone.
        case conflict(String)
    }

    /// Judges the real (symlink-resolved) directory too, so links cannot escape the home folder.
    /// The lexical check comes first, so only absolute paths under home get resolved.
    public static func directoryProblem(directory: String, home: String, effects: CLILinkEffects) -> String? {
        if let problem = CLILinkPlanner.validate(directory: directory, home: home) { return problem }
        let real = effects.resolvePath((CLILinkPlanner.linkPath(directory: directory, home: home) as NSString).deletingLastPathComponent)
        return CLILinkPlanner.validate(directory: real, home: effects.resolvePath(home))
    }

    /// Creates or repairs the one link. A failed replace puts the previous link back.
    public static func install(directory: String = defaultDirectory, home: String, cliPath: String, effects: CLILinkEffects) throws -> Outcome {
        if let problem = directoryProblem(directory: directory, home: home, effects: effects) { return .invalidDirectory(problem) }
        let existing = effects.linkState(CLILinkPlanner.linkPath(directory: directory, home: home))
        switch CLILinkPlanner.install(directory: directory, home: home, cliPath: cliPath, existing: existing) {
        case .create(let link, let target):
            try effects.createLink(link, target)
            return .installed(link: link)
        case .replace(let link, let target):
            try effects.removeLink(link)
            do { try effects.createLink(link, target) } catch {
                if case .symlink(let previous) = existing { try? effects.createLink(link, previous) }
                throw error
            }
            return .replaced(link: link)
        case .alreadyInstalled(let link): return .alreadyInstalled(link: link)
        case .refused(let reason): return .conflict(reason)
        case .remove, .nothingToRemove: return .conflict("Nothing was changed.")
        }
    }

    // MARK: - Offering the install from the app

    public enum Location: Equatable, Sendable {
        /// `/Applications` or `~/Applications`: a link made now keeps working.
        case stable
        /// Somewhere else the user put it; a link works until the app moves.
        case elsewhere
        /// The DMG itself or a Gatekeeper-translocated copy: a link would break.
        case transient
    }

    public static func location(bundlePath: String, home: String, isReadOnlyVolume: Bool) -> Location {
        let path = (bundlePath as NSString).standardizingPath
        if isReadOnlyVolume || path.contains("/AppTranslocation/") { return .transient }
        return path.hasPrefix("/Applications/") || path.hasPrefix((home as NSString).standardizingPath + "/Applications/") ? .stable : .elsewhere
    }

    public enum Offer: Equatable, Sendable {
        case ask
        /// A link to this app exists, so there is nothing to ask, now or later.
        case alreadyInstalled
        /// Not now: the app may move, or something is in the way. The menu item still explains why.
        case skip
    }

    public static func offer(bundlePath: String, home: String, isReadOnlyVolume: Bool, effects: CLILinkEffects) -> Offer {
        guard location(bundlePath: bundlePath, home: home, isReadOnlyVolume: isReadOnlyVolume) == .stable else { return .skip }
        let cli = (bundlePath as NSString).standardizingPath + "/Contents/Helpers/\(CLILinkPlanner.linkName)"
        // `~/bin` is the other directory the docs suggest for `install-link --dir`.
        for directory in [defaultDirectory, "~/bin"] where effects.linkState(CLILinkPlanner.linkPath(directory: directory, home: home)) == .symlink(to: cli) {
            return .alreadyInstalled
        }
        guard directoryProblem(directory: defaultDirectory, home: home, effects: effects) == nil else { return .skip }
        let existing = effects.linkState(CLILinkPlanner.linkPath(directory: defaultDirectory, home: home))
        switch CLILinkPlanner.install(directory: defaultDirectory, home: home, cliPath: cli, existing: existing) {
        case .create, .replace: return .ask
        default: return .skip
        }
    }

    // MARK: - Whether the installed link is usable

    public enum PathStatus: Equatable, Sendable {
        case onPath, notOnPath
        /// A different `trellis` comes first, so typing `trellis` runs that one.
        case shadowed(by: String)
        /// The shell's PATH could not be read.
        case unknown
    }

    /// `searchPath` is the user's shell PATH, which a GUI app doesn't inherit.
    public static func pathStatus(link: String, searchPath: [String]?, effects: CLILinkEffects) -> PathStatus {
        guard let searchPath else { return .unknown }
        let target = effects.resolvePath(link)
        for directory in searchPath where directory.hasPrefix("/") {
            let candidate = ((directory as NSString).appendingPathComponent(CLILinkPlanner.linkName) as NSString).standardizingPath
            guard effects.isExecutable(candidate) else { continue }
            return effects.resolvePath(candidate) == target ? .onPath : .shadowed(by: candidate)
        }
        return .notOnPath
    }

    /// The line a user can run themselves. Trellis never runs it (MAC-10).
    public static func pathSetupCommand(shell: String, directory: String = defaultDirectory) -> String {
        let path = directory.hasPrefix("~/") ? "$HOME" + directory.dropFirst() : directory
        switch (shell as NSString).lastPathComponent {
        case "fish": return "fish_add_path \(path)"
        case "bash": return "echo 'export PATH=\"\(path):$PATH\"' >> ~/.bash_profile"
        case "zsh": return "echo 'export PATH=\"\(path):$PATH\"' >> ~/.zshrc"
        default: return "export PATH=\"\(path):$PATH\""
        }
    }
}

/// Reads PATH from the user's login shell, once, on a gesture. Startup files can print
/// anything or hang, so only the marked value is kept and the shell has a deadline.
public enum LoginShellPath {
    private static let begin = "__TRELLIS_PATH_BEGIN__", end = "__TRELLIS_PATH_END__"
    private static let maximumOutput = 1 << 20

    /// The last marked value, ignoring whatever startup files printed around it.
    public static func parse(_ output: String) -> [String]? {
        guard let close = output.range(of: end, options: .backwards), let open = output.range(of: begin, options: .backwards, range: output.startIndex..<close.lowerBound) else {
            return nil
        }
        let entries = output[open.upperBound..<close.lowerBound].split(separator: ":").map(String.init)
        return entries.isEmpty ? nil : entries
    }

    private final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var closed = false
        /// The lock keeps a read already under way from touching a closed handle, which would raise.
        func read(from handle: FileHandle) {
            lock.withLock {
                guard !closed else { return }
                let more = handle.availableData
                // At end of file the handle stays readable, so without this the handler would spin.
                if more.isEmpty { handle.readabilityHandler = nil } else if data.count < maximumOutput { data.append(more) }
            }
        }
        /// Closing also makes a background job still writing get SIGPIPE, rather than block on a full pipe.
        func close(_ handle: FileHandle) {
            handle.readabilityHandler = nil
            lock.withLock {
                closed = true; try? handle.close()
            }
        }
        var path: [String]? { lock.withLock { parse(String(decoding: data, as: UTF8.self)) } }
    }

    /// Blocks up to `timeout`, so call it off the main thread. Nil means unknown: the shell
    /// is unusual, failed, or too slow. Reading stops at the marker rather than at end of
    /// file, because a background job started by a startup file can hold the pipe open.
    public static func query(shell: String, timeout: TimeInterval = 4) -> [String]? {
        let process = Process(), pipe = Pipe(), output = Output()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-i", "-l", "-c", "printf '%s%s%s\\n' '\(begin)' \"$PATH\" '\(end)'"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { output.read(from: $0) }
        defer { output.close(pipe.fileHandleForReading) }
        guard (try? process.run()) != nil else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        var exited: Date?
        var path: [String]?
        while path == nil, Date() < deadline {
            path = output.path
            if path != nil { break }
            // Data can still be on its way to the handler just after the shell exits.
            if !process.isRunning {
                if let exited, Date().timeIntervalSince(exited) > 0.25 { break }
                exited = exited ?? Date()
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        // SIGKILL: interactive shells ignore SIGTERM. Process hasn't seen the child exit, so the PID shouldn't have been reused.
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        return path
    }
}
