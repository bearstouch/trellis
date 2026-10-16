import SwiftUI
import TrellisCore

/// Previews literal aliases from ~/.ssh/config. Nothing is saved until the user
/// confirms a selection, and the SSH configuration itself is only read.
struct AliasDiscoveryView: View {
    @ObservedObject var model: HostListModel
    @Environment(\.dismiss) private var dismiss
    @State private var outcome: Result<SSHConfigDiscovery.Result, SSHConfigDiscovery.Failure>?
    @State private var selected = Set<String>()
    @State private var message: String?
    @State private var adding = false

    private var saved: Set<String> { Set(model.hosts.map(\.destination)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Discover SSH Aliases").font(.headline)
            Text("Reads literal Host names from ~/.ssh/config without changing it. Each alias is saved as its destination, so ssh keeps applying your configuration.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            switch outcome {
            case nil: ProgressView("Reading ~/.ssh/config…")
            case .failure(let failure):
                Text(HostListModel.message(for: failure)).fixedSize(horizontal: false, vertical: true)
                Button("Try Again") { Task { await load() } }
            case .success(let result):
                if result.aliases.isEmpty {
                    Text("No literal aliases were found.").foregroundStyle(.secondary)
                } else {
                    List(result.aliases, id: \.name) { alias in
                        let exists = saved.contains(alias.name)
                        Toggle(isOn: binding(alias.name)) {
                            HStack {
                                Text(alias.name)
                                Spacer()
                                Text(exists ? "Already saved" : "Line \(alias.line)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .disabled(exists)
                        .accessibilityValue(exists ? "Already saved" : selected.contains(alias.name) ? "Selected" : "Not selected")
                    }
                    .frame(minHeight: 160).accessibilityLabel("Discovered aliases")
                }
                if !result.warnings.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(result.warnings.enumerated()), id: \.offset) { _, warning in
                            Label(warning.description, systemImage: "info.circle").font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            if let message { Text(message).font(.caption) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add \(selected.count) Selected") { add() }
                    .keyboardShortcut(.defaultAction).disabled(selected.isEmpty || adding)
            }
        }
        .padding(20).frame(width: 520)
        .task { await load() }
    }

    private func binding(_ name: String) -> Binding<Bool> {
        Binding(
            get: { selected.contains(name) },
            set: { if $0 { selected.insert(name) } else { selected.remove(name) } })
    }

    private func load() async {
        outcome = nil
        let next = await model.discoverAliases()
        outcome = next
        selected = []
    }

    private func add() {
        adding = true
        let names = selected.filter { !saved.contains($0) }.sorted()
        Task {
            if let failure = await model.importAliases(names) {
                if case .invalid = failure {
                    message = "A selected alias cannot be saved as a destination. Nothing was added; deselect it or add it manually."
                } else {
                    message = HostListModel.message(for: failure)
                }
                adding = false
            } else {
                dismiss()
            }
        }
    }
}
