import Foundation
import TrellisCore

/// The protocol 2 method catalog (docs/api/v2/methods.md). Each phase adds its area here; nothing else lists methods.
public enum MethodCatalogV2 {
    public static let methods: [MethodSpecV2] = [
        MethodSpecV2("system.info", "Trellis version, protocol version, app instance ID and protocol limits."),
        MethodSpecV2("grant.get", "This connection's own grant: capabilities, scopes and expiry, so a client can see what it may do.")
    ]

    public static let byName: [String: MethodSpecV2] = Dictionary(methods.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

    public static func spec(_ name: String) -> MethodSpecV2? { byName[name] }

    /// Unknown names count as mutating, so a notification for one is refused rather than ignored.
    public static func isMutating(_ name: String) -> Bool { byName[name]?.isMutating ?? true }

    /// `session.sendInput` → `session_send_input`: Claude-compatible MCP tool names (`[a-z0-9_]`, ≤ 64).
    public static func toolName(_ method: String) -> String {
        var name = ""
        for character in method {
            if character == "." {
                name.append("_")
            } else if character.isUppercase {
                name.append("_"); name.append(contentsOf: character.lowercased())
            } else {
                name.append(character)
            }
        }
        return name
    }

    /// Contract checks (API2-02): every rule the conventions put on a method's declaration. Empty for a valid catalog.
    public static func problems(in methods: [MethodSpecV2]) -> [String] {
        var problems: [String] = []
        var names = Set<String>(), tools = Set<String>()
        let methodPattern = /^[a-z][a-zA-Z0-9]*(\.[a-z][a-zA-Z0-9]*){1,2}$/
        let paramPattern = /^[a-z][a-zA-Z0-9]*$/
        for spec in methods {
            let name = spec.name
            func problem(_ text: String) { problems.append("\(name): \(text)") }
            if !names.insert(name).inserted { problem("declared twice") }
            if name.wholeMatch(of: methodPattern) == nil { problem("not area.verb or area.subarea.verb in lowerCamelCase") }
            if name.hasPrefix("window.") { problem("v1 alias names are not part of protocol 2") }
            let tool = toolName(name)
            if tool.count > 64 || !tools.insert(tool).inserted { problem("MCP tool name \(tool) is too long or not unique") }
            if spec.summary.isEmpty || !spec.summary.hasSuffix(".") { problem("needs a one-sentence summary") }
            let params = spec.params
            var seen = Set<String>()
            for param in params {
                if !seen.insert(param.name).inserted { problem("parameter \(param.name) declared twice") }
                if param.name.wholeMatch(of: paramPattern) == nil { problem("parameter \(param.name) is not lowerCamelCase") }
                if ["windowId", "windowIds"].contains(param.name) { problem("parameter \(param.name) is a v1 alias") }
                if param.summary.isEmpty { problem("parameter \(param.name) has no description") }
                if param.required && param.nullable { problem("parameter \(param.name) is required, so it can't be null") }
                switch param.type {
                case .uuid, .uuidList:
                    if !param.unscoped && !spec.resources.contains(where: { $0.param == param.name }) {
                        problem("UUID parameter \(param.name) needs a resource rule (or unscoped: true)")
                    }
                default: break
                }
            }
            let byName = Dictionary(params.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            for rule in spec.resources {
                switch byName[rule.param]?.type {
                case .uuid? where !rule.list, .uuidList? where rule.list: break
                default: problem("resource parameter \(rule.param) must be declared as \(rule.list ? "a UUID list" : "a UUID")")
                }
            }
            for rule in spec.conditional {
                if case .present(let param) = rule.condition, byName[param] == nil { problem("conditional capability depends on undeclared \(param)") }
                if spec.capabilities.contains(rule.capability) { problem("\(rule.capability.rawValue) is both required and conditional") }
            }
            let isList = name.hasSuffix(".list")
            if isList != spec.paginated { problem(isList ? "list methods take limit and cursor" : "only list methods are paginated") }
            if spec.paginated && spec.isMutating { problem("list methods are read-only") }
            switch spec.revisionTarget {
            case .resource(let param)?:
                if byName[param]?.type != .uuid || byName[param]?.required != true { problem("revision target \(param) must be a required UUID parameter") }
                if !params.contains(where: { $0.name == "expectedRevision" }) { problem("mutating methods take expectedRevision") }
            case .container(let container)?:
                if container.isEmpty { problem("revision container needs a name") }
                if !params.contains(where: { $0.name == "expectedRevision" }) { problem("mutating methods take expectedRevision") }
            case .exempt(let reason)?:
                if reason.isEmpty { problem("an expectedRevision exemption needs a reason") }
            case nil:
                if params.contains(where: { ["expectedRevision", "idempotencyKey"].contains($0.name) }) { problem("read-only methods take no expectedRevision or idempotencyKey") }
            }
            if spec.isMutating && !params.contains(where: { $0.name == "idempotencyKey" }) { problem("mutating methods take idempotencyKey") }
        }
        return problems
    }
}
