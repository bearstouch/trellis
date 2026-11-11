import XCTest
import TrellisCore
@testable import TrellisControl

/// Phase 2 catalog features: nested schemas, parameter rules, declarative conditions, revision targets and
/// normalization, and the contract checker for each.
final class CatalogV2Tests: XCTestCase {
    private func spec(_ name: String) throws -> MethodSpecV2 { try XCTUnwrap(MethodCatalogV2.spec(name), name) }

    private func fields(_ spec: MethodSpecV2, _ params: [String: JSONValue]) -> [String: JSONValue]? {
        guard case .failure(let error) = spec.validate(.object(params)) else { return nil }
        XCTAssertEqual(error.code, -32602)
        return error.details?["fields"].flatMap { if case .object(let fields) = $0 { fields } else { nil } }
    }

    private let pane = JSONValue.string(UUID().uuidString)

    // MARK: Nested schemas

    func testLaunchDescriptorsAreValidatedFieldByField() throws {
        let start = try spec("session.start")
        XCTAssertEqual(fields(start, ["paneId": pane, "launch": .object([:])]), ["launch.kind": .string("required: one of shell, process, ssh")])
        XCTAssertEqual(
            fields(start, ["paneId": pane, "launch": .object(["kind": .string("process"), "arguments": .array([.number(1)])])]),
            ["launch.executable": .string("required: string of at most 4096 bytes"), "launch.directory": .string("required: string of at most 4096 bytes"), "launch.arguments": .string("array of at most 256 strings")])
        XCTAssertEqual(
            fields(start, ["paneId": pane, "launch": .object(["kind": .string("ssh"), "hostId": .string("nope"), "directory": .string("/tmp")])]),
            ["launch.hostId": .string("UUID"), "launch.directory": .string("not used with this kind")], "A variant takes only its own fields")
        XCTAssertEqual(
            fields(start, ["paneId": pane, "launch": .object(["kind": .string("agent"), "agentId": .string("trellis-claude-code")])]),
            ["launch.kind": .string("one of shell, process, ssh"), "launch.agentId": .string("unknown parameter")], "Agents start only through agent.start")
        XCTAssertEqual(
            fields(start, ["paneId": pane, "launch": .object(["kind": .string("shell"), "environment": .object(["A": .number(1)])])]),
            ["launch.environment": .string("object of at most 256 string values")])
        XCTAssertNil(fields(start, ["paneId": pane, "launch": .object(["kind": .string("shell"), "environment": .object(["A": .string("1")])])]))
        XCTAssertNil(fields(start, ["paneId": pane, "launch": .object(["kind": .string("ssh"), "hostId": pane])]))

        let connect = try spec("host.connect")
        XCTAssertEqual(fields(connect, ["hostId": pane]), ["placement": .string("required: object with kind tab, split, space")])
        XCTAssertEqual(fields(connect, ["hostId": pane, "placement": .object(["kind": .string("tab")])]), ["placement.spaceId": .string("required: UUID")])
        XCTAssertNil(fields(connect, ["hostId": pane, "placement": .object(["kind": .string("space")])]))
    }

    func testNestedSchemasAreClosedAndDescribeTheirVariants() throws {
        guard case .object(let schema) = try spec("session.start").inputSchema, case .object(let properties)? = schema["properties"],
            case .object(let launch)? = properties["launch"], case .object(let fields)? = launch["properties"], case .object(let kind)? = fields["kind"]
        else { return XCTFail() }
        XCTAssertEqual(launch["type"], .string("object"))
        XCTAssertEqual(launch["additionalProperties"], .bool(false))
        XCTAssertEqual(launch["required"], .array([.string("kind")]))
        XCTAssertEqual(Set(fields.keys), ["kind", "directory", "executable", "arguments", "environment", "hostId"])
        XCTAssertEqual(kind["enum"], .array([.string("shell"), .string("process"), .string("ssh")]))
        guard case .string(let description)? = kind["description"] else { return XCTFail() }
        XCTAssertTrue(description.contains("process (executable, arguments?, directory, environment?)"), description)
        XCTAssertTrue(description.contains("ssh (hostId)"), description)
        guard case .object(let environment)? = fields["environment"] else { return XCTFail() }
        XCTAssertEqual(environment["additionalProperties"], .object(["type": .string("string")]))
        XCTAssertEqual(try spec("session.start").synopsis, "session.start paneId=<uuid> [launch=<json>] [expectedRevision=<integer>] [idempotencyKey=<key>]")
    }

