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
    public init(platform: String, path: String, digest: String, fileDigest: String, fileSize: Int, compressed: Bool) {
        self.platform = platform; self.path = path; self.digest = digest; self.fileDigest = fileDigest; self.fileSize = fileSize; self.compressed = compressed
    }
    /// The install directory under `~/.trellis/remote`, one per helper build.
    public var directory: String { String(digest.prefix(16)) }

    public static func isDigest(_ value: String) -> Bool { value.utf8.count == 64 && value.utf8.allSatisfy(RemoteBootstrap.isLowerHex) }
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
/// command per line on stdin: `install <digest> <bytes> gz|raw` followed by exactly that many bytes, `bridge <digest>`,
/// `remove` or `quit`. Every reply line starts with `TRELLIS-<nonce> `, so login-script output can't forge one.
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
            while read -r cmd a b c; do
              d=$(printf '%.16s' "$a")
              case "$cmd" in
              install)
                case "$a" in *[!0-9a-f]*|'') say ERROR INVALID; exit 1 ;; esac
                case "$b" in *[!0-9]*|'') say ERROR INVALID; exit 1 ;; esac
                case "$c" in gz|raw) ;; *) say ERROR INVALID; exit 1 ;; esac
                [ "${#a}" -eq 64 ] && [ "$tool" != none ] || { say ERROR INVALID; exit 1; }
                [ "$c" = raw ] || command -v gzip >/dev/null 2>&1 || { say ERROR GZIP; exit 1; }
                mkdir -p "$R/$d" || { say ERROR MKDIR; exit 1; }
                t="$R/$d/.upload.$$"
                rm -f "$t"
                if [ "$c" = gz ]; then head -c "$b" | gzip -dc > "$t"; else head -c "$b" > "$t"; fi
                if [ "$(sum "$t")" = "$a" ] && chmod 700 "$t" && mv -f "$t" "$R/$d/trellis-broker"; then say INSTALLED "$a"; else rm -f "$t"; say ERROR DIGEST; exit 1; fi
                ;;
              bridge)
                case "$a" in *[!0-9a-f]*|'') say ERROR INVALID; exit 1 ;; esac
                [ -x "$R/$d/trellis-broker" ] || { say ERROR MISSING; exit 1; }
                exec "$R/$d/trellis-broker" bridge --client-id "$C" --sync "$N"
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
        "install \(artifact.digest) \(artifact.fileSize) \(artifact.compressed ? "gz" : "raw")\n"
    }
    public static func bridgeLine(digest: String) -> String { "bridge \(digest)\n" }
    public static let removeLine = "remove\n"
    public static let quitLine = "quit\n"

    public enum Reply: Equatable, Sendable {
        case probe(RemoteProbe), installed(String), removed, error(String)
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

    public static func load(stateDirectory: URL) throws -> String {
        let url = stateDirectory.appendingPathComponent(fileName)
        if let data = try? Data(contentsOf: url), let document = try? JSONDecoder().decode(Document.self, from: data), RemoteBootstrap.isNonce(document.clientID) {
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
