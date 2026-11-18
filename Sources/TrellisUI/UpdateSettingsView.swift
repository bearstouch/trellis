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
            Section(L("Current version")) {
                LabeledContent {
                    Button(L("Check Now")) { updates.checkNow() }.disabled(!updates.canCheck).accessibilityIdentifier("settings.updates.checkNow")
                } label: {
                    SettingsLabel(updates.version, help: lastCheckText)
                }
                .accessibilityIdentifier("settings.updates.version")
            }
            Section(L("Automatic updates")) {
                Toggle(isOn: Binding(get: { updates.automaticChecks }, set: { updates.setAutomaticChecks($0) })) {
                    SettingsLabel(L("Automatically check for updates"), help: L("Checks once a day. Trellis only downloads the update list; it sends no usage data."))
                }
                .accessibilityIdentifier("settings.updates.automatic")
                Toggle(isOn: Binding(get: { updates.includeBetas }, set: { updates.setIncludeBetas($0) })) {
                    SettingsLabel(L("Include beta versions"), help: L("Offers pre-release builds as well as stable ones."))
                }
                .accessibilityIdentifier("settings.updates.betas")
            }
        }
        .settingsFormStyle()
        .onAppear { updates.refresh() }
    }
    private var lastCheckText: String {
        guard let date = updates.lastCheck else { return L("Never checked") }
        return L("Last checked %@", date.formatted(date: .abbreviated, time: .shortened))
    }
}
