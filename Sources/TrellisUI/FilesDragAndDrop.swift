import AppKit
import SwiftUI
import TrellisCore
import UniformTypeIdentifiers

// MARK: Drops on the tree (FR-FB10, FR-FB14)

/// A drop on a folder line copies into that folder; on a file line, into its folder; on the list, into the root. ⌘ moves
/// within one machine. The folder taking the drop is outlined while a drag hovers it.
struct FilesDropDelegate: DropDelegate {
    let model: AppWorkspaceModel
    let folder: String
    static let types: [UTType] = [.trellisFilesEntry, .fileURL]

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: Self.types) }
    func dropEntered(info: DropInfo) { model.setFilesDropTarget(folder) }
    func dropExited(info: DropInfo) { model.setFilesDropTarget(nil) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        model.setFilesDropTarget(folder)
        guard model.filesAcceptsDrops else { return DropProposal(operation: .forbidden) }
        return DropProposal(operation: NSEvent.modifierFlags.contains(.command) ? .move : .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        model.setFilesDropTarget(nil)
        let move = NSEvent.modifierFlags.contains(.command)
        let providers = info.itemProviders(for: Self.types)
        let model = model, folder = folder
        Task { await model.dropIntoFiles(providers, folder: folder, move: move) }
        return true
    }
}

// MARK: Dragging a host's rows out (FR-FB11)

/// What a host's row drags: the host, the path, and the model that copies it when Finder takes the promise.
@MainActor struct RemoteRowDrag {
    weak var model: AppWorkspaceModel?
    let entry: FileEntry
}

/// Behind each of a host's rows, never hit by the mouse: it only knows where the row is, so a drag starting over it can
/// carry a file promise, which Finder needs to receive a file that isn't on this Mac and SwiftUI's `onDrag` can't make.
struct RemoteRowDragAnchor: NSViewRepresentable {
    let drag: RemoteRowDrag

    func makeNSView(context: Context) -> RemoteRowAnchorView {
        let view = RemoteRowAnchorView()
        view.drag = drag
        return view
    }

    func updateNSView(_ view: RemoteRowAnchorView, context: Context) { view.drag = drag }
}

final class RemoteRowAnchorView: NSView, NSDraggingSource {
    var drag: RemoteRowDrag?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { RemoteRowDragMonitor.shared.register(self) }
    }

    func contains(_ event: NSEvent) -> Bool {
        guard event.window === window, !isHiddenOrHasHiddenAncestor else { return false }
        let point = convert(event.locationInWindow, from: nil)
        return visibleRect.contains(point)
    }

    func beginDrag(with event: NSEvent) {
        guard let drag, let model = drag.model, let host = model.files.host else { return }
        let entry = drag.entry
        let writer = RemotePromiseWriter(model: model, hostID: host.id, path: entry.path)
        let provider = RemoteFilePromiseProvider(fileType: entry.isDirectory ? UTType.folder.identifier : UTType.data.identifier, delegate: writer)
        provider.writer = writer
        provider.path = entry.path
        provider.payload = (try? JSONEncoder().encode(FilesDragPayload(host: host.id, paths: [entry.path]))) ?? Data()
        let item = NSDraggingItem(pasteboardWriter: provider)
        let icon = NSWorkspace.shared.icon(for: entry.isDirectory ? .folder : (UTType(filenameExtension: (entry.name as NSString).pathExtension) ?? .data))
        let side = min(bounds.height, 24)
        item.setDraggingFrame(NSRect(x: 0, y: (bounds.height - side) / 2, width: side, height: side), contents: icon)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Inside Trellis a ⌘ drop moves on the host; outside, Finder only receives a copy.
        context == .withinApplication ? [.copy, .move] : .copy
    }
}

/// Starts a host row's drag when the mouse moves a few points from a press over one: the anchors never take clicks, so
/// selection, double clicks and the context menu stay SwiftUI's.
@MainActor final class RemoteRowDragMonitor {
    static let shared = RemoteRowDragMonitor()
    private let anchors = NSHashTable<RemoteRowAnchorView>.weakObjects()
    private var monitor: Any?
    private var pressed: (location: NSPoint, anchor: RemoteRowAnchorView)?

    func register(_ anchor: RemoteRowAnchorView) {
        anchors.add(anchor)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { event in
            // Local monitors run on the main thread.
            nonisolated(unsafe) let event = event
            let passed = MainActor.assumeIsolated { RemoteRowDragMonitor.shared.handle(event) }
            return passed ? event : nil
        }
    }

    /// False when the event started a drag and is taken.
    private func handle(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown:
            pressed = anchors.allObjects.first { $0.drag != nil && $0.contains(event) }.map { (event.locationInWindow, $0) }
            return true
        case .leftMouseDragged:
            guard let pressed, pressed.anchor.window === event.window else { return true }
            let moved = hypot(event.locationInWindow.x - pressed.location.x, event.locationInWindow.y - pressed.location.y)
            guard moved >= 4 else { return true }
            self.pressed = nil
            pressed.anchor.beginDrag(with: event)
            return false
        default:
            pressed = nil
            return true
        }
    }
}

/// A file promise that also carries the host's path as text (a pane or a text field takes it) and the row for drops
/// inside Trellis.
final class RemoteFilePromiseProvider: NSFilePromiseProvider {
    /// The delegate is weak; the provider keeps it for as long as the drag needs it.
    var writer: RemotePromiseWriter?
    var path = ""
    var payload = Data()

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [.trellisFilesEntry, .string]
    }

    override func writingOptions(forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        type == .trellisFilesEntry || type == .string ? [] : super.writingOptions(forType: type, pasteboard: pasteboard)
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        switch type {
        case .trellisFilesEntry: payload
        case .string: path
        default: super.pasteboardPropertyList(forType: type)
        }
    }
}

