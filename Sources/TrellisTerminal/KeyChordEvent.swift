import AppKit
import TrellisCore

extension KeyChord {
    private static let functionKeys: [Int: String] = {
        var keys = [
            NSLeftArrowFunctionKey: "left", NSRightArrowFunctionKey: "right", NSUpArrowFunctionKey: "up", NSDownArrowFunctionKey: "down",
            NSHomeFunctionKey: "home", NSEndFunctionKey: "end", NSPageUpFunctionKey: "pageUp", NSPageDownFunctionKey: "pageDown",
            NSDeleteFunctionKey: "forwardDelete"
        ]
        for index in 0..<12 { keys[NSF1FunctionKey + index] = "f\(index + 1)" }
        return keys
    }()

    /// Reads the key the active layout produces without modifiers, so a recorded
    /// chord matches the key cap the user pressed on US, Portuguese, or other layouts.
    /// Escape and modifier-only events return nil.
    public init?(event: NSEvent) {
        guard event.type == .keyDown else { return nil }
        let flags = event.modifierFlags
        var modifiers: KeyModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        // Layout translation reports arrows as legacy control codes, so read
        // AppKit's function-key characters before the layout's base character.
        let functionKey = event.charactersIgnoringModifiers?.unicodeScalars.first.flatMap { Self.functionKeys[Int($0.value)] }
        if let functionKey {
            self.init(functionKey, modifiers)
            return
        }
        guard let base = event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers,
            let scalar = base.unicodeScalars.first
        else { return nil }
        let key: String
        switch Int(scalar.value) {
        case 0x0D, 0x03: key = "return"
        case 0x09, 0x19: key = "tab"
        case 0x20: key = "space"
        case 0x7F, 0x08: key = "delete"
        case 0x1B: return nil
        default:
            guard base.count == 1, scalar.value >= 0x20 else { return nil }
            key = base
        }
        self.init(key, modifiers)
    }

    public var keyEquivalent: String {
        if let code = Self.functionKeys.first(where: { $0.value == key })?.key { return String(UnicodeScalar(code)!) }
        switch key {
        case "return": return "\r"
        case "tab": return "\t"
        case "space": return " "
        case "delete": return "\u{8}"
        default: return key
        }
    }

    public var modifierMask: NSEvent.ModifierFlags {
        var mask: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { mask.insert(.command) }
        if modifiers.contains(.shift) { mask.insert(.shift) }
        if modifiers.contains(.option) { mask.insert(.option) }
        if modifiers.contains(.control) { mask.insert(.control) }
        return mask
    }
}
