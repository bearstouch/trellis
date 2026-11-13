import SwiftUI
import TrellisControl
import TrellisCore

/// Review before any change: counts, host and project collisions, and an
/// explicit host collision policy. Import stays disabled until it is valid.
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
            Text(L("Import Projects & Hosts")).font(.headline)
            Text(L("%1$d project(s), %2$d saved host(s)", Int(preview.projects), Int(preview.hosts)))
            Text(L("Everything imports with new IDs. Nothing opens or runs until you launch a project.")).font(.caption).foregroundStyle(.secondary)
            if preview.skippedSpaces > 0 {
                Label(
                    L("This file was made by an older Trellis; its %d window(s) are not imported. Spaces now come from projects.", Int(preview.skippedSpaces)),
                    systemImage: "info.circle"
                ).font(.caption)
            }
            if !preview.projectCollisions.isEmpty {
                Text(L("You already have project(s) named %@; they're added as copies named “… (imported)”.", preview.projectCollisions.map { "“\($0)”" }.joined(separator: ", ")))
                    .font(.caption).lineLimit(4)
            }
            if !preview.errors.isEmpty {
                ForEach(Array(preview.errors.enumerated()), id: \.offset) { _, issue in
                    Label(issue.message, systemImage: "exclamationmark.triangle").font(.caption)
                }
            }
            if !preview.collisions.isEmpty {
                Text(L("%d imported host(s) match hosts you already have (same destination or name).", preview.collisions.count)).font(.callout)
                Text(preview.collisionDetails.joined(separator: "\n")).font(.caption).lineLimit(6)
                Picker(L("Matching hosts"), selection: $policy) {
                    Text(L("Choose…")).tag(HostCollisionPolicy?.none)
                    ForEach(HostCollisionPolicy.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                }
                .accessibilityHint(L("Required before importing"))
            }
            if let message { Text(message).font(.caption).accessibilityIdentifier("import.result") }
            HStack {
                Spacer()
                Button(done ? L("Done") : L("Cancel")) { close() }.keyboardShortcut(.cancelAction)
                if !done {
                    Button(L("Import")) { run() }
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
                message = L("Imported %1$d project(s); %2$d host(s) added, %3$d replaced.", Int(summary.projectsCreated), summary.hostsCreated, summary.hostsReplaced)
                done = true
            case .failure(let error): message = error.message
            }
            importing = false
        }
    }
}
