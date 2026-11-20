import AppKit
import Foundation
import TrellisCore
import UniformTypeIdentifiers

/// What a drop on the Files view carries: files on this Mac (from Finder, or a local row), or rows of a host's tree.
public enum FilesDropSource: Equatable, Sendable {
    case local([String])
    case host(UUID, [String])

    var paths: [String] {
        switch self {
        case .local(let paths), .host(_, let paths): paths
        }
    }
    var hostID: UUID? { if case .host(let id, _) = self { id } else { nil } }
}

/// A host's rows on the pasteboard, for drops inside Trellis (FR-FB14): which host, and the paths there.
struct FilesDragPayload: Codable, Equatable {
    var host: UUID
    var paths: [String]
}

extension UTType {
    /// Rows of a host's Files tree being dragged inside Trellis.
    static let trellisFilesEntry = UTType(exportedAs: "com.bearstouch.trellis.files-entry")
}

extension NSPasteboard.PasteboardType {
    static let trellisFilesEntry = NSPasteboard.PasteboardType(UTType.trellisFilesEntry.identifier)
}

extension AppWorkspaceModel {
    /// Whether the tree shown takes dropped files: this Mac's always, a host's when its helper writes (FR-RW20).
    public var filesAcceptsDrops: Bool {
        guard files.root != nil else { return false }
        guard let host = files.host else { return true }
        return remoteFiles(host.id)?.writes == true
    }

    /// The folder line hovered by a drag, outlined (FR-FB10); nil when none is.
    public func setFilesDropTarget(_ folder: String?) { filesBrowser.setDropTarget(folder) }

