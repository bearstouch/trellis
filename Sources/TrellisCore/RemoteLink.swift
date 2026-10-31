import Darwin
import Foundation

/// A helper build Trellis can install on a remote host (FR-RW02). `digest` is the SHA-256 of the helper itself, checked
/// on the host after upload; `fileDigest` is the SHA-256 of the file sent (gzip or raw), checked here before upload.
public struct RemoteArtifact: Codable, Equatable, Sendable {
    public var platform: String
    public var path: String
    public var digest: String
    public var fileDigest: String
    public var fileSize: Int
    public var compressed: Bool
    /// The install directory under `~/.trellis/remote`: 16 hex characters naming this helper together with the shell
    /// integration scripts installed beside it, so a change to either installs a new directory.
    public var directory: String
    public init(platform: String, path: String, digest: String, fileDigest: String, fileSize: Int, compressed: Bool, directory: String? = nil) {
        self.platform = platform; self.path = path; self.digest = digest; self.fileDigest = fileDigest; self.fileSize = fileSize; self.compressed = compressed
        self.directory = directory ?? String(digest.prefix(16))
    }

    public static func isDigest(_ value: String) -> Bool { value.utf8.count == 64 && value.utf8.allSatisfy(RemoteBootstrap.isLowerHex) }
}

/// One shell integration script installed beside the helper (FR-RW05), at `integration/<path>` in its directory.
public struct RemoteIntegrationFile: Equatable, Sendable {
    public var path: String
    public var data: Data
    public var digest: String
    public init(path: String, data: Data, digest: String) { self.path = path; self.data = data; self.digest = digest }
}

public enum RemotePlatform {
    /// The bundled helper for a host's `uname -s` and `uname -m`; nil when Trellis has none for it.
    public static func key(system: String, machine: String) -> String? {
        switch (system.lowercased(), machine.lowercased()) {
        case ("linux", "x86_64"), ("linux", "amd64"): "linux-x86_64"
        case ("linux", "aarch64"), ("linux", "arm64"): "linux-aarch64"
        case ("darwin", "arm64"), ("darwin", "x86_64"): "darwin"
        default: nil
        }
    }

    /// "Linux aarch64", "macOS arm64".
    public static func displayName(system: String, machine: String) -> String {
        (system.lowercased() == "darwin" ? "macOS" : system.lowercased() == "linux" ? "Linux" : system) + " " + machine
    }
}

/// What the bootstrap reports first: the host's platform, whether it can check a digest, and the installed helpers.
public struct RemoteProbe: Equatable, Sendable {
    public var system: String
    public var machine: String
    /// `sha256sum`, `shasum` or `openssl`; nil when the host has none, so nothing can be installed safely.
    public var checksumTool: String?
    /// Install directories (16 hex characters) that hold an executable helper.
    public var installed: Set<String>
    public init(system: String, machine: String, checksumTool: String?, installed: Set<String>) {
        self.system = system; self.machine = machine; self.checksumTool = checksumTool; self.installed = installed
    }
    public var platform: String? { RemotePlatform.key(system: system, machine: machine) }
    public var displayName: String { RemotePlatform.displayName(system: system, machine: machine) }
}

/// The POSIX `sh` script that runs first on a host (FR-RW02, FR-RW03): it reports the platform, then answers one
/// command per line on stdin, each upload followed by exactly its bytes: `file <dir> <digest> <bytes> <path>` (a shell
/// integration script), `install <dir> <digest> <bytes> gz|raw` (the helper, sent last so an installed directory is
/// complete), `bridge <dir>`, `remove` or `quit`. Every reply starts with `TRELLIS-<nonce> `, so login-script output
/// can't forge one.
public enum RemoteBootstrap {
    public static let replyPrefix = "TRELLIS-"
    /// Login scripts may print this much before the probe; more is a failure.
    public static let noiseLimit = 65_536

    static func isLowerHex(_ byte: UInt8) -> Bool { (48...57).contains(byte) || (97...102).contains(byte) }
    public static func isNonce(_ value: String) -> Bool { value.utf8.count == 32 && value.utf8.allSatisfy(isLowerHex) }

