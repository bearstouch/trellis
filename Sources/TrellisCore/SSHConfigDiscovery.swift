import Foundation

/// Best-effort, read-only discovery of literal `Host` aliases. This is not an
/// OpenSSH parser: connecting by alias lets `/usr/bin/ssh` apply the real config.
public enum SSHConfigDiscovery {
    public struct Alias: Equatable, Sendable {
        public let name: String
        public let line: Int
    }

    public enum Warning: Equatable, Sendable, CustomStringConvertible {
        case include(line: Int, pattern: String)
        case match(line: Int)
        case pattern(line: Int, value: String)
        case invalidName(line: Int, value: String)

        public var description: String {
            switch self {
            case .include(let line, let pattern):
                "Line \(line): Include \(pattern) was not followed. Aliases in included files are not listed; add them manually."
            case .match(let line): "Line \(line): Match blocks are not listed and their commands are never run."
            case .pattern(let line, let value): "Line \(line): \(value) is a pattern, not a single host, so it is not listed."
            case .invalidName(let line, let value): "Line \(line): \(value) cannot be used as a saved destination."
            }
        }
    }

    public struct Result: Equatable, Sendable {
        public var aliases: [Alias] = []
        public var warnings: [Warning] = []
    }

    public enum Failure: Error, Equatable, Sendable {
        case missing
        case unreadable(String)
    }

    public static let byteLimit = 1_048_576

    public static func parse(_ text: String) -> Result {
        var result = Result()
        var seen = Set<String>()
        for (index, raw) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let line = index + 1
            let words = tokens(String(raw))
            guard let keyword = words.first?.lowercased() else { continue }
            let arguments = Array(words.dropFirst())
            switch keyword {
            case "include": result.warnings.append(.include(line: line, pattern: arguments.joined(separator: " ")))
            case "match": result.warnings.append(.match(line: line))
            case "host":
                for name in arguments {
                    if name.contains(where: { "*?!".contains($0) }) {
                        result.warnings.append(.pattern(line: line, value: name))
                    } else if (try? HostDraft(name: name, destination: name).validated(isRegularFile: { _ in false })) == nil {
                        result.warnings.append(.invalidName(line: line, value: name))
                    } else if seen.insert(name).inserted {
                        result.aliases.append(Alias(name: name, line: line))
                    }
                }
            default: continue
            }
        }
        return result
    }

    /// `read` returns at most `byteLimit` bytes or throws; it never writes.
    public static func discover(_ url: URL, read: (URL) throws -> Data?) -> Swift.Result<Result, Failure> {
        let data: Data?
        do { data = try read(url) } catch { return .failure(.unreadable(error.localizedDescription)) }
        guard let data else { return .failure(.missing) }
        guard data.count <= byteLimit else { return .failure(.unreadable("The file is larger than 1 MiB.")) }
        return .success(parse(String(decoding: data, as: UTF8.self)))
    }

    /// Bounded read of a regular file (symlinked dotfiles are allowed). The type is
    /// checked on the opened descriptor, and O_NONBLOCK keeps a FIFO from hanging.
    public static func readConfig(_ url: URL) throws -> Data? {
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 { if errno == ENOENT { return nil }; throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw CocoaError(.fileReadUnknown) }
        guard info.st_size <= byteLimit else { throw CocoaError(.fileReadTooLarge) }
        return try handle.read(upToCount: byteLimit + 1) ?? Data()
    }

    /// ssh_config words: whitespace or a single "=" separates the keyword;
    /// double quotes group words; an unquoted "#" starts a comment.
    static func tokens(_ line: String) -> [String] {
        var words: [String] = [], current = "", quoted = false, started = false, separated = false
        func flush() {
            if started { words.append(current) }
            current = ""; started = false
        }
        for character in line {
            if quoted {
                if character == "\"" { quoted = false } else { current.append(character) }
            } else if character == "\"" {
                quoted = true; started = true
            } else if character == "#" && !started {
                break
            } else if character == "=" && !separated && words.count + (started ? 1 : 0) == 1 {
                // "Host=a", "Host = a" and "Host =a" are all one keyword/argument split.
                flush(); separated = true
            } else if character.isWhitespace {
                flush()
            } else {
                current.append(character); started = true
            }
        }
        flush()
        return words
    }
}

extension HostLibrary {
    /// Adds aliases as hosts whose destination is the alias itself, in one
    /// commit: either every selected alias is saved or none is. Aliases already
    /// saved as a destination (or repeated) are skipped, so a stale preview cannot duplicate.
    public func importAliases(_ aliases: [String]) throws(HostLibraryError) -> [SavedHost] {
        var seen = Set(hosts.map(\.destination))
        return try createAll(aliases.filter { seen.insert($0).inserted }.map { HostDraft(name: $0, destination: $0, tags: "ssh-config") })
    }
}
