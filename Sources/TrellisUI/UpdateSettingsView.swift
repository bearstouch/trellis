import Foundation
import SwiftUI
import TrellisCore

/// The app's updater (Sparkle in packaged builds, MAC-14); views and tests never see the engine.
@MainActor public protocol SoftwareUpdater: AnyObject {
    var canCheckForUpdates: Bool { get }
    var automaticallyChecksForUpdates: Bool { get set }
    var includesBetas: Bool { get set }
    var lastUpdateCheckDate: Date? { get }
    /// Called when the values above change outside a setter, such as a check starting or finishing.
    var onChange: (() -> Void)? { get set }
    func checkForUpdates()
}

@MainActor public final class UpdateSettingsModel: ObservableObject {
    @Published public private(set) var canCheck = false
    @Published public private(set) var automaticChecks = false
    @Published public private(set) var includeBetas = false
    @Published public private(set) var lastCheck: Date?
    public let version: String
    private let updater: SoftwareUpdater

    public init(updater: SoftwareUpdater, version: String = AppVersion.current) {
        self.updater = updater; self.version = version
        updater.onChange = { [weak self] in self?.refresh() }
        refresh()
    }

    public func refresh() {
        canCheck = updater.canCheckForUpdates; automaticChecks = updater.automaticallyChecksForUpdates
        includeBetas = updater.includesBetas; lastCheck = updater.lastUpdateCheckDate
    }
    public func setAutomaticChecks(_ enabled: Bool) { updater.automaticallyChecksForUpdates = enabled; refresh() }
    public func setIncludeBetas(_ enabled: Bool) { updater.includesBetas = enabled; refresh() }
    public func checkNow() {
        guard updater.canCheckForUpdates else { return }
        updater.checkForUpdates(); refresh()
    }
}

struct UpdateSettingsView: View {
    @ObservedObject var updates: UpdateSettingsModel
    var body: some View {
        Form {
            LabeledContent("Current version", value: updates.version).accessibilityIdentifier("settings.updates.version")
            Toggle("Automatically check for updates", isOn: Binding(get: { updates.automaticChecks }, set: { updates.setAutomaticChecks($0) }))
                .accessibilityIdentifier("settings.updates.automatic")
            caption("Checks once a day. Trellis only downloads the update list; it sends no usage data.")
            Toggle("Include beta versions", isOn: Binding(get: { updates.includeBetas }, set: { updates.setIncludeBetas($0) }))
                .accessibilityIdentifier("settings.updates.betas")
            caption("Offers pre-release builds as well as stable ones.")
            HStack {
                Text(lastCheckText).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("settings.updates.lastCheck")
                Spacer()
                Button("Check Now") { updates.checkNow() }.disabled(!updates.canCheck).accessibilityIdentifier("settings.updates.checkNow")
            }
        }
        .onAppear { updates.refresh() }
    }
    private var lastCheckText: String {
        guard let date = updates.lastCheck else { return "Never checked" }
        return "Last checked \(date.formatted(date: .abbreviated, time: .shortened))"
    }
    private func caption(_ text: String) -> some View { Text(text).font(.caption).foregroundStyle(.secondary).wrappingSettingsCaption() }
}