    // MARK: Rules

    func testUpdatesNeedAChangeAndInputNeedsExactlyOneEncoding() throws {
        let id = pane
        let update = try spec("tab.update")
        XCTAssertEqual(fields(update, ["id": id]), ["title": .string("send at least one of title, color"), "color": .string("send at least one of title, color")])
        XCTAssertNil(fields(update, ["id": id, "title": .null]), "null returns to the automatic title, which is a change")
        XCTAssertEqual(fields(try spec("host.update"), ["id": id])?.count, 6)
        let input = try spec("session.sendInput")
        XCTAssertEqual(fields(input, ["id": id])?["text"], .string("send exactly one of text, base64"))
        XCTAssertEqual(fields(input, ["id": id, "text": .string("a"), "base64": .string("YQ==")])?["base64"], .string("send exactly one of text, base64"))
        XCTAssertNil(fields(input, ["id": id, "base64": .string("YQ==")]))
        let list = try spec("pane.list")
        XCTAssertNotNil(fields(list, [:]))
        XCTAssertNotNil(fields(list, ["tabId": id, "spaceId": id]))
        XCTAssertNil(fields(list, ["spaceId": id]))
        XCTAssertNil(fields(try spec("workspace.get"), ["include": .array([.string("agents")])]), "agents arrived with phase 5")
        let respond = try spec("agent.respond")
        XCTAssertNil(fields(respond, ["sessionId": id, "action": .string("reply"), "text": .string("yes")]))
        XCTAssertEqual(fields(respond, ["sessionId": id, "action": .string("accept")])?["action"], .string("one of approve, reject, reply"))
        let start = try spec("agent.start")
        XCTAssertNotNil(fields(start, ["agentId": .string("trellis-codex"), "placement": .object(["kind": .string("pane")])])?["placement.paneId"])
        XCTAssertNotNil(fields(start, ["agentId": .string("trellis-codex"), "placement": .object(["kind": .string("tab"), "spaceId": id, "axis": .string("x")])]))
    }

    // MARK: Conditions

    func testConditionalCapabilitiesAreDeclarativeRules() throws {
        let start = try spec("session.start")
        func needs(_ spec: MethodSpecV2, _ params: [String: JSONValue]) -> [String] { spec.requiredCapabilities(for: params).map(\.rawValue).sorted() }
        XCTAssertEqual(needs(start, [:]), ["session.start"])
        XCTAssertEqual(needs(start, ["launch": .object(["kind": .string("shell")])]), ["session.start"])
        XCTAssertEqual(needs(start, ["launch": .object(["kind": .string("ssh"), "hostId": pane])]), ["session.start"], "A saved host is governed by host scope")
        for launch: JSONValue in [
            .object(["kind": .string("shell"), "directory": .string("/tmp")]), .object(["kind": .string("process")]),
            .object(["kind": .string("shell"), "environment": .object(["A": .string("1")])])
        ] {
            XCTAssertEqual(needs(start, ["launch": launch]), ["session.execute", "session.start"], "\(launch)")
        }
        XCTAssertEqual(start.requirementSummary, "session.start (+session.execute if launch.kind is process or launch.directory or launch.environment)")
        let restart = try spec("session.restart")
        XCTAssertEqual(needs(restart, ["force": .bool(true)]), ["session.close", "session.start"])
        let update = try spec("host.update")
        XCTAssertEqual(needs(update, ["name": .string("x"), "tags": .null]), ["host.write"])
        XCTAssertEqual(needs(update, ["user": .null]), ["host.write", "session.execute"], "Clearing a connection field changes where ssh connects")
        let connect = try spec("host.connect")
        // A new space needs all or created scope (permissions.md#scopes), never a fixed set of spaces.
        XCTAssertTrue(connect.createsSpace(for: ["placement": .object(["kind": .string("space")])]))
        XCTAssertFalse(connect.createsSpace(for: ["placement": .object(["kind": .string("tab")])]))
        XCTAssertFalse(connect.needsAllSpaces(for: ["placement": .object(["kind": .string("space")])]))
        XCTAssertEqual(connect.requirementSummary, "session.start + workspace.write, all or created spaces if placement.kind is space")
        XCTAssertEqual(try spec("space.create").requirementSummary, "workspace.write (+session.start if start), all or created spaces")
        XCTAssertTrue(connect.errors.contains(.permissionDenied))
        XCTAssertEqual(ConditionV2.contains("include", "layout").summary, "include has layout")
        XCTAssertTrue(ConditionV2.contains("include", "layout").applies(to: ["include": .array([.string("layout")])]))
        XCTAssertFalse(ConditionV2.provided("user").applies(to: [:]))
    }

