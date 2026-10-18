import Darwin
import Foundation

/// FR-R04: the opt-in scrollback file, `<state>/Scrollback/<session-uuid>.txt`. Text is redacted (FR-R05) and then
/// cut to the newest `fileLimit` bytes; files are 0600 in a 0700 directory, written atomically, read without following
/// symlinks. Only plain text is stored: no escape sequences, no input, never output from a session that isn't saved.
public actor ScrollbackStore {
    public static let fileLimit = 1_048_576
    public static let totalLimit = 64 * 1_048_576
    public nonisolated let directory: URL
    private let fileManager = FileManager.default

    public init(directory: URL) { self.directory = directory }

    private func url(_ sessionID: UUID) -> URL { directory.appendingPathComponent("\(sessionID.uuidString).txt") }

    /// The newest text within `limit` UTF-8 bytes, starting on a line when it has to be cut.
    static func tail(_ text: String, limit: Int) -> String {
        let bytes = Array(text.utf8)
        guard bytes.count > limit else { return text }
        var start = bytes.count - limit
        while start < bytes.count, bytes[start] & 0xC0 == 0x80 { start += 1 }
        if let newline = bytes[start...].firstIndex(of: 0x0a) { start = newline + 1 }
        return String(decoding: bytes[start...], as: UTF8.self)
    }

    private func ensureDirectory() throws {
        var info = stat()
        if lstat(directory.path, &info) == 0 {
            // Never write through a symlinked or shared directory.
            guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid() else { throw WorkspacePersistenceError.corrupt }
            if info.st_mode & 0o077 != 0 { guard chmod(directory.path, 0o700) == 0 else { throw WorkspacePersistenceError.io(errno) } }
            return
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    /// Saves every pane's text and removes any other file, keeping the total under `totalLimit`
    /// (sessions after the budget is spent are not saved). Returns the sessions written.
    @discardableResult
    public func replaceAll(_ texts: [(sessionID: UUID, text: String)]) -> Set<UUID> {
        var written = Set<UUID>()
        var used = 0
        if !texts.isEmpty, (try? ensureDirectory()) != nil {
            for (sessionID, text) in texts {
                // Redaction sees a little more than is kept, so a secret cut at the limit is still recognised.
                let data = Data(Self.tail(ScrollbackRedactor.redact(Self.tail(text, limit: 2 * Self.fileLimit)), limit: Self.fileLimit).utf8)
                guard !data.isEmpty, used + data.count <= Self.totalLimit else { continue }
                if (try? OwnerOnlyStorage.atomicWrite(data, to: url(sessionID), temporaryPrefix: ".scrollback.")) != nil {
                    used += data.count
                    written.insert(sessionID)
                }
            }
        }
        retain(written)
        return written
    }

    public func load(sessionID: UUID) -> (text: String, savedAt: Date)? {
        guard let data = try? OwnerOnlyStorage.read(url(sessionID), limit: Self.fileLimit), !data.isEmpty else { return nil }
        let attributes = try? fileManager.attributesOfItem(atPath: url(sessionID).path)
        let saved = attributes?[.modificationDate] as? Date ?? Date()
        return (String(decoding: data, as: UTF8.self), saved)
    }

    public func delete(sessionIDs: some Sequence<UUID>) {
        for id in sessionIDs { unlink(url(id).path) }
    }

    /// Removes every file except those of `sessionIDs`; only names this store writes are touched.
    public func retain(_ sessionIDs: Set<UUID>) {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names {
            let isTemporary = name.hasPrefix(".scrollback.") && name.hasSuffix(".tmp")
            guard isTemporary || name.hasSuffix(".txt") else { continue }
            if !isTemporary, let id = UUID(uuidString: String(name.dropLast(4))), sessionIDs.contains(id) { continue }
            unlink(directory.appendingPathComponent(name).path)
        }
    }

    public func deleteAll() {
        retain([])
        rmdir(directory.path)
    }
}