    /// Reads what a drop carries: a host's rows when they came from Trellis, else the files' URLs on this Mac.
    func filesDropSource(from providers: [NSItemProvider]) async -> FilesDropSource? {
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.trellisFilesEntry.identifier) {
            if let data = await Self.load(provider, type: UTType.trellisFilesEntry), let payload = try? JSONDecoder().decode(FilesDragPayload.self, from: data) {
                return .host(payload.host, payload.paths)
            }
        }
        var paths: [String] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            if let data = await Self.load(provider, type: .fileURL), let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL { paths.append(url.path) }
        }
        return paths.isEmpty ? nil : .local(paths)
    }

    private static func load(_ provider: NSItemProvider, type: UTType) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in continuation.resume(returning: data) }
        }
    }

    /// A drop on the Files view (FR-FB10, FR-FB14), from its drop targets.
    func dropIntoFiles(_ providers: [NSItemProvider], folder: String, move: Bool) async {
        // `folder` is a line of the tree shown at the drop: never written into another pane's or host's tree shown since.
        let paneID = files.paneID, host = files.host
        guard let source = await filesDropSource(from: providers), files.paneID == paneID, files.host == host else { return }
        await dropIntoFiles(source, folder: folder, move: move)
    }

    /// Copies (or, on the same machine with `move`, moves) the dropped items into `folder` of the tree shown, then reads the
    /// tree again and selects the first one. A host's helper older than protocol 6 is never asked to write.
    @discardableResult
    public func dropIntoFiles(_ source: FilesDropSource, folder: String, move: Bool) async -> FileTransferReport? {
        guard let paneID = files.paneID, files.root != nil else { return nil }
        let host = files.host
        let destination: any TransferDestination
        if let host {
            guard let access = remoteFiles(host.id) else {
                showFilesStatus(L("Not connected to %@.", host.name))
                return nil
            }
            guard access.writes, let writer = access.transferDestination() else {
                files.notice = L("Update the Trellis helper on %@ to copy files to it.", host.name)
                return nil
            }
            destination = writer
        } else {
            destination = LocalTransferEndpoint()
        }
        let reader: any TransferSource
        switch source {
        case .local: reader = LocalTransferEndpoint()
        case .host(let id, _):
            guard let access = remoteFiles(id), let found = access.transferSource() else {
                showFilesStatus(L("Not connected to %@.", remoteHostName(id)))
                return nil
            }
            reader = found
        }
        let sameMachine = source.hostID == host?.id
        let moving = move && sameMachine
        let name = (folder as NSString).lastPathComponent
        let title = moving ? L("Moving to %@", name) : L("Copying to %@", name)
        let paths = source.paths, limits = fileTransferLimits, bothLocal = host == nil && source.hostID == nil
        let task = fileTransfers.start(title: title, upload: host != nil) { resolve, report in
            let run = FileTransferRun(source: reader, destination: destination, sameMachine: sameMachine, bothLocal: bothLocal, limits: limits, resolve: resolve, progress: report)
            return moving ? await run.move(paths, into: folder) : await run.copy(paths, into: folder)
        }
        let result = await task.value
        await finishFilesDrop(result, folder: folder, moved: moving, paneID: paneID, host: host)
        return result
    }

    private func finishFilesDrop(_ report: FileTransferReport, folder: String, moved: Bool, paneID: UUID, host: FilesHost?) async {
        if files.paneID == paneID, files.host == host {
            await refreshFiles(paneID: paneID)
            if folder != files.root, !files.expanded.contains(folder), files.rows.contains(where: { $0.entry.path == folder }) { await toggleFilesFolder(folder) }
            if let placed = report.firstPlaced { selectFile(placed) }
        }
        showFilesStatus(Self.transferSummary(report, folder: (folder as NSString).lastPathComponent, moved: moved))
    }

    /// The words the status line says after a copy (FR-FB10, FR-FB13).
    nonisolated static func transferSummary(_ report: FileTransferReport, folder: String, moved: Bool) -> String {
        switch report.stopped {
        case .tooLarge?, .tooManyItems?: return L("Nothing was copied: one drag copies at most 2 GB and 10,000 items.")
        case .disconnected?: return L("The host disconnected; %d copied before it did.", report.copied)
        case let failure?: return L("Nothing was copied: %@", reason(failure))
        case nil: break
        }
        var parts: [String] = []
        if report.cancelled {
            parts.append(L("Stopped after %d copied", report.copied))
        } else if moved {
            parts.append(report.copied == 1 ? L("Moved 1 item to %@", folder) : L("Moved %1$d items to %2$@", report.copied, folder))
        } else {
            parts.append(report.copied == 1 ? L("Copied 1 item to %@", folder) : L("Copied %1$d items to %2$@", report.copied, folder))
        }
        if report.skipped > 0 { parts.append(L("%d skipped", report.skipped)) }
        if report.linksSkipped > 0 { parts.append(L("%d links not copied", report.linksSkipped)) }
        if let first = report.failures.sorted(by: { $0.key < $1.key }).first {
            parts.append(
                report.failures.count == 1
                    ? L("%1$@ failed: %2$@", (first.key as NSString).lastPathComponent, reason(first.value))
                    : L("%1$d failed, first %2$@: %3$@", report.failures.count, (first.key as NSString).lastPathComponent, reason(first.value)))
        }
        return parts.joined(separator: " · ")
    }

    nonisolated static func reason(_ failure: FileTransferFailure) -> String {
        switch failure {
        case .changed: L("it changed while it was copied")
        case .exists: L("the name is taken")
        case .intoItself: L("a folder can't go into itself")
        case .missing: L("it is no longer there")
        case .unreadable: L("it can't be read")
        case .noSpace: L("the disk is full")
        case .crossDevice: L("it is on another disk")
        case .notAllowed: L("not allowed")
        case .disconnected: L("the host disconnected")
        case .tooLarge, .tooManyItems: L("too large")
        case .unwritable: L("it can't be written there")
        }
    }

    /// A host's row dropped on Finder (FR-FB11): copied into the folder Finder names, beside anything of the same name.
    func downloadForPromise(hostID: UUID, path: String, to folder: String) async -> FileTransferFailure? {
        guard let source = remoteFiles(hostID)?.transferSource() else { return .disconnected }
        let limits = fileTransferLimits, name = (path as NSString).lastPathComponent
        let task = fileTransfers.start(title: L("Copying %@ to this Mac", name), upload: false) { _, report in
            let run = FileTransferRun(
                source: source, destination: LocalTransferEndpoint(), sameMachine: false, limits: limits, resolve: { _ in FileTransferDecision(.keepBoth, applyToAll: true) },
                progress: report)
            return await run.copy([path], into: folder)
        }
        let report = await task.value
        if report.cancelled { return .notAllowed }
        if let failure = report.stopped ?? report.failures.values.first {
            showFilesStatus(Self.transferSummary(report, folder: (folder as NSString).lastPathComponent, moved: false))
            return failure
        }
        // Nothing written: a link or a special file, which aren't copied from a host. Finder is told the promise failed
        // instead of being left waiting for a file that never comes.
        guard report.copied > 0 else {
            showFilesStatus(report.linksSkipped > 0 ? L("%@ is a link; links aren't copied from a host.", name) : L("%@ can't be copied: it isn't a file or a folder.", name))
            return .notAllowed
        }
        showFilesStatus(Self.transferSummary(report, folder: (folder as NSString).lastPathComponent, moved: false))
        return nil
    }
}
