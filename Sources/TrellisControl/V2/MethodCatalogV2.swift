import Foundation
import TrellisCore

/// The protocol 2 method catalog (docs/api/v2/methods.md). Each phase adds its area here; nothing else lists methods.
public enum MethodCatalogV2 {
    public static let methods: [MethodSpecV2] = system + workspace + spaces + tabs + panes + sessions + agents + hosts + remote + projects + tasks + events

    public static let byName: [String: MethodSpecV2] = Dictionary(methods.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

    public static func spec(_ name: String) -> MethodSpecV2? { byName[name] }

    /// Unknown names count as mutating, so a notification for one is refused rather than ignored.
    public static func isMutating(_ name: String) -> Bool { byName[name]?.isMutating ?? true }

    /// `launch` → its fields as `launch.kind`, … (one level of nesting, which is all the catalog uses).
    static func paths(_ params: [ParamV2]) -> [String: ParamV2] {
        var paths: [String: ParamV2] = [:]
        for param in params {
            paths[param.name] = param
            if case .structure(let schema) = param.type { for field in schema.fields { paths[param.name + "." + field.name] = field } }
        }
        return paths
    }

    static func problems(in condition: ConditionV2, paths: [String: ParamV2]) -> [String] {
        switch condition {
        case .present(let path), .provided(let path):
            return paths[path] == nil ? ["condition depends on undeclared \(path)"] : []
        case .equals(let path, let value):
            guard let param = paths[path] else { return ["condition depends on undeclared \(path)"] }
            return param.type.accepts(value) ? [] : ["condition compares \(path) with a value it can't take"]
        case .contains(let path, let value):
            guard let param = paths[path] else { return ["condition depends on undeclared \(path)"] }
            guard case .stringList = param.type, param.type.accepts(.array([.string(value)])) else { return ["condition looks for \(value) in \(path), which can't hold it"] }
            return []
        case .anyOf(let conditions):
            return conditions.isEmpty ? ["anyOf needs conditions"] : conditions.flatMap { problems(in: $0, paths: paths) }
        }
    }

    static func kindName(_ kind: ResourceKind) -> String {
        switch kind {
        case .space: "space"
        case .tab: "tab"
        case .pane: "pane"
        case .branch: "branch"
        case .session: "session"
        case .host: "host"
        case .anyLayout: "resource"
        case .project: "project"
        case .agent: "agent"
        }
    }

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
                if ["windowId", "windowIds"].contains(param.name) { problem("parameter \(param.name) is a v1 alias") }
                if param.required && param.nullable { problem("parameter \(param.name) is required, so it can't be null") }
            }
            // Every parameter path, nested fields of `.structure` params included.
            let paths = Self.paths(params)
            for (path, param) in paths.sorted(by: { $0.key < $1.key }) {
                let leaf = String(path.split(separator: ".").last ?? "")
                if leaf.wholeMatch(of: paramPattern) == nil { problem("parameter \(path) is not lowerCamelCase") }
                if param.summary.isEmpty { problem("parameter \(path) has no description") }
                switch param.type {
                case .uuid, .uuidList:
                    if !param.unscoped && !spec.resources.contains(where: { $0.param == path }) { problem("UUID parameter \(path) needs a resource rule (or unscoped: true)") }
                case .structure(let schema):
                    let fields = Set(schema.fields.map(\.name))
                    if let tag = schema.tag {
                        let tagType = schema.fields.first { $0.name == tag }?.type
                        if tagType != .string(values: schema.variants.map(\.value)) { problem("\(path).\(tag) must be a string listing exactly the variants") }
                        for variant in schema.variants where !Set(variant.allowed + variant.required).isSubset(of: fields) || !Set(variant.required).isSubset(of: variant.allowed) {
                            problem("variant \(variant.value) of \(path) names undeclared or unallowed fields")
                        }
                    } else if !schema.variants.isEmpty {
                        problem("\(path) has variants but no tag")
                    }
                default: break
                }
            }
            for rule in spec.resources {
                // Agents are named by definition ID strings; every other resource by UUID.
                switch (rule.kind, paths[rule.param]?.type) {
                case (.agent, .string?) where !rule.list, (.agent, .stringList?) where rule.list: break
                case (.agent, _): problem("agent parameter \(rule.param) must be declared as \(rule.list ? "a string list" : "a string")")
                case (_, .uuid?) where !rule.list, (_, .uuidList?) where rule.list: break
                default: problem("resource parameter \(rule.param) must be declared as \(rule.list ? "a UUID list" : "a UUID")")
                }
            }
            for group in spec.anyOf {
                if Set(group).count < 2 || Set(group).count != group.count { problem("an anyOf group needs two or more different capabilities") }
                if !spec.capabilities.isDisjoint(with: group) { problem("an anyOf group overlaps the required capabilities") }
            }
            if spec.createsSpace && spec.createsSpaceIf != nil { problem("createsSpace and createsSpaceIf are exclusive") }
            if (spec.createsSpace || spec.createsSpaceIf != nil) && spec.requiresAllSpaces { problem("a method that needs all spaces can't also allow created scope") }
            var conditions = spec.conditional.map(\.condition)
            if let condition = spec.allSpacesIf { conditions.append(condition) }
            if let condition = spec.createsSpaceIf { conditions.append(condition) }
            if let condition = spec.waitsIf { conditions.append(condition) }
            if spec.waits && spec.waitsIf != nil { problem("waits and waitsIf are exclusive") }
            for condition in conditions { problems += Self.problems(in: condition, paths: paths).map { "\(name): \($0)" } }
            for rule in spec.conditional where spec.capabilities.contains(rule.capability) { problem("\(rule.capability.rawValue) is both required and conditional") }
            for rule in spec.rules {
                if rule.names.count < 2 { problem("a parameter rule needs at least two parameters") }
                for param in rule.names {
                    if params.first(where: { $0.name == param }).map({ $0.required }) ?? true { problem("rule parameter \(param) must be a declared optional parameter") }
                }
            }
            let isList = name.hasSuffix(".list")
            if isList != spec.paginated { problem(isList ? "list methods take limit and cursor" : "only list methods are paginated") }
            if spec.paginated && spec.isMutating { problem("list methods are read-only") }
            let byName = Dictionary(params.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            switch spec.revisionTarget {
            case .resource(let param)?:
                if byName[param]?.type != .uuid || byName[param]?.required != true { problem("revision target \(param) must be a required UUID parameter") }
                if !spec.resources.contains(where: { $0.param == param && !$0.list }) { problem("revision target \(param) needs a resource rule for its kind") }
                if !params.contains(where: { $0.name == "expectedRevision" }) { problem("mutating methods take expectedRevision") }
            case .container(let container, let param)?:
                switch (container, param) {
                case ("workspace", nil): break
                case (_, let param?):
                    let kind = spec.resources.first { $0.param == param && !$0.list }?.kind
                    if byName[param]?.type != .uuid || byName[param]?.required != true || kind.map(Self.kindName) != container {
                        problem("revision container \(container) needs a required \(container) ID parameter with a resource rule")
                    }
                default: problem("revision container \(container.isEmpty ? "needs a name" : container + " needs the parameter naming it")")
                }
                if !params.contains(where: { $0.name == "expectedRevision" }) { problem("mutating methods take expectedRevision") }
            case .anyResource(let targets)?:
                if targets.isEmpty { problem("revision target needs at least one parameter") }
                for target in targets where paths[target]?.type != .uuid || !spec.resources.contains(where: { $0.param == target && !$0.list }) {
                    problem("revision target \(target) must be a UUID parameter with a resource rule")
                }
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