    public static func script(nonce: String, clientID: String) -> String {
        precondition(isNonce(nonce) && isNonce(clientID))
        return """
            umask 077
            N=\(nonce); C=\(clientID); R="$HOME/.trellis/remote"
            say() { printf 'TRELLIS-%s %s\\n' "$N" "$*"; }
            tool=none
            for t in sha256sum shasum openssl; do if command -v "$t" >/dev/null 2>&1; then tool=$t; break; fi; done
            sum() {
              case "$tool" in
              sha256sum) sha256sum "$1" ;;
              shasum) shasum -a 256 "$1" ;;
              openssl) openssl dgst -sha256 -r "$1" ;;
              esac | { read -r d rest; printf '%s' "$d"; }
            }
            dirs=
            for f in "$R"/*/trellis-broker; do [ -x "$f" ] && dirs="$dirs $(basename "$(dirname "$f")")"; done
            say PROBE 1 "$(uname -s)" "$(uname -m)" "$tool"$dirs
            hex16() { case "$1" in *[!0-9a-f]*|'') return 1 ;; esac; [ "${#1}" -eq 16 ]; }
            hex64() { case "$1" in *[!0-9a-f]*|'') return 1 ;; esac; [ "${#1}" -eq 64 ]; }
            count() { case "$1" in *[!0-9]*|'') return 1 ;; esac; }
            # receive <target> <digest> <bytes> gz|raw: exactly <bytes> from stdin, kept only if its SHA-256 matches.
            receive() {
              t="$1.upload.$$"
              rm -f "$t"
              if [ "$4" = gz ]; then head -c "$3" | gzip -dc > "$t"; else head -c "$3" > "$t"; fi
              if [ "$(sum "$t")" = "$2" ] && mv -f "$t" "$1"; then return 0; fi
              rm -f "$t"
              return 1
            }
            while read -r cmd a b c e; do
              case "$cmd" in
              file)
                hex16 "$a" && hex64 "$b" && count "$c" && [ "$tool" != none ] || { say ERROR INVALID; exit 1; }
                case "$e" in ''|/*|*..*|*[!A-Za-z0-9._/-]*) say ERROR INVALID; exit 1 ;; esac
                f="$R/$a/integration/$e"
                mkdir -p "$(dirname "$f")" || { say ERROR MKDIR; exit 1; }
                receive "$f" "$b" "$c" raw || { say ERROR DIGEST; exit 1; }
                say STORED "$e"
                ;;
              install)
                hex16 "$a" && hex64 "$b" && count "$c" && [ "$tool" != none ] || { say ERROR INVALID; exit 1; }
                case "$e" in gz|raw) ;; *) say ERROR INVALID; exit 1 ;; esac
                [ "$e" = raw ] || command -v gzip >/dev/null 2>&1 || { say ERROR GZIP; exit 1; }
                mkdir -p "$R/$a" || { say ERROR MKDIR; exit 1; }
                receive "$R/$a/trellis-broker.new" "$b" "$c" "$e" && chmod 700 "$R/$a/trellis-broker.new" && mv -f "$R/$a/trellis-broker.new" "$R/$a/trellis-broker" || { say ERROR DIGEST; exit 1; }
                say INSTALLED "$a"
                ;;
              bridge)
                hex16 "$a" || { say ERROR INVALID; exit 1; }
                [ -x "$R/$a/trellis-broker" ] || { say ERROR MISSING; exit 1; }
                exec "$R/$a/trellis-broker" bridge --client-id "$C" --sync "$N"
                ;;
              remove)
                rm -rf "$R" "$HOME/.trellis/run"
                rmdir "$HOME/.trellis" 2>/dev/null
                say REMOVED
                ;;
              *) exit 0 ;;
              esac
            done
            """
    }

    /// The single ssh command argument. It parses the same in sh, bash, zsh, fish and csh login shells: one line,
    /// no `!`, and nothing but base64 inside its single quotes.
    public static func command(nonce: String, clientID: String) -> String {
        let encoded = Data(script(nonce: nonce, clientID: clientID).utf8).base64EncodedString()
        return "exec /bin/sh -c 'eval \"$(echo \(encoded) | (base64 -d 2>/dev/null || base64 -D 2>/dev/null))\"'"
    }

    public static func installLine(_ artifact: RemoteArtifact) -> String {
        "install \(artifact.directory) \(artifact.digest) \(artifact.fileSize) \(artifact.compressed ? "gz" : "raw")\n"
    }
    public static func fileLine(_ file: RemoteIntegrationFile, directory: String) -> String {
        "file \(directory) \(file.digest) \(file.data.count) \(file.path)\n"
    }
    public static func bridgeLine(directory: String) -> String { "bridge \(directory)\n" }
    public static let removeLine = "remove\n"
    public static let quitLine = "quit\n"

    public enum Reply: Equatable, Sendable {
        case probe(RemoteProbe), installed(String), stored(String), removed, error(String)
    }

    /// A reply addressed to this connection, or nil for anything else (login-script output).
    public static func reply(_ line: Substring, nonce: String) -> Reply? {
        let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard fields.count >= 2, fields[0] == replyPrefix + nonce else { return nil }
        switch fields[1] {
        case "PROBE":
            guard fields.count >= 6, fields[2] == "1" else { return nil }
            let installed = Set(fields.dropFirst(6).filter { $0.utf8.count == 16 && $0.utf8.allSatisfy(isLowerHex) })
            return .probe(RemoteProbe(system: fields[3], machine: fields[4], checksumTool: fields[5] == "none" ? nil : fields[5], installed: installed))
        case "INSTALLED": return fields.count == 3 ? .installed(fields[2]) : nil
        case "STORED": return fields.count == 3 ? .stored(fields[2]) : nil
        case "REMOVED": return .removed
        case "ERROR": return .error(fields.count >= 3 ? fields[2] : "UNKNOWN")
        default: return nil
        }
    }
}

/// This state directory's identity on remote hosts (FR-RW13): a random 128-bit ID in `remote-client.json`, mode 0600.
/// It names the remote broker this Mac uses, so two Macs (or two state directories) never share sessions.
public enum RemoteClientIdentity {
    public static let fileName = "remote-client.json"
    private struct Document: Codable { var clientID: String }

    /// Created only when absent. A file that can't be read or parsed is never replaced: it names the brokers holding this
    /// Mac's remote sessions, so this throws and remote workspaces stay unavailable until it is repaired or removed.
    public static func load(stateDirectory: URL) throws -> String {
        let url = stateDirectory.appendingPathComponent(fileName)
        if let data = try LibraryFile.read(url, limit: 4096) {
            guard let document = try? JSONDecoder().decode(Document.self, from: data), RemoteBootstrap.isNonce(document.clientID) else { throw HostLibraryError.readOnly }
            return document.clientID
        }
        let id = randomHex()
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(Document(clientID: id)).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return id
    }

    public static func randomHex() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<2).map { _ in String(format: "%016llx", generator.next() as UInt64) }.joined()
    }
}
