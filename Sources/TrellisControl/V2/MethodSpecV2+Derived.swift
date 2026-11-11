import Foundation
import TrellisCore

// Everything here is generated from a `MethodSpecV2`: parameter validation, MCP JSON Schemas and annotations, and CLI
// help. Nothing restates a method's parameters by hand.

extension ParamTypeV2 {
    /// What a valid value looks like, for `data.fields` and help.
    public var expectation: String {
        switch self {
        case .string(let values?, _): "one of " + values.joined(separator: ", ")
        case .string(nil, let maxBytes?): "string of at most \(maxBytes) bytes"
        case .string(nil, nil): "string"
        case .uuid: "UUID"
        case .uuidList(let maxCount): "array of at most \(maxCount) UUIDs"
        case .stringList(let values?, _): "array of " + values.joined(separator: ", ")
        case .stringList(nil, let maxCount): "array of at most \(maxCount) strings"
        case .integer(let minimum?, let maximum?): "integer \(minimum)–\(maximum)"
        case .integer(let minimum?, nil): "integer ≥ \(minimum)"
        case .integer(nil, let maximum?): "integer ≤ \(maximum)"
        case .integer(nil, nil): "integer"
        case .number(let minimum?, let maximum?): "number \(Self.text(minimum))–\(Self.text(maximum))"
        case .number: "number"
        case .boolean: "boolean"
        case .object: "object"
        case .idempotencyKey: "1–128 printable ASCII characters"
        case .cursor: "nextCursor from the previous page"
        }
    }

    /// The placeholder in a CLI synopsis (`id=<uuid>`).
    public var placeholder: String {
        switch self {
        case .string(let values?, _): values.joined(separator: "|")
        case .string: "string"
        case .uuid: "uuid"
        case .uuidList: "uuid,…"
        case .stringList: "string,…"
        case .integer: "integer"
        case .number: "number"
        case .boolean: "true|false"
        case .object: "json"
        case .idempotencyKey: "key"
        case .cursor: "cursor"
        }
    }

    public func accepts(_ value: JSONValue) -> Bool {
        switch (self, value) {
        case (.string(let values, let maxBytes), .string(let text)):
            return values.map { $0.contains(text) } ?? true && maxBytes.map { text.utf8.count <= $0 } ?? true
        case (.uuid, .string(let text)): return ConventionsV2.parseID(text) != nil
        case (.uuidList(let maxCount), .array(let items)):
            return items.count <= maxCount && items.allSatisfy { if case .string(let text) = $0 { ConventionsV2.parseID(text) != nil } else { false } }
        case (.stringList(let values, let maxCount), .array(let items)):
            return items.count <= maxCount && items.allSatisfy { if case .string(let text) = $0 { values?.contains(text) ?? true } else { false } }
        case (.integer(let minimum, let maximum), .number(let number)):
            guard let integer = ConventionsV2.integer(number) else { return false }
            return minimum.map { integer >= $0 } ?? true && maximum.map { integer <= $0 } ?? true
        case (.number(let minimum, let maximum), .number(let number)):
            return number.isFinite && minimum.map { number >= $0 } ?? true && maximum.map { number <= $0 } ?? true
        case (.boolean, .bool), (.object, .object): return true
        case (.idempotencyKey, .string(let key)): return ConventionsV2.isValidIdempotencyKey(key)
        case (.cursor, .string(let text)): return (1...1_024).contains(text.utf8.count)
        default: return false
        }
    }

    /// JSON Schema (draft 2020-12 subset MCP clients accept) for one value.
    public var jsonSchema: [String: JSONValue] {
        switch self {
        case .string(let values, _):
            var schema: [String: JSONValue] = ["type": .string("string")]
            if let values { schema["enum"] = .array(values.map(JSONValue.string)) }
            return schema
        case .uuid: return ["type": .string("string"), "format": .string("uuid")]
        case .uuidList(let maxCount):
            return ["type": .string("array"), "items": .object(Self.uuid.jsonSchema), "maxItems": .number(Double(maxCount))]
        case .stringList(let values, let maxCount):
            return ["type": .string("array"), "items": .object(Self.string(values: values).jsonSchema), "maxItems": .number(Double(maxCount))]
        case .integer(let minimum, let maximum):
            var schema: [String: JSONValue] = ["type": .string("integer")]
            if let minimum { schema["minimum"] = .number(Double(minimum)) }
            if let maximum { schema["maximum"] = .number(Double(maximum)) }
            return schema
        case .number(let minimum, let maximum):
            var schema: [String: JSONValue] = ["type": .string("number")]
            if let minimum { schema["minimum"] = .number(minimum) }
            if let maximum { schema["maximum"] = .number(maximum) }
            return schema
        case .boolean: return ["type": .string("boolean")]
        case .object: return ["type": .string("object")]
        case .idempotencyKey:
            return ["type": .string("string"), "minLength": .number(1), "maxLength": .number(128), "pattern": .string("^[\\x20-\\x7E]+$")]
        case .cursor: return ["type": .string("string"), "minLength": .number(1), "maxLength": .number(1_024)]
        }
    }

