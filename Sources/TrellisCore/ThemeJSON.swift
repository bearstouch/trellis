import Foundation

public struct ThemeValidationError: Error, Equatable, Sendable, LocalizedError {
    public enum Code: String, Sendable {
        case tooLarge, malformedJSON, duplicateKey, unknownField, missingField, wrongType
        case unsupportedVersion, invalidID, invalidName, invalidAppearance, invalidColor, invalidANSI
    }
    public let path: String
    public let code: Code
    public let reason: String
    public var errorDescription: String? { "\(path): \(reason)" }
}

/// A small bounded JSON reader retains object keys until they have been checked
/// for duplicates. Foundation's dictionary decoders discard that information.
indirect enum ThemeJSON {
    case object([String: ThemeJSON]), array([ThemeJSON]), string(String), number(String), bool, null

    static func parse(_ data: Data) throws -> ThemeJSON {
        guard data.count <= ThemeValidator.maximumBytes else {
            throw ThemeValidationError(path: "$", code: .tooLarge, reason: "Theme files must be at most 64 KiB.")
        }
        guard String(data: data, encoding: .utf8) != nil else {
            throw ThemeValidationError(path: "$", code: .malformedJSON, reason: "Use valid UTF-8 JSON.")
        }
        var reader = Reader(bytes: Array(data))
        let result = try reader.value(path: "$", depth: 0)
        reader.whitespace()
        guard reader.index == reader.bytes.count else { throw reader.malformed("$") }
        return result
    }

    private struct Reader {
        let bytes: [UInt8]
        var index = 0
        var current: UInt8? { index < bytes.count ? bytes[index] : nil }
        mutating func whitespace() {
            while let byte = current, [9, 10, 13, 32].contains(byte) { index += 1 }
        }
        func malformed(_ path: String) -> ThemeValidationError {
            ThemeValidationError(path: path, code: .malformedJSON, reason: "Malformed JSON near byte \(index).")
        }
        mutating func consume(_ byte: UInt8) -> Bool {
            guard current == byte else { return false }
            index += 1; return true
        }
        mutating func string(path: String) throws -> String {
            let start = index
            guard consume(34) else { throw malformed(path) }
            var escaped = false
            while let byte = current {
                index += 1
                if escaped { escaped = false; continue }
                if byte == 92 { escaped = true; continue }
                if byte == 34 {
                    guard let text = try? JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) else { throw malformed(path) }
                    return text
                }
                if byte < 32 { throw malformed(path) }
            }
            throw malformed(path)
        }
        mutating func value(path: String, depth: Int) throws -> ThemeJSON {
            whitespace()
            guard depth <= 16, let byte = current else { throw malformed(path) }
            if byte == 34 { return .string(try string(path: path)) }
            if consume(123) {
                var fields: [String: ThemeJSON] = [:]
                whitespace()
                if consume(125) { return .object(fields) }
                while true {
                    whitespace()
                    let key = try string(path: path)
                    let childPath = path + "." + key
                    guard fields[key] == nil else {
                        throw ThemeValidationError(path: childPath, code: .duplicateKey, reason: "Duplicate object key.")
                    }
                    whitespace()
                    guard consume(58) else { throw malformed(childPath) }
                    fields[key] = try value(path: childPath, depth: depth + 1)
                    whitespace()
                    if consume(125) { return .object(fields) }
                    guard consume(44) else { throw malformed(path) }
                }
            }
            if consume(91) {
                var items: [ThemeJSON] = []
                whitespace()
                if consume(93) { return .array(items) }
                while true {
                    items.append(try value(path: "\(path)[\(items.count)]", depth: depth + 1))
                    whitespace()
                    if consume(93) { return .array(items) }
                    guard consume(44) else { throw malformed(path) }
                }
            }
            for literal in ["true", "false", "null"] {
                let word = Array(literal.utf8)
                if bytes[index...].starts(with: word) {
                    index += word.count
                    return literal == "null" ? .null : .bool
                }
            }
            let start = index
            _ = consume(45)
            if !consume(48) {
                guard let digit = current, (49...57).contains(digit) else { throw malformed(path) }
                index += 1
                while let digit = current, (48...57).contains(digit) { index += 1 }
            }
            if consume(46) {
                let fraction = index
                while let digit = current, (48...57).contains(digit) { index += 1 }
                guard index > fraction else { throw malformed(path) }
            }
            if current == 101 || current == 69 {
                index += 1
                if current == 43 || current == 45 { index += 1 }
                let exponent = index
                while let digit = current, (48...57).contains(digit) { index += 1 }
                guard index > exponent else { throw malformed(path) }
            }
            return .number(String(decoding: bytes[start..<index], as: UTF8.self))
        }
    }
}
