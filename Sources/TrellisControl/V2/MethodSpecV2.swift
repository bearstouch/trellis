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
    /// `idempotencyKey`: 1–128 printable ASCII characters.
    case idempotencyKey
    /// A list cursor from `nextCursor`; opaque to clients.
    case cursor
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

/// When a conditional capability applies. `present` is the common case; `custom` keeps a description so help and
/// docs can show the rule.
public enum ConditionV2: Sendable {
    /// The parameter is present and not `false` or `null`.
    case present(String)
    case custom(String, @Sendable ([String: JSONValue]) -> Bool)

    public var summary: String {
        switch self {
        case .present(let name): name
        case .custom(let text, _): text
        }
    }

    public func applies(to params: [String: JSONValue]) -> Bool {
        switch self {
        case .present(let name):
            switch params[name] {
            case nil, .null?, .bool(false)?: false
            default: true
            }
        case .custom(_, let rule): rule(params)
        }
    }
}

public struct ConditionalCapabilityV2: Sendable {
    public let capability: CapabilityV2
    public let condition: ConditionV2
    public init(_ capability: CapabilityV2, if condition: ConditionV2) { self.capability = capability; self.condition = condition }
}

/// A parameter naming a resource that must be visible to the grant; out-of-scope IDs are `NOT_FOUND`.
public struct ResourceRuleV2: Sendable, Equatable {
    public let kind: ResourceKind
    public let param: String
    /// The parameter is a list of IDs, each of which must be visible.
    public let list: Bool
    public init(_ kind: ResourceKind, _ param: String, list: Bool = false) { self.kind = kind; self.param = param; self.list = list }
}

/// What `expectedRevision` is compared with on a mutating method (API2-02 optimistic concurrency).
public enum RevisionTargetV2: Sendable, Equatable {
    /// The resource named by this ID parameter.
    case resource(param: String)
    /// The container (`workspace`, `space`, …) for create and reorder methods.
    case container(String)
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
    public let conditional: [ConditionalCapabilityV2]
    public let resources: [ResourceRuleV2]
    /// Needs a grant whose space scope is `all`.
    public let requiresAllSpaces: Bool
    public let effect: EffectV2
    /// Codes particular to the method; `errors` adds the ones every method of its kind can return.
    public let declaredErrors: Set<APIErrorCode>
    /// A `list` method: takes `limit` and `cursor`, returns `nextCursor` while more remain.
    public let paginated: Bool

    public init(
        _ name: String, _ summary: String, params: [ParamV2] = [], capabilities: Set<CapabilityV2> = [], conditional: [ConditionalCapabilityV2] = [],
        resources: [ResourceRuleV2] = [], allSpaces: Bool = false, effect: EffectV2 = .read, errors: Set<APIErrorCode> = [], paginated: Bool = false
    ) {
        self.name = name; self.summary = summary; declaredParams = params; self.capabilities = capabilities; self.conditional = conditional
        self.resources = resources; requiresAllSpaces = allSpaces; self.effect = effect; declaredErrors = errors; self.paginated = paginated
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
        if !capabilities.isEmpty || !conditional.isEmpty || requiresAllSpaces || resources.contains(where: { $0.kind == .host }) { codes.insert(.permissionDenied) }
        if !resources.isEmpty { codes.insert(.notFound) }
        if isMutating { codes.insert(.conflict) }
        if paginated { codes.insert(.invalidCursor) }
        return codes
    }

    /// The capabilities this call needs with these parameters.
    public func requiredCapabilities(for params: [String: JSONValue]) -> Set<CapabilityV2> {
        capabilities.union(conditional.filter { $0.condition.applies(to: params) }.map(\.capability))
    }
}