    private static func text(_ number: Double) -> String { number == number.rounded() ? String(Int64(number)) : String(number) }
}

extension ParamV2 {
    public var jsonSchema: JSONValue {
        var schema = type.jsonSchema
        if nullable, case .string(let base)? = schema["type"] {
            schema["type"] = .array([.string(base), .string("null")])
            if case .array(let values)? = schema["enum"] { schema["enum"] = .array(values + [.null]) }
        }
        schema["description"] = .string(summary)
        return .object(schema)
    }
}

extension MethodSpecV2 {
    /// At most this many field messages are returned, so a hostile request can't inflate the reply.
    static let maximumFieldErrors = 32

    /// Checks params against the declaration: an object, no unknown names (v1 aliases such as `windowId` included),
    /// required ones present, `null` only where it clears a field, and every value of its type. Failures are -32602 with
    /// `data.fields`.
    public func validate(_ params: JSONValue?) -> Result<ParamsV2, ControlError> {
        let object: [String: JSONValue]
        switch params {
        case nil: object = [:]
        case .object(let value)?: object = value
        default: return .failure(.invalidParams("params must be an object.", fields: ["params": "object"]))
        }
        let accepted = self.params
        let known = Set(accepted.map(\.name))
        var fields: [String: String] = [:]
        for key in object.keys.sorted() where !known.contains(key) {
            // Only short identifier-like names are echoed back; anything else is reported in aggregate.
            let echo = key.utf8.count <= 64 && key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
            fields[echo ? key : "params"] = echo ? "unknown parameter" : "unknown parameters"
        }
        for param in accepted {
            switch object[param.name] {
            case nil where param.required: fields[param.name] = "required: " + param.type.expectation
            case nil: break
            case .null? where param.nullable: break
            case .null?: fields[param.name] = param.type.expectation + (param.required ? "" : "; omit it instead of null")
            case let value?: if !param.type.accepts(value) { fields[param.name] = param.type.expectation }
            }
        }
        guard fields.isEmpty else {
            let bounded = Dictionary(uniqueKeysWithValues: fields.sorted { $0.key < $1.key }.prefix(Self.maximumFieldErrors).map { ($0.key, $0.value) })
            return .failure(.invalidParams("Invalid params.", fields: bounded))
        }
        return .success(ParamsV2(object))
    }

    /// The MCP `inputSchema`: a closed object with the generated properties and required names.
    public var inputSchema: JSONValue {
        let all = params
        var schema: [String: JSONValue] = [
            "type": .string("object"), "properties": .object(Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0.jsonSchema) })),
            "additionalProperties": .bool(false)
        ]
        let required = all.filter(\.required).map(\.name)
        if !required.isEmpty { schema["required"] = .array(required.map(JSONValue.string)) }
        return .object(schema)
    }

    /// The MCP tool name (`grant_get`).
    public var toolName: String { MethodCatalogV2.toolName(name) }

    /// The MCP tool description: the summary and what the call needs.
    public var toolDescription: String {
        let needs = requirementSummary
        return needs == "none" ? summary : summary + " Needs " + needs + "."
    }

    /// MCP annotations: read-only tools are `readOnlyHint`; mutating ones say whether they are destructive.
    public var toolAnnotations: JSONValue {
        var annotations: [String: JSONValue] = ["readOnlyHint": .bool(!isMutating), "openWorldHint": .bool(false)]
        if isMutating { annotations["destructiveHint"] = .bool(isDestructive) }
        return .object(annotations)
    }

    /// Capabilities and scope as methods.md writes them: `workspace.write (+session.start if start), all spaces`.
    public var requirementSummary: String {
        var parts = capabilities.sorted().map(\.rawValue).joined(separator: " + ")
        let extras = conditional.map { "+\($0.capability.rawValue) if \($0.condition.summary)" }
        if !extras.isEmpty { parts += (parts.isEmpty ? "" : " ") + "(" + extras.joined(separator: ", ") + ")" }
        if requiresAllSpaces { parts += (parts.isEmpty ? "" : ", ") + "all spaces" }
        return parts.isEmpty ? "none" : parts
    }

    /// A one-line CLI synopsis: `space.update id=<uuid> name=<string> [expectedRevision=<integer>]`.
    public var synopsis: String {
        ([name]
            + params.map { param in
                let field = "\(param.name)=<\(param.type.placeholder)>"
                return param.required ? field : "[\(field)]"
            }).joined(separator: " ")
    }

    /// CLI help for one method: summary, synopsis, parameters, requirement and errors.
    public var helpText: String {
        var lines = [synopsis, "", summary, ""]
        if !params.isEmpty {
            lines.append("Parameters:")
            lines += params.map { "  \($0.name)\($0.required ? "" : " (optional)"): \($0.summary)" }
            lines.append("")
        }
        lines.append("Needs: " + requirementSummary)
        lines.append("Errors: " + errors.map(\.rawValue).sorted().joined(separator: ", "))
        return lines.joined(separator: "\n")
    }
}
