import Foundation
import TrellisCore

/// The type of one v2 parameter. It drives validation (-32602 with `data.fields`), the generated JSON Schema for MCP
/// and the CLI synopsis, so all three always agree.
public enum ParamTypeV2: Sendable, Equatable {
    /// A string, optionally limited to `values` and to `maxBytes` UTF-8 bytes.
    case string(values: [String]? = nil, maxBytes: Int? = nil)
    /// A UUID in any case; results always write UUIDs lowercase.
    case uuid
    case uuidList(maxCount: Int = 1_000)
    case stringList(values: [String]? = nil, maxCount: Int = 1_000)
    case integer(minimum: Int64? = nil, maximum: Int64? = nil)
    case number(minimum: Double? = nil, maximum: Double? = nil)
    case boolean
    /// A JSON object the method validates itself (layout, project and theme documents).
    case object
    /// An object with declared fields (a launch descriptor, a placement), validated and described like top-level params.
    case structure(ObjectSchemaV2)
    /// An object whose values are strings (an environment), at most `maxCount` entries.
    case stringMap(maxCount: Int = 256)
    /// `idempotencyKey`: 1–128 printable ASCII characters.
    case idempotencyKey
    /// A list cursor from `nextCursor`; opaque to clients.
    case cursor
}

/// The fields of a `.structure` parameter. With `tag`, it is a tagged union: the tag field (a string with fixed values)
/// picks a variant, and each variant names the other fields it allows and requires.
public struct ObjectSchemaV2: Sendable, Equatable {
    public struct Variant: Sendable, Equatable {
        public let value: String
        public let allowed: [String]
        public let required: [String]
        public init(_ value: String, allowed: [String] = [], required: [String] = []) { self.value = value; self.allowed = allowed; self.required = required }
    }

    public let fields: [ParamV2]
    public let tag: String?
    public let variants: [Variant]

    public init(_ fields: [ParamV2], tag: String? = nil, variants: [Variant] = []) { self.fields = fields; self.tag = tag; self.variants = variants }
}

public struct ParamV2: Sendable, Equatable {
    public let name: String
    public let type: ParamTypeV2
    public let required: Bool
    /// Only update parameters accept `null`, which clears the field (API2-02 absent values).
    public let nullable: Bool
    public let summary: String
    /// A UUID that names no workspace resource or host (an app instance ID), so it needs no `ResourceRuleV2`. Every
    /// other UUID parameter must have one, so a forgotten scope check fails the contract test instead of failing open.
    public let unscoped: Bool

    public init(_ name: String, _ type: ParamTypeV2, required: Bool = false, nullable: Bool = false, unscoped: Bool = false, _ summary: String) {
        self.name = name; self.type = type; self.required = required; self.nullable = nullable; self.unscoped = unscoped; self.summary = summary
    }
}

/// When a conditional capability or rule applies. Every case names its parameters (dotted paths reach into
/// `.structure` params), so help, docs and the contract checker can read the rule.
public enum ConditionV2: Sendable, Equatable {
    /// The parameter is present and not `false` or `null`.
    case present(String)
    /// The parameter is sent at all, `null` included: an update that clears a field counts.
    case provided(String)
    /// The parameter has exactly this value.
    case equals(String, JSONValue)
    /// The parameter is an array that contains this string.
    case contains(String, String)
    case anyOf([ConditionV2])

    public var summary: String {
        switch self {
        case .present(let path): path
        case .provided(let path): "\(path) is sent"
        case .equals(let path, let value): "\(path) is \(Self.text(value))"
        case .contains(let path, let value): "\(path) has \(value)"
        case .anyOf(let conditions): conditions.map(\.summary).joined(separator: " or ")
        }
    }

    /// Every parameter path the condition reads.
    public var paths: [String] {
        switch self {
        case .present(let path), .provided(let path), .equals(let path, _), .contains(let path, _): [path]
        case .anyOf(let conditions): conditions.flatMap(\.paths)
        }
    }

    public func applies(to params: [String: JSONValue]) -> Bool {
        switch self {
        case .present(let path):
            switch Self.value(at: path, in: params) {
            case nil, .null?, .bool(false)?: false
            default: true
            }
        case .provided(let path): Self.value(at: path, in: params) != nil
        case .equals(let path, let value): Self.value(at: path, in: params) == value
        case .contains(let path, let value):
            if case .array(let items)? = Self.value(at: path, in: params) { items.contains(.string(value)) } else { false }
        case .anyOf(let conditions): conditions.contains { $0.applies(to: params) }
        }
    }

