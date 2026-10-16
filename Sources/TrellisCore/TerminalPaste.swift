import Foundation

public enum TerminalPasteInput: Sendable {
    case text(String)
    case paths([String])
}

public struct TerminalPastePlan: Equatable, Sendable {
    public let text: String
    public let lineCount: Int
    public let preview: String
    public let requiresReview: Bool
    public let unsupportedShell: Bool
    public let isPath: Bool

    public init(input: TerminalPasteInput, shell: String?) {
        let text: String
        switch input {
        case .text(let value): text = value; isPath = false; unsupportedShell = false
        case .paths(let paths):
            isPath = true
            unsupportedShell = !["zsh", "bash", "sh"].contains(shell.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "")
            text = paths.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        }
        self.text = text
        var lines = 1, previousCR = false, controls = false
        var visible = "", shown = 0
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if value == 13 || value == 10 || value == 0x85 || value == 0x2028 || value == 0x2029 {
                if value != 10 || !previousCR { lines += 1 }
            }
            previousCR = value == 13
            let control = scalar.properties.generalCategory == .control
                || (scalar.properties.generalCategory == .format && value != 0x200C && value != 0x200D)
                || value == 0x2028 || value == 0x2029
            controls = controls || control
            if shown < 8192 {
                switch value {
                case 9: visible += "⟨TAB⟩"
                case 10: visible += "⟨LF⟩\n"
                case 13: visible += "⟨CR⟩\n"
                case 27: visible += "⟨ESC⟩"
                default: visible += control ? "⟨U+\(String(value, radix: 16).uppercased())⟩" : String(scalar)
                }
            }
            shown += 1
        }
        if shown > 8192 { visible += "\n… Preview truncated; \(text.utf8.count) bytes total." }
        lineCount = lines
        preview = visible
        requiresReview = controls || unsupportedShell
    }

    public func data(bracketed: Bool) -> Data {
        Data((bracketed ? "\u{1b}[200~" + text + "\u{1b}[201~" : text).utf8)
    }
}

public struct TerminalPasteTarget: Equatable, Sendable {
    public let paneID: UUID
    public let sessionID: UUID
    public init(paneID: UUID, sessionID: UUID) { self.paneID = paneID; self.sessionID = sessionID }
}

public struct PendingTerminalPaste: Identifiable, Sendable {
    public let id = UUID()
    public let plan: TerminalPastePlan
    public let target: TerminalPasteTarget
    public let targetName: String
}

/// Ephemeral approval: no clipboard history and no delayed target lookup.
@MainActor
public final class TerminalPasteReview {
    public private(set) var pending: PendingTerminalPaste?
    public init() {}

    public func request(_ plan: TerminalPastePlan, target: TerminalPasteTarget, name: String,
                        send: (TerminalPastePlan) throws -> Void) rethrows {
        pending = nil
        guard !plan.text.isEmpty else { return }
        if plan.requiresReview { pending = PendingTerminalPaste(plan: plan, target: target, targetName: name) }
        else { try send(plan) }
    }

    @discardableResult
    public func confirm(id: UUID, currentTarget: TerminalPasteTarget?,
                        send: (TerminalPastePlan) throws -> Void) rethrows -> Bool {
        guard let candidate = pending, candidate.id == id else { return false }
        pending = nil
        guard candidate.target == currentTarget else { return false }
        try send(candidate.plan)
        return true
    }

    public func cancel() { pending = nil }
}
