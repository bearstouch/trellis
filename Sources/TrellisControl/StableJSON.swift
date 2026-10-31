import Foundation

/// Fields in a fixed, readable order with two-space indentation and a final newline, so files written twice are
/// identical bytes and reviews show only real changes (FR-TK04).
enum StableJSON {
    indirect enum Value: Sendable {
        case string(String), number(Double), array([Value]), object([(String, Value)])
    }

    static func render(_ document: Value) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        func scalar<T: Encodable>(_ value: T) -> String { (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "null" }
        func render(_ value: Value, indent: String) -> String {
            let inner = indent + "  "
            switch value {
            case .string(let text): return scalar(text)
            case .number(let number): return number == number.rounded() && abs(number) < 1e15 ? String(Int64(number)) : scalar(number)
            case .array(let items):
                return items.isEmpty ? "[]" : "[\n" + items.map { inner + render($0, indent: inner) }.joined(separator: ",\n") + "\n\(indent)]"
            case .object(let fields):
                return fields.isEmpty ? "{}" : "{\n" + fields.map { inner + scalar($0.0) + ": " + render($0.1, indent: inner) }.joined(separator: ",\n") + "\n\(indent)}"
            }
        }
        return Data((render(document, indent: "") + "\n").utf8)
    }
}