    /// `launch.kind` → `params["launch"]["kind"]`.
    public static func value(at path: String, in params: [String: JSONValue]) -> JSONValue? {
        var current: JSONValue? = .object(params)
        for part in path.split(separator: ".") {
            guard case .object(let object)? = current else { return nil }
            current = object[String(part)]
        }
        return current
    }

    private static func text(_ value: JSONValue) -> String {
        switch value {
        case .string(let text): text
        case .bool(let flag): String(flag)
        case .number(let number): number == number.rounded() ? String(Int64(number)) : String(number)
        default: "a value"
        }
    }
}

public struct ConditionalCapabilityV2: Sendable {
    public let capability: CapabilityV2
    public let condition: ConditionV2
    public init(_ capability: CapabilityV2, if condition: ConditionV2) { self.capability = capability; self.condition = condition }
}

/// A rule across parameters that types alone can't express.
public enum ParamRuleV2: Sendable, Equatable {
    /// An update method changes something: at least one of these is sent (`null` counts, it clears).
    case atLeastOne([String])
    /// Exactly one of these is sent.
    case exactlyOne([String])

    public var names: [String] {
        switch self {
        case .atLeastOne(let names), .exactlyOne(let names): names
        }
    }
}

/// A parameter naming a resource that must be visible to the grant; out-of-scope IDs are `NOT_FOUND`. `param` may be a
/// dotted path into a `.structure` param (`placement.spaceId`).
public struct ResourceRuleV2: Sendable, Equatable {
    public let kind: ResourceKind
    public let param: String
    /// The parameter is a list of IDs, each of which must be visible.
    public let list: Bool
    public init(_ kind: ResourceKind, _ param: String, list: Bool = false) { self.kind = kind; self.param = param; self.list = list }
}

/// What `expectedRevision` is compared with on a mutating method (API2-02 optimistic concurrency). The dispatcher
/// enforces it from this declaration, so no method can forget it.
public enum RevisionTargetV2: Sendable, Equatable {
    /// The resource named by this ID parameter (its kind comes from the parameter's resource rule; a branch answers
    /// with its tab's revision).
    case resource(param: String)
    /// The container for create and reorder methods: `workspace`, or a resource named by `param` (`space` + `spaceId`).
    case container(String, param: String? = nil)
    /// The resource named by whichever of these parameters is sent, dotted paths included: `agent.start`'s placement
    /// names the space that gets a tab or the pane that is split or used.
    case anyResource([String])
    /// No revision applies; the reason is shown by the contract test so exemptions stay deliberate.
    case exempt(reason: String)
}

public enum EffectV2: Sendable, Equatable {
    case read
    /// Mutating methods accept `idempotencyKey`, and `expectedRevision` unless the target is exempt. Destructive ones
    /// are flagged for MCP (`destructiveHint`).
    case mutating(revision: RevisionTargetV2, destructive: Bool = false)
}

/// One v2 method, declared once. Authorization, validation, MCP tool schemas and annotations, CLI help and the
/// contract tests are all derived from this value.
public struct MethodSpecV2: Sendable {
    public let name: String
    /// One sentence for MCP descriptions and CLI help.
    public let summary: String
    /// Declared parameters; the conventions add `limit`/`cursor`, `expectedRevision` and `idempotencyKey`.
    public let declaredParams: [ParamV2]
    public let capabilities: Set<CapabilityV2>
    /// Groups of which the grant needs at least one each (`agent.respond` or `session.input`, permissions.md), the
    /// intent-level capability first.
    public let anyOf: [[CapabilityV2]]
    public let conditional: [ConditionalCapabilityV2]
    public let rules: [ParamRuleV2]
    public let resources: [ResourceRuleV2]
    /// Needs a grant whose space scope is `all`.
    public let requiresAllSpaces: Bool
    /// Needs all-spaces scope only with these parameters.
    public let allSpacesIf: ConditionV2?
    /// Creates a top-level space: needs `all` or `created` space scope, and with `created` the space joins it.
    public let createsSpace: Bool
    /// Creates a top-level space only with these parameters (`host.connect` into a new space).
    public let createsSpaceIf: ConditionV2?
    public let effect: EffectV2
    /// Codes particular to the method; `errors` adds the ones every method of its kind can return.
    public let declaredErrors: Set<APIErrorCode>
    /// A `list` method: takes `limit` and `cursor`, returns `nextCursor` while more remain.
    public let paginated: Bool
    /// Needs a connection the server can push to (`events.subscribe`), so it is not an MCP tool.
    public let socketOnly: Bool

