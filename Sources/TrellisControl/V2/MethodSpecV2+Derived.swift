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
        case .structure(let schema): schema.tag.map { "object with \($0) " + schema.variants.map(\.value).joined(separator: ", ") } ?? "object"
        case .stringMap(let maxCount): "object of at most \(maxCount) string values"
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
        case .object, .structure, .stringMap: "json"
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
        case (.structure(let schema), .object(let object)):
            var fields: [String: String] = [:]
            MethodSpecV2.check(object, params: schema.fields, schema: schema, prefix: "", into: &fields)
            return fields.isEmpty
        case (.stringMap(let maxCount), .object(let object)):
            return object.count <= maxCount && object.values.allSatisfy { if case .string = $0 { true } else { false } }
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
        case .structure(let schema):
            var object: [String: JSONValue] = [
                "type": .string("object"), "properties": .object(Dictionary(uniqueKeysWithValues: schema.fields.map { ($0.name, $0.jsonSchema(in: schema)) })),
                "additionalProperties": .bool(false)
            ]
            let required = schema.tag.map { [$0] } ?? schema.fields.filter(\.required).map(\.name)
            if !required.isEmpty { object["required"] = .array(required.map(JSONValue.string)) }
            return object
        case .stringMap(let maxCount):
            return ["type": .string("object"), "additionalProperties": .object(["type": .string("string")]), "maxProperties": .number(Double(maxCount))]
        case .idempotencyKey:
            return ["type": .string("string"), "minLength": .number(1), "maxLength": .number(128), "pattern": .string("^[\\x20-\\x7E]+$")]
        case .cursor: return ["type": .string("string"), "minLength": .number(1), "maxLength": .number(1_024)]
        }
    }

    private static func text(_ number: Double) -> String { number == number.rounded() ? String(Int64(number)) : String(number) }
}

extension ParamV2 {
    public var jsonSchema: JSONValue { jsonSchema(in: nil) }

    /// Inside a tagged union, the tag's description lists which fields each variant takes, so clients can see what the
    /// flat schema can't say.
    func jsonSchema(in parent: ObjectSchemaV2?) -> JSONValue {
        var schema = type.jsonSchema
        if nullable, case .string(let base)? = schema["type"] {
            schema["type"] = .array([.string(base), .string("null")])
            if case .array(let values)? = schema["enum"] { schema["enum"] = .array(values + [.null]) }
        }
        var description = summary
        if let parent, parent.tag == name {
            description +=
                " "
                + parent.variants.map { variant in
                    let fields = variant.allowed.map { variant.required.contains($0) ? $0 : $0 + "?" }
                    return variant.value + (fields.isEmpty ? "" : " (" + fields.joined(separator: ", ") + ")")
                }.joined(separator: "; ") + "."
        }
        schema["description"] = .string(description)
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
        var fields: [String: String] = [:]
        Self.check(object, params: self.params, schema: nil, prefix: "", into: &fields)
        for rule in rules {
            let sent = rule.names.filter { name in
                switch rule {
                case .atLeastOne: object[name] != nil
                case .exactlyOne: object[name].map { $0 != .null } ?? false
                }
            }
            switch rule {
            case .atLeastOne(let names) where sent.isEmpty:
                for name in names { fields[name] = fields[name] ?? "send at least one of " + names.joined(separator: ", ") }
            case .exactlyOne(let names) where sent.count != 1:
                for name in names { fields[name] = fields[name] ?? "send exactly one of " + names.joined(separator: ", ") }
            default: break
            }
        }
        guard fields.isEmpty else {
            let bounded = Dictionary(uniqueKeysWithValues: fields.sorted { $0.key < $1.key }.prefix(Self.maximumFieldErrors).map { ($0.key, $0.value) })
            return .failure(.invalidParams("Invalid params.", fields: bounded))
        }
        return .success(ParamsV2(Self.normalized(object, params: self.params)))
    }

    /// Field checks shared by top-level params and `.structure` fields (reported as `launch.kind`).
    static func check(_ object: [String: JSONValue], params accepted: [ParamV2], schema: ObjectSchemaV2?, prefix: String, into fields: inout [String: String]) {
        var allowed = Set(accepted.map(\.name))
        var required = Set(accepted.filter(\.required).map(\.name))
        if let schema, let tag = schema.tag {
            required.insert(tag)
            if case .string(let value)? = object[tag], let variant = schema.variants.first(where: { $0.value == value }) {
                allowed = Set(variant.allowed + [tag]); required = Set(variant.required + [tag])
            }
        }
        for key in object.keys.sorted() where !allowed.contains(key) {
            // Only short identifier-like names are echoed back; anything else is reported in aggregate.
            let echo = key.utf8.count <= 64 && key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
            let known = accepted.contains { $0.name == key }
            fields[echo ? prefix + key : prefix + "params"] = known ? "not used with this \(schema?.tag ?? "kind")" : echo ? "unknown parameter" : "unknown parameters"
        }
        for param in accepted where allowed.contains(param.name) {
            let key = prefix + param.name
            switch object[param.name] {
            case nil where required.contains(param.name): fields[key] = "required: " + param.type.expectation
            case nil: break
            case .null? where param.nullable: break
            case .null?: fields[key] = param.type.expectation + (required.contains(param.name) ? "" : "; omit it instead of null")
            case .object(let nested)?:
                if case .structure(let inner) = param.type {
                    check(nested, params: inner.fields, schema: inner, prefix: key + ".", into: &fields)
                } else if !param.type.accepts(.object(nested)) {
                    fields[key] = param.type.expectation
                }
            case let value?: if !param.type.accepts(value) { fields[key] = param.type.expectation }
            }
        }
    }

    /// UUIDs are compared lowercase, so a retried call that spells an ID in another case replays instead of conflicting
    /// with its own idempotency key.
    static func normalized(_ object: [String: JSONValue], params accepted: [ParamV2]) -> [String: JSONValue] {
        var result = object
        for param in accepted {
            guard let value = object[param.name] else { continue }
            switch (param.type, value) {
            case (.uuid, .string(let text)): result[param.name] = .string(text.lowercased())
            case (.uuidList, .array(let items)): result[param.name] = .array(items.map { if case .string(let text) = $0 { .string(text.lowercased()) } else { $0 } })
            case (.structure(let schema), .object(let nested)): result[param.name] = .object(normalized(nested, params: schema.fields))
            default: break
            }
        }
        return result
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
        var parts = (capabilities.sorted().map(\.rawValue) + anyOf.map { $0.map(\.rawValue).joined(separator: " or ") }).joined(separator: " + ")
        let extras = conditional.map { "+\($0.capability.rawValue) if \($0.condition.summary)" }
        if !extras.isEmpty { parts += (parts.isEmpty ? "" : " ") + "(" + extras.joined(separator: ", ") + ")" }
        if requiresAllSpaces { parts += (parts.isEmpty ? "" : ", ") + "all spaces" }
        if let allSpacesIf { parts += (parts.isEmpty ? "" : ", ") + "all spaces if " + allSpacesIf.summary }
        if createsSpace { parts += (parts.isEmpty ? "" : ", ") + "all or created spaces" }
        if let createsSpaceIf { parts += (parts.isEmpty ? "" : ", ") + "all or created spaces if " + createsSpaceIf.summary }
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
