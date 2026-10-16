import Foundation
import SwiftUI
import TrellisControl
import TrellisCore

/// Builds the allow-listed diagnostics report and writes it only after the
/// user previews it and chooses a location. There is no network path.
@MainActor
public final class DiagnosticsExporter {
    private let model: AppWorkspaceModel
    private let hosts: HostListModel
    private let grants: GrantListModel?
    private let controlRunning: () -> Bool

    public init(model: AppWorkspaceModel, hosts: HostListModel, grants: GrantListModel?, controlRunning: @escaping () -> Bool) {
        self.model = model; self.hosts = hosts; self.grants = grants; self.controlRunning = controlRunning
    }

    public func report() async -> DiagnosticsReport {
        let info = ProcessInfo.processInfo
        var report = DiagnosticsReport(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
            systemVersion: info.operatingSystemVersionString, architecture: Self.architecture)
        report.count(model.snapshot)
        report.savedHosts = await hosts.library.hosts.count
        if let grants {
            await grants.refresh()
            report.activeGrants = grants.grants.filter { $0.isActive(at: grants.now) }.count
        }
        report.customThemes = model.themeCatalog.documents.count
        report.appearanceMode = model.appearance.chromeMode.rawValue
        report.controlSocketRunning = controlRunning()
        report.recentErrorCodes = model.diagnosticCodes
        return report
    }

    /// `present` shows the exact text and returns a destination, or nil when
    /// the user cancels. Nothing is written unless a destination is returned.
    @discardableResult
    public func export(present: (String) async -> URL?, write: (Data, URL) throws -> Void) async -> Bool {
        let text = await report().text
        guard let destination = await present(text) else { return false }
        do {
            try write(Data(text.utf8), destination)
            return true
        } catch { return false }
    }

    private static var architecture: String {
        #if arch(arm64)
            "arm64"
        #else
            "x86_64"
        #endif
    }
}

/// Read-only preview of the exact report text.
public struct DiagnosticsPreviewView: View {
    let text: String
    let save: () -> Void
    let cancel: () -> Void
    public init(text: String, save: @escaping () -> Void, cancel: @escaping () -> Void) { self.text = text; self.save = save; self.cancel = cancel }
    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Export Diagnostics").font(.headline)
            Text("This is exactly what will be saved. Nothing is sent anywhere.").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 220).accessibilityLabel("Diagnostics report")
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Save…", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 520)
    }
}