    public init(
        _ name: String, _ summary: String, params: [ParamV2] = [], capabilities: Set<CapabilityV2> = [], anyOf: [[CapabilityV2]] = [],
        conditional: [ConditionalCapabilityV2] = [], rules: [ParamRuleV2] = [], resources: [ResourceRuleV2] = [], allSpaces: Bool = false,
        allSpacesIf: ConditionV2? = nil, createsSpace: Bool = false, createsSpaceIf: ConditionV2? = nil, effect: EffectV2 = .read, errors: Set<APIErrorCode> = [],
        paginated: Bool = false, socketOnly: Bool = false
    ) {
        self.name = name; self.summary = summary; declaredParams = params; self.capabilities = capabilities; self.anyOf = anyOf; self.conditional = conditional
        self.rules = rules; self.resources = resources; requiresAllSpaces = allSpaces; self.allSpacesIf = allSpacesIf; self.createsSpace = createsSpace
        self.createsSpaceIf = createsSpaceIf; self.effect = effect; declaredErrors = errors; self.paginated = paginated; self.socketOnly = socketOnly
    }

    /// `space` for `space.list`, `remote` for `remote.helper.install`.
    public var area: String { String(name.prefix { $0 != "." }) }

    public var isMutating: Bool { if case .mutating = effect { true } else { false } }
    public var isDestructive: Bool { if case .mutating(_, true) = effect { true } else { false } }

    public var revisionTarget: RevisionTargetV2? { if case .mutating(let target, _) = effect { target } else { nil } }

    public static let limitParam = ParamV2(
        "limit", .integer(minimum: 1, maximum: Int64(PageV2.maximumLimit)), "Items per page, 1–\(PageV2.maximumLimit); default \(PageV2.defaultLimit).")
    public static let cursorParam = ParamV2("cursor", .cursor, "nextCursor from the previous page.")
    public static let expectedRevisionParam = ParamV2(
        "expectedRevision", .integer(minimum: 0), "Fail with CONFLICT (details.currentRevision) unless the target is still at this revision.")
    public static let idempotencyKeyParam = ParamV2(
        "idempotencyKey", .idempotencyKey, "1–128 printable ASCII characters. Repeating the call with the same key within 10 minutes returns the first result.")

    /// Every accepted parameter, in a stable order: declared, then pagination, then concurrency.
    public var params: [ParamV2] {
        var all = declaredParams
        if paginated { all += [Self.limitParam, Self.cursorParam] }
        if let target = revisionTarget {
            if case .exempt = target {} else { all.append(Self.expectedRevisionParam) }
            all.append(Self.idempotencyKeyParam)
        }
        return all
    }

    /// Every application error the method can return: its own plus those implied by its shape.
    public var errors: Set<APIErrorCode> {
        var codes = declaredErrors.union([.authRequired, .limitExceeded])
        if !capabilities.isEmpty || !anyOf.isEmpty || !conditional.isEmpty || requiresAllSpaces || allSpacesIf != nil || createsSpace || createsSpaceIf != nil
            || resources.contains(where: { $0.kind == .host })
        {
            codes.insert(.permissionDenied)
        }
        if !resources.isEmpty { codes.insert(.notFound) }
        if isMutating { codes.insert(.conflict) }
        if paginated { codes.insert(.invalidCursor) }
        return codes
    }

    /// The capabilities this call needs with these parameters, apart from the `anyOf` groups.
    public func requiredCapabilities(for params: [String: JSONValue]) -> Set<CapabilityV2> {
        capabilities.union(conditional.filter { $0.condition.applies(to: params) }.map(\.capability))
    }

    /// What `granted` lacks for this call, for `details.missing`. An unmet `anyOf` group is reported by its first member,
    /// the intent-level capability (`agent.respond` rather than `session.input`).
    public func missingCapabilities(for params: [String: JSONValue], granted: Set<CapabilityV2>) -> Set<CapabilityV2> {
        var missing = requiredCapabilities(for: params).subtracting(granted)
        // An empty group (refused by the catalog checks) can't be met: it fails closed on its first required capability.
        for group in anyOf where granted.isDisjoint(with: group) { missing.insert(group.first ?? capabilities.sorted().first ?? .workspaceRead) }
        return missing
    }

    /// Whether a grant holding `granted` can ever call this method (before conditional capabilities and scope).
    public func isReachable(with granted: Set<CapabilityV2>) -> Bool {
        capabilities.isSubset(of: granted) && anyOf.allSatisfy { !granted.isDisjoint(with: $0) }
    }

    /// Whether this call needs a grant whose space scope is `all`.
    public func needsAllSpaces(for params: [String: JSONValue]) -> Bool { requiresAllSpaces || allSpacesIf?.applies(to: params) == true }

    /// Whether this call creates a top-level space (needs `all` or `created` scope; with `created` it joins the scope).
    public func createsSpace(for params: [String: JSONValue]) -> Bool { createsSpace || createsSpaceIf?.applies(to: params) == true }
}