/// Copies the host's file or folder into the folder Finder names once it is dropped there.
final class RemotePromiseWriter: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {
    private weak var model: AppWorkspaceModel?
    private let hostID: UUID
    private let path: String
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    @MainActor init(model: AppWorkspaceModel, hostID: UUID, path: String) {
        self.model = model; self.hostID = hostID; self.path = path
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String { (path as NSString).lastPathComponent }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { queue }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        let folder = url.deletingLastPathComponent().path, hostID = hostID, path = path
        let done = Completion(completionHandler)
        // Waits here for the copy, so the drag's queue knows when the promise is kept.
        let finished = DispatchSemaphore(value: 0)
        Task { @MainActor [weak model] in
            let failure: FileTransferFailure? = if let model { await model.downloadForPromise(hostID: hostID, path: path, to: folder) } else { .disconnected }
            done.call(failure.map { NSError(domain: "Trellis.FileTransfer", code: 1, userInfo: [NSLocalizedDescriptionKey: AppWorkspaceModel.reason($0)]) })
            finished.signal()
        }
        finished.wait()
    }

    private final class Completion: @unchecked Sendable {
        let handler: (Error?) -> Void
        init(_ handler: @escaping (Error?) -> Void) { self.handler = handler }
        func call(_ error: Error?) { handler(error) }
    }
}

// MARK: Progress and conflicts (FR-FB12, FR-FB13)

/// The running copies above the footer, each with a Cancel button, and the sheet asking about a taken name.
struct FilesTransferPanel: View {
    @ObservedObject var center: FileTransferCenter
    let palette: FilesPalette

    var body: some View {
        VStack(spacing: 6) {
            ForEach(center.runs.prefix(3)) { run in line(run) }
            if center.runs.count > 3 {
                Text(L("and %d more", center.runs.count - 3)).font(.caption).foregroundStyle(palette.muted).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12).padding(.bottom, center.runs.isEmpty ? 0 : 6)
        // Answered only from the sheet's buttons (Esc is Stop Copying), each for its own prompt: a dismissal while the next
        // conflict replaces it must never stop that other copy.
        .sheet(item: Binding(get: { center.prompt }, set: { _ in })) { prompt in
            FilesConflictSheet(conflict: prompt.conflict) { center.answer($0, to: prompt.id) }
        }
    }

    private func line(_ run: FileTransferCenter.Run) -> some View {
        let progress = run.progress
        let bytes = ByteCountFormatter.string(fromByteCount: progress.bytesDone, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: progress.bytesTotal, countStyle: .file)
        return HStack(spacing: 8) {
            Image(systemName: run.upload ? "arrow.up.circle" : "arrow.down.circle").foregroundStyle(palette.muted).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(run.title).font(.caption).lineLimit(1).truncationMode(.middle)
                ProgressView(value: progress.fraction).controlSize(.small)
                Text(L("%1$d of %2$d · %3$@ of %4$@", min(progress.itemsDone, progress.itemsTotal), progress.itemsTotal, bytes, total))
                    .font(.caption2).foregroundStyle(palette.muted).lineLimit(1)
            }
            Button {
                center.cancel(run.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain).foregroundStyle(palette.muted)
            .help(L("Stop copying")).accessibilityLabel(L("Stop %@", run.title))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(run.title)
        .accessibilityValue(L("%d percent", Int(progress.fraction * 100)))
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// "“name” already exists in “folder”." with the choices the engine allows; Keep Both is the default, Esc stops copying.
struct FilesConflictSheet: View {
    let conflict: FileTransferConflict
    let answer: (FileTransferDecision?) -> Void
    @State private var applyToAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("“%1$@” already exists in “%2$@”.", conflict.name, (conflict.folder as NSString).lastPathComponent.isEmpty ? "/" : (conflict.folder as NSString).lastPathComponent))
                .font(.headline).fixedSize(horizontal: false, vertical: true)
            Text(explanation).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle(L("Apply to all"), isOn: $applyToAll)
            HStack {
                Button(L("Stop Copying"), role: .cancel) { answer(nil) }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(L("Skip")) { answer(FileTransferDecision(.skip, applyToAll: applyToAll)) }
                if conflict.choices.contains(.replace) { Button(L("Replace")) { answer(FileTransferDecision(.replace, applyToAll: applyToAll)) } }
                if conflict.choices.contains(.merge) { Button(L("Merge")) { answer(FileTransferDecision(.merge, applyToAll: applyToAll)) } }
                Button(L("Keep Both")) { answer(FileTransferDecision(.keepBoth, applyToAll: applyToAll)) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 420)
    }

    private var explanation: String {
        switch (conflict.incoming == .directory, conflict.existing == .directory) {
        case (true, true): L("Merge adds what you drop to the folder there and keeps what it already holds. Keep Both copies it beside it with a new name.")
        case (false, false):
            conflict.choices.contains(.replace)
                ? L("Replace puts the dropped file in its place. Keep Both copies it beside it with a new name.") : L("Keep Both moves it beside it with a new name.")
        default: L("A file and a folder can't replace each other. Keep Both copies it beside it with a new name.")
        }
    }
}
