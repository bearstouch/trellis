import SwiftUI
import TrellisControl
import TrellisCore

/// Review before any change: counts, launch references, host collisions, and
/// an explicit collision policy. Import stays disabled until it is valid.
public struct ImportPreviewView: View {
    private let transfer: PortableTransfer
    private let parsed: PortableDocument.Parsed
    private let preview: PortableDocument.Preview
    private let close: () -> Void
    @State private var policy: HostCollisionPolicy?
    @State private var message: String?
    @State private var importing = false
    @State private var done = false

    public init(transfer: PortableTransfer, parsed: PortableDocument.Parsed, preview: PortableDocument.Preview, close: @escaping () -> Void) {
        self.transfer = transfer; self.parsed = parsed; self.preview = preview; self.close = close
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Import Windows & Hosts").font(.headline)
            Text("\(preview.windows) window(s), \(preview.tabs) tab(s), \(preview.panes) pane(s), \(preview.hosts) saved host(s)" + (preview.projects > 0 ? ", \(preview.projects) project(s)" : ""))
            Text("Everything imports with new IDs. Panes start stopped; nothing runs until you start it.").font(.caption).foregroundStyle(.secondary)
            if !preview.directories.isEmpty {
                Text("Directories: " + preview.directories.joined(separator: ", ")).font(.caption).lineLimit(3)
            }
            if !preview.hostReferences.isEmpty {
                Text("Hosts used by panes: " + preview.hostReferences.joined(separator: ", ")).font(.caption).lineLimit(3)
            }
            if !preview.errors.isEmpty {
                ForEach(Array(preview.errors.enumerated()), id: \.offset) { _, issue in
                    Label(issue.message, systemImage: "exclamationmark.triangle").font(.caption)
                }
            }
            if !preview.collisions.isEmpty {
                Text("\(preview.collisions.count) imported host(s) match hosts you already have (same destination or name).").font(.callout)
                Text(preview.collisionDetails.joined(separator: "\n")).font(.caption).lineLimit(6)
                Picker("Matching hosts", selection: $policy) {
                    Text("Choose…").tag(HostCollisionPolicy?.none)
                    ForEach(HostCollisionPolicy.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                }
                .accessibilityHint("Required before importing")
            }
            if let message { Text(message).font(.caption).accessibilityIdentifier("import.result") }
            HStack {
                Spacer()
                Button(done ? "Done" : "Cancel") { close() }.keyboardShortcut(.cancelAction)
                if !done {
                    Button("Import") { run() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(importing || !preview.errors.isEmpty || (!preview.collisions.isEmpty && policy == nil))
                }
            }
        }
        .padding(20).frame(width: 520)
    }

    private func run() {
        importing = true
        Task {
            switch await transfer.commit(parsed, policy: policy) {
            case .success(let summary):
                message = "Imported \(summary.windows) window(s); \(summary.hostsCreated) host(s) added, \(summary.hostsReplaced) replaced."
                done = true
            case .failure(let error): message = error.message
            }
            importing = false
        }
    }
}
