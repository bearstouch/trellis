import AppKit
import Combine
import UTermCore
import UTermTerminal

@MainActor
public final class ThemePreviewModel: ObservableObject {
    @Published public private(set) var theme = ResolvedTheme.builtIn(.light)
    @Published public private(set) var validationMessage: String?
    @Published public private(set) var loading = false
    @Published public private(set) var document: ThemeDocument?
    public let terminal = NativeTerminal()
    private var loadGeneration = UUID()
    var contentGeneration: UUID { loadGeneration }
    public init() {
        terminal.view.setAccessibilityLabel("Theme preview terminal — sample output only")
        var sample = "uTerm color preview\r\ncafé e\u{301} 漢字 👩‍💻\r\n"
        for row in 0..<2 {
            for index in (row * 8)..<(row * 8 + 8) {
                sample += "\u{1b}[38;5;\(index)m\(String(format: "%02d", index))  "
            }
            sample += "\u{1b}[0m\r\n"
        }
        sample += "Default text · Select and copy\r\n"
        terminal.adapter.receive(Data(sample.utf8))
        terminal.applyPalette(theme.terminal)
    }
    @discardableResult
    public func preview(_ data: Data) -> Bool {
        loadGeneration = UUID()
        loading = false
        do {
            let document = try ThemeValidator.validate(data)
            let resolved = document.resolved()
            terminal.applyPalette(resolved.terminal)
            theme = resolved
            self.document = document
            validationMessage = nil
            return true
        } catch {
            validationMessage = error.localizedDescription
            return false
        }
    }
    public func example(_ example: ThemeExample) {
        do { _ = preview(try ThemeExamples.data(example)) }
        catch { validationMessage = "The bundled example could not be loaded." }
    }
    public func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "Preview a JSON Theme"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let generation = UUID(); loadGeneration = generation; loading = true
        Task {
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    let info = try url.resourceValues(forKeys: [.isRegularFileKey])
                    guard info.isRegularFile == true else { throw CocoaError(.fileReadUnsupportedScheme) }
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    var data = Data()
                    let limit = ThemeValidator.maximumBytes + 1
                    while data.count < limit {
                        guard let chunk = try handle.read(upToCount: limit - data.count), !chunk.isEmpty else { break }
                        data.append(chunk)
                    }
                    return data
                }.value
                guard generation == loadGeneration else { return }
                _ = preview(data)
            } catch {
                guard generation == loadGeneration else { return }
                loading = false
                validationMessage = "The theme file could not be read. Choose a readable local JSON file."
            }
        }
    }
}