    // MARK: Revisions and normalization

    func testEveryMutatingMethodNamesAnEnforceableRevisionTarget() throws {
        var exempt: [String] = []
        for spec in MethodCatalogV2.methods where spec.isMutating {
            guard case .exempt = spec.revisionTarget else {
                // Fill every UUID the declaration names so the subject can be resolved.
                var params: [String: JSONValue] = [:]
                for param in spec.params where param.type == .uuid { params[param.name] = pane }
                // A placement names the space or pane its expectedRevision is compared with.
                if spec.params.contains(where: { $0.name == "placement" }) { params["placement"] = .object(["kind": .string("pane"), "paneId": pane]) }
                XCTAssertNotNil(RevisionSubjectV2.of(spec, ParamsV2(params)), spec.name)
                continue
            }
            exempt.append(spec.name)
        }
        XCTAssertEqual(exempt, ["workspace.save", "host.create", "project.create", "project.capture"], "Exemptions stay deliberate")
        let id = UUID()
        XCTAssertEqual(RevisionSubjectV2.of(try spec("pane.resize"), ParamsV2(["branchId": .string(id.uuidString)])), .resource(.branch, id))
        XCTAssertEqual(RevisionSubjectV2.of(try spec("tab.create"), ParamsV2(["spaceId": .string(id.uuidString)])), .resource(.space, id))
        XCTAssertEqual(RevisionSubjectV2.of(try spec("space.reorder"), ParamsV2([:])), .workspace)
        XCTAssertEqual(RevisionSubjectV2.of(try spec("host.connect"), ParamsV2(["hostId": .string(id.uuidString)])), .resource(.host, id))
        let tab = JSONValue.object(["kind": .string("tab"), "spaceId": .string(id.uuidString)]), split = JSONValue.object(["kind": .string("split"), "paneId": .string(id.uuidString)])
        XCTAssertEqual(RevisionSubjectV2.of(try spec("agent.start"), ParamsV2(["placement": tab])), .resource(.space, id), "A new tab compares its space")
        XCTAssertEqual(RevisionSubjectV2.of(try spec("agent.install"), ParamsV2(["placement": split])), .resource(.pane, id), "A split compares the pane it splits")
        XCTAssertEqual(RevisionSubjectV2.of(try spec("agent.respond"), ParamsV2(["sessionId": .string(id.uuidString)])), .resource(.session, id))
    }

    func testUUIDsAreNormalizedBeforeIdempotencyComparesThem() throws {
        let id = UUID(), host = UUID()
        guard
            case .success(let params) = try spec("session.start").validate(
                .object(["paneId": .string(id.uuidString.uppercased()), "launch": .object(["kind": .string("ssh"), "hostId": .string(host.uuidString.uppercased())])]))
        else { return XCTFail() }
        XCTAssertEqual(params["paneId"], .string(id.uuidString.lowercased()))
        XCTAssertEqual(params["launch"], .object(["kind": .string("ssh"), "hostId": .string(host.uuidString.lowercased())]))
        guard case .success(let reorder) = try spec("space.reorder").validate(.object(["ids": .array([.string(id.uuidString)])])) else { return XCTFail() }
        XCTAssertEqual(reorder["ids"], .array([.string(id.uuidString.lowercased())]))
    }

    // MARK: Contract checker

    func testContractCheckerCoversTheNewDeclarationFeatures() {
        let tagged = ParamV2(
            "launch", .structure(ObjectSchemaV2([ParamV2("kind", .string(values: ["a", "b"]), "Kind."), ParamV2("hostId", .uuid, "Host.")], tag: "kind", variants: [.init("a", allowed: ["hostId"])])),
            "Launch.")
        let broken: [(MethodSpecV2, String)] = [
            (MethodSpecV2("session.start", "Nested ID.", params: [tagged]), "UUID parameter launch.hostId needs a resource rule"),
            (MethodSpecV2("session.start", "Tag mismatch.", params: [tagged], resources: [ResourceRuleV2(.host, "launch.hostId")]), "launch.kind must be a string listing exactly the variants"),
            (
                MethodSpecV2(
                    "session.start", "Bad variant.",
                    params: [ParamV2("launch", .structure(ObjectSchemaV2([ParamV2("kind", .string(values: ["a"]), "Kind.")], tag: "kind", variants: [.init("a", allowed: ["nope"])])), "L.")]),
                "variant a of launch names undeclared"
            ),
            (
                MethodSpecV2("tab.update", "Bad value.", params: [ParamV2("color", .string(values: ["red"]), "C.")], conditional: [ConditionalCapabilityV2(.sessionStart, if: .equals("color", .string("pink")))]),
                "can't take"
            ),
            (MethodSpecV2("tab.update", "Nested nothing.", conditional: [ConditionalCapabilityV2(.sessionStart, if: .anyOf([.present("launch.kind")]))]), "undeclared launch.kind"),
            (MethodSpecV2("tab.list", "Contains.", params: [ParamV2("include", .string(), "I.")], conditional: [ConditionalCapabilityV2(.sessionStart, if: .contains("include", "x"))]), "can't hold it"),
            (MethodSpecV2("tab.get", "Rule on required.", params: [ParamV2("a", .string(), required: true, "A."), ParamV2("b", .string(), "B.")], rules: [.atLeastOne(["a", "b"])]), "declared optional"),
            (MethodSpecV2("tab.get", "Rule on one.", params: [ParamV2("a", .string(), "A.")], rules: [.exactlyOne(["a"])]), "at least two"),
            (MethodSpecV2("tab.create", "Container without ID.", effect: .mutating(revision: .container("space"))), "space needs the parameter naming it"),
            (
                MethodSpecV2(
                    "tab.create", "Container of the wrong kind.", params: [ParamV2("tabId", .uuid, required: true, "T.")], resources: [ResourceRuleV2(.tab, "tabId")],
                    effect: .mutating(revision: .container("space", param: "tabId"))),
                "needs a required space ID parameter"
            ),
            (
                MethodSpecV2("tab.close", "Unscoped target.", params: [ParamV2("id", .uuid, required: true, unscoped: true, "ID.")], effect: .mutating(revision: .resource(param: "id"))),
                "needs a resource rule for its kind"
            ),
            (MethodSpecV2("host.connect", "All spaces if nothing.", allSpacesIf: .equals("placement.kind", .string("space"))), "undeclared placement.kind")
        ]
        for (spec, expected) in broken {
            let problems = MethodCatalogV2.problems(in: [spec])
            XCTAssertTrue(problems.contains { $0.contains(expected) }, "\(spec.summary): expected “\(expected)” in \(problems)")
        }
    }
}
