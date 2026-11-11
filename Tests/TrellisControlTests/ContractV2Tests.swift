import XCTest
import TrellisCore
@testable import TrellisControl

/// API2-01–03 contract harness: walks the v2 method catalog and the error registry, and checks both against the
/// draft contract pages in docs/api/v2.
final class ContractV2Tests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func page(_ name: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent("docs/api/v2/\(name)"), encoding: .utf8)
    }

    /// Shapes later phases declare, so the checks below run on mutating, scoped, paginated and destructive methods too.
    static let samples: [MethodSpecV2] = [
        MethodSpecV2(
            "space.list", "List spaces.", params: [ParamV2("query", .string(maxBytes: 200), "Filter.")], capabilities: [.workspaceRead], paginated: true),
        MethodSpecV2(
            "tab.update", "Rename a tab or set its color.",
            params: [
                ParamV2("id", .uuid, required: true, "Tab ID."), ParamV2("title", .string(maxBytes: 200), nullable: true, "Title, or null for automatic."),
                ParamV2("color", .string(values: ["red", "blue"]), nullable: true, "Color label, or null to clear it.")
            ], capabilities: [.workspaceWrite], resources: [ResourceRuleV2(.tab, "id")], effect: .mutating(revision: .resource(param: "id"))),
        MethodSpecV2(
            "pane.close", "Close a pane.",
            params: [
                ParamV2("id", .uuid, required: true, "Pane ID."), ParamV2("allowRunning", .boolean, "Stop running sessions."), ParamV2("force", .boolean, "Force.")
            ], capabilities: [.workspaceWrite], conditional: [ConditionalCapabilityV2(.sessionClose, if: .present("allowRunning"))],
            resources: [ResourceRuleV2(.pane, "id")], effect: .mutating(revision: .resource(param: "id"), destructive: true), errors: [.confirmationRequired, .closePending]),
        MethodSpecV2(
            "space.reorder", "Reorder spaces.", params: [ParamV2("ids", .uuidList(), required: true, "Every space ID in order.")], capabilities: [.workspaceWrite],
            resources: [ResourceRuleV2(.space, "ids", list: true)], allSpaces: true, effect: .mutating(revision: .container("workspace")))
    ]

    // MARK: - Catalog (API2-02)

    func testCatalogFollowsTheConventions() {
        XCTAssertEqual(MethodCatalogV2.problems(in: MethodCatalogV2.methods), [])
        XCTAssertEqual(MethodCatalogV2.problems(in: Self.samples), [], "The sample shapes are valid declarations")
        XCTAssertEqual(MethodCatalogV2.methods.map(\.name), ["system.info", "grant.get"], "Phase 1 exercises the path with two methods")
    }

    func testEveryMethodHasAPolicyADescriptionAndAContractRow() throws {
        let methods = try page("methods.md")
        for spec in MethodCatalogV2.methods {
            XCTAssertNotNil(MethodCatalogV2.spec(spec.name), spec.name)
            XCTAssertFalse(spec.summary.isEmpty, spec.name)
            XCTAssertFalse(spec.requirementSummary.isEmpty, "\(spec.name) has a policy (capabilities, scope) derived from its declaration")
            XCTAssertTrue(methods.contains("| `\(spec.name)` |"), "\(spec.name) has a row in methods.md")
            XCTAssertTrue(spec.helpText.hasPrefix(spec.synopsis), "CLI help is derived from the declaration")
            XCTAssertTrue(spec.errors.isSuperset(of: [.authRequired, .limitExceeded]), spec.name)
        }
        XCTAssertNil(MethodCatalogV2.spec("window.list"))
        XCTAssertNil(MethodCatalogV2.spec("space.list"), "v1 methods are not in the v2 catalog until their phase lands")
        XCTAssertFalse(MethodCatalogV2.isMutating("system.info"))
        XCTAssertTrue(MethodCatalogV2.isMutating("no.suchMethod"), "Unknown names are treated as mutating")
    }

    func testMutatingMethodsTakeIdempotencyKeyAndExpectedRevision() {
        for spec in MethodCatalogV2.methods + Self.samples {
            let names = spec.params.map(\.name)
            if spec.isMutating {
                XCTAssertTrue(names.contains("idempotencyKey"), spec.name)
                if case .exempt? = spec.revisionTarget {} else { XCTAssertTrue(names.contains("expectedRevision"), spec.name) }
                XCTAssertTrue(spec.errors.contains(.conflict), spec.name)
            } else {
                XCTAssertFalse(names.contains("idempotencyKey") || names.contains("expectedRevision"), spec.name)
            }
            if spec.paginated { XCTAssertTrue(names.contains("limit") && names.contains("cursor") && spec.errors.contains(.invalidCursor), spec.name) }
        }
        let close = Self.samples[2]
        XCTAssertEqual(close.params.map(\.name), ["id", "allowRunning", "force", "expectedRevision", "idempotencyKey"])
        XCTAssertEqual(close.requirementSummary, "workspace.write (+session.close if allowRunning)")
        XCTAssertEqual(Self.samples[3].requirementSummary, "workspace.write, all spaces")
        XCTAssertEqual(close.synopsis, "pane.close id=<uuid> [allowRunning=<true|false>] [force=<true|false>] [expectedRevision=<integer>] [idempotencyKey=<key>]")
        XCTAssertEqual(close.errors, [.authRequired, .limitExceeded, .permissionDenied, .notFound, .conflict, .confirmationRequired, .closePending])
    }

    func testContractCheckerCatchesBrokenDeclarations() {
        let broken: [(MethodSpecV2, String)] = [
            (MethodSpecV2("window.list", "Old.", paginated: true), "v1 alias"),
            (MethodSpecV2("Space_List", "Bad name."), "lowerCamelCase"),
            (MethodSpecV2("space.get", ""), "summary"),
            (MethodSpecV2("space.list", "Unpaged."), "list methods take limit"),
            (MethodSpecV2("space.get", "Paged.", paginated: true), "only list methods"),
            (MethodSpecV2("tab.get", "Alias param.", params: [ParamV2("windowId", .uuid, "Old.")]), "v1 alias"),
            (MethodSpecV2("tab.get", "Scope on a string.", params: [ParamV2("id", .string(), required: true, "ID.")], resources: [ResourceRuleV2(.tab, "id")]), "must be declared"),
            (
                MethodSpecV2("tab.close", "Revision on nothing.", params: [ParamV2("tabId", .uuid, required: true, "ID.")], effect: .mutating(revision: .resource(param: "id"))),
                "revision target"
            ),
            (MethodSpecV2("tab.close", "Unexplained.", effect: .mutating(revision: .exempt(reason: ""))), "needs a reason"),
            (
                MethodSpecV2("tab.create", "Condition on nothing.", conditional: [ConditionalCapabilityV2(.sessionStart, if: .present("start"))], effect: .mutating(revision: .container("space"))),
                "undeclared start"
            ),
            (MethodSpecV2("tab.get", "Nullable required.", params: [ParamV2("id", .uuid, required: true, nullable: true, "ID.")]), "can't be null"),
            (MethodSpecV2("tab.get", "Unscoped ID.", params: [ParamV2("id", .uuid, required: true, "ID.")]), "needs a resource rule")
        ]
        for (spec, expected) in broken {
            let problems = MethodCatalogV2.problems(in: [spec])
            XCTAssertTrue(problems.contains { $0.contains(expected) }, "\(spec.name): expected “\(expected)” in \(problems)")
        }
        let instance = MethodSpecV2("events.poll", "Poll.", params: [ParamV2("instanceId", .uuid, unscoped: true, "App instance ID.")])
        XCTAssertEqual(MethodCatalogV2.problems(in: [instance]), [], "IDs that name no resource are declared unscoped")
        let twice = MethodCatalogV2.problems(in: [MethodCatalogV2.methods[0], MethodCatalogV2.methods[0]])
        XCTAssertTrue(twice.contains { $0.contains("declared twice") })
    }

    // MARK: - Generated schemas

    func testGeneratedSchemasAreClosedJSONSchemaObjects() throws {
        let types: Set<String> = ["string", "integer", "number", "boolean", "object", "array", "null"]
        for spec in MethodCatalogV2.methods + Self.samples {
            guard case .object(let schema) = spec.inputSchema, case .object(let properties)? = schema["properties"] else { return XCTFail(spec.name) }
            XCTAssertEqual(schema["type"], .string("object"), spec.name)
            XCTAssertEqual(schema["additionalProperties"], .bool(false), spec.name)
            XCTAssertEqual(Set(properties.keys), Set(spec.params.map(\.name)), spec.name)
            for (name, property) in properties {
                guard case .object(let fields) = property else { return XCTFail("\(spec.name).\(name)") }
                switch fields["type"] {
                case .string(let type)?: XCTAssertTrue(types.contains(type), "\(spec.name).\(name)")
                case .array(let list)?: XCTAssertTrue(list.allSatisfy { if case .string(let type) = $0 { types.contains(type) } else { false } })
                default: XCTFail("\(spec.name).\(name) has no type")
                }
                XCTAssertNotNil(fields["description"], "\(spec.name).\(name)")
            }
            let required = spec.params.filter(\.required).map { JSONValue.string($0.name) }
            XCTAssertEqual(schema["required"], required.isEmpty ? nil : .array(required), spec.name)
            // A generated schema is valid JSON and round-trips.
            let data = try JSONEncoder().encode(spec.inputSchema)
            XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: data), spec.inputSchema)
        }
        guard case .object(let update) = Self.samples[1].inputSchema, case .object(let properties)? = update["properties"],
            case .object(let color)? = properties["color"]
        else { return XCTFail() }
        XCTAssertEqual(color["type"], .array([.string("string"), .string("null")]), "Update params that clear take null")
        XCTAssertEqual(color["enum"], .array([.string("red"), .string("blue"), .null]))
        XCTAssertEqual(Self.samples[2].toolAnnotations, .object(["readOnlyHint": .bool(false), "destructiveHint": .bool(true), "openWorldHint": .bool(false)]))
        XCTAssertEqual(MethodCatalogV2.spec("grant.get")?.toolAnnotations, .object(["readOnlyHint": .bool(true), "openWorldHint": .bool(false)]))
        XCTAssertEqual(Self.samples[2].toolName, "pane_close")
        XCTAssertEqual(MethodCatalogV2.toolName("session.sendInput"), "session_send_input")
    }

    func testSchemaValidationReportsEachField() {
        let update = Self.samples[1], close = Self.samples[2]
        func fields(_ spec: MethodSpecV2, _ params: JSONValue?) -> [String: JSONValue]? {
            guard case .failure(let error) = spec.validate(params) else { return nil }
            XCTAssertEqual(error.code, -32602)
            XCTAssertNil(error.appCode)
            return error.details?["fields"].flatMap { if case .object(let fields) = $0 { fields } else { nil } }
        }
        let id = UUID().uuidString
        XCTAssertEqual(fields(update, nil), ["id": .string("required: UUID")])
        XCTAssertEqual(fields(update, .array([])), ["params": .string("object")])
        XCTAssertEqual(
            fields(update, .object(["id": .string("nope"), "color": .string("pink"), "windowId": .string(id), "expectedRevision": .number(-1), "idempotencyKey": .string("é")])),
            [
                "id": .string("UUID"), "color": .string("one of red, blue"), "windowId": .string("unknown parameter"), "expectedRevision": .string("integer ≥ 0"),
                "idempotencyKey": .string("1–128 printable ASCII characters")
            ])
        XCTAssertEqual(fields(close, .object(["id": .string(id), "force": .null])), ["force": .string("boolean; omit it instead of null")], "null only clears update fields")
        XCTAssertEqual(fields(close, .object(["id": .string(id), "expectedRevision": .number(1.5)])), ["expectedRevision": .string("integer ≥ 0")])
        XCTAssertEqual(fields(close, .object(["id": .string(id), "bad key!": .bool(true)])), ["params": .string("unknown parameters")], "Odd names are never echoed")
        let many = JSONValue.object(Dictionary(uniqueKeysWithValues: (0..<100).map { ("extra\($0)", JSONValue.bool(true)) }))
        XCTAssertEqual(fields(close, many)?.count, MethodSpecV2.maximumFieldErrors, "Field errors are bounded")

        guard case .success(let valid) = update.validate(.object(["id": .string(id.lowercased()), "title": .null, "color": .string("red")])) else { return XCTFail() }
        XCTAssertEqual(try valid.uuid("id"), UUID(uuidString: id), "UUIDs are accepted in any case")
        XCTAssertNil(try valid.optionalString("title"))
        guard case .success = close.validate(.object(["id": .string(id), "expectedRevision": .number(3), "idempotencyKey": .string("retry 1")])) else { return XCTFail() }
        guard case .success = MethodCatalogV2.spec("system.info")!.validate(nil) else { return XCTFail("No params is an empty object") }
    }

    // MARK: - Error registry (API2-03)

    func testErrorRegistryMatchesTheContractTable() throws {
        let text = try page("index.md")
        let section = try XCTUnwrap(text.range(of: "## Errors (API2-03)")).upperBound
        let end = try XCTUnwrap(text.range(of: "## Requirements", range: section..<text.endIndex)).lowerBound
        var documented: [String: (retryable: String, exit: String)] = [:]
        for line in text[section..<end].split(separator: "\n") where line.hasPrefix("| `") && !line.hasPrefix("| `code`") {
            let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            XCTAssertEqual(cells.count, 4, String(line))
            documented[cells[0].trimmingCharacters(in: CharacterSet(charactersIn: "`"))] = (cells[2], cells[3])
        }
        XCTAssertEqual(Set(documented.keys), Set(APIErrorCode.allCases.map(\.rawValue)), "Every registry code is in the table and nothing else")
        for code in APIErrorCode.allCases {
            XCTAssertEqual(documented[code.rawValue]?.retryable, code.retryability.rawValue, code.rawValue)
            XCTAssertEqual(documented[code.rawValue]?.exit, String(code.cliExitStatus), code.rawValue)
        }
    }

    func testEveryCodeUsedInSourcesIsRegistered() throws {
        let sources = Self.root.appendingPathComponent("Sources")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        let registry = Set(APIErrorCode.allCases.map(\.rawValue))
        var used = Set<String>()
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for match in text.matches(of: /(?:application\(\s*|appCode == )"([A-Z_]+)"/) { used.insert(String(match.output.1)) }
        }
        XCTAssertTrue(used.contains("REMOTE_DISCONNECTED"), "The scan sees multi-line call sites")
        XCTAssertEqual(used.subtracting(registry), [], "Application codes in Sources/ must be in APIErrorCode")
    }

    func testKnownErrorCodesCLIAndMCPMapsDeriveFromTheRegistry() {
        XCTAssertEqual(DiagnosticsReport.knownErrorCodes, Set(APIErrorCode.allCases.map(\.rawValue) + ["UI_ERROR"]))
        XCTAssertTrue(DiagnosticsReport.knownErrorCodes.contains("REMOTE_DISCONNECTED"), "Was missing before the registry")
        XCTAssertEqual(APIErrorCode.cliExitStatus(appCode: "NOT_FOUND", rpcCode: -32000), 3)
        XCTAssertEqual(APIErrorCode.cliExitStatus(appCode: "UNSUPPORTED_VERSION", rpcCode: -32000), 2)
        XCTAssertEqual(APIErrorCode.cliExitStatus(appCode: "SOMETHING_NEW", rpcCode: -32000), 8)
        XCTAssertEqual(APIErrorCode.cliExitStatus(appCode: nil, rpcCode: -32602), 2)
        XCTAssertEqual(APIErrorCode.cliExitStatus(appCode: nil, rpcCode: -32601), 3)
        XCTAssertEqual(APIErrorCode.cliExitStatus(appCode: nil, rpcCode: -32603), 8)
        for code in APIErrorCode.allCases {
            XCTAssertEqual(code.mcpDisposition, code == .authRequired ? .toolErrorEndingSession : .toolError, code.rawValue)
            XCTAssertEqual(ControlError.api(code, "x").retryable, code.retryability == .yes, code.rawValue)
            XCTAssertEqual(ControlError.api(code, "x").appCode, code.rawValue)
        }
        XCTAssertTrue(ControlError.api(.invalidState, "Starting.", retryable: true).retryable, "`sometimes` codes decide per error")
    }

    // MARK: - Conventions (API2-02)

    func testIDsAreLowercaseOutAndAnyCaseIn() {
        let id = UUID()
        XCTAssertEqual(ConventionsV2.id(id), id.uuidString.lowercased())
        XCTAssertEqual(ConventionsV2.parseID(id.uuidString.lowercased()), id)
        XCTAssertEqual(ConventionsV2.parseID(id.uuidString.uppercased()), id)
        XCTAssertNil(ConventionsV2.parseID(""))
        XCTAssertNil(ConventionsV2.parseID("{\(id.uuidString)}"))
    }

    func testTimestampsAreRFC3339UTCWithMilliseconds() {
        XCTAssertEqual(ConventionsV2.timestamp(Date(timeIntervalSince1970: 1_800_000_000)), "2027-01-15T08:00:00.000Z")
        XCTAssertEqual(ConventionsV2.timestamp(Date(timeIntervalSince1970: 1_800_000_000.402)), "2027-01-15T08:00:00.402Z")
        XCTAssertEqual(ConventionsV2.timestamp(Date(timeIntervalSince1970: 1_800_000_000.9996)), "2027-01-15T08:00:01.000Z")
        XCTAssertEqual(ConventionsV2.timestamp(Date(timeIntervalSince1970: -0.5)), "1969-12-31T23:59:59.500Z")
    }

    func testResultsOmitAbsentValuesAndKeepTheirTypes() throws {
        var object = ResultObjectV2()
        let id = UUID()
        object.set("empty", "" as String?)
        object.set("missing", nil as String?)
        object.set("noID", nil as UUID?)
        object.set("noNumber", nil as Int?)
        object.set("exitCode", 0 as Int?)
        object.set("busy", false as Bool?)
        object.set("id", id as UUID?)
        object.set("at", Date(timeIntervalSince1970: 0) as Date?)
        object.set("nothing", JSONValue.null as JSONValue?)
        XCTAssertEqual(
            object.json,
            .object(["exitCode": .number(0), "busy": .bool(false), "id": .string(id.uuidString.lowercased()), "at": .string("1970-01-01T00:00:00.000Z")]),
            "Absent values are omitted; real zeros and false stay")
        XCTAssertEqual(ConventionsV2.resource("tab", .object([:]), workspaceRevision: 7), .object(["tab": .object([:]), "workspaceRevision": .number(7)]))
        XCTAssertEqual(ConventionsV2.list("tabs", [], revision: 3), .object(["tabs": .array([]), "revision": .number(3)]))
        XCTAssertEqual(ConventionsV2.list("tabs", [], revision: 3, nextCursor: "c"), .object(["tabs": .array([]), "revision": .number(3), "nextCursor": .string("c")]))
        XCTAssertEqual(
            ConventionsV2.deleted(kind: "pane", id: id, workspaceRevision: 9),
            .object(["deleted": .object(["kind": .string("pane"), "id": .string(id.uuidString.lowercased())]), "workspaceRevision": .number(9)]))
        // Numbers are JSON numbers on the wire, not strings or 2.0.
        let line = String(decoding: ControlSession.encode(result: .object(["revision": ConventionsV2.number(UInt64(42))]), id: .number(1)), as: UTF8.self)
        XCTAssertTrue(line.contains(#""revision":42"#), line)
    }

    func testPaginationAndCursors() throws {
        let items = Array(0..<250)
        var page = try PageV2(ParamsV2([:]), method: "space.list")
        XCTAssertEqual(page.limit, 100)
        var seen: [Int] = []
        var pages = 0
        while true {
            let (slice, next) = page.slice(items)
            seen += slice; pages += 1
            guard let next else { break }
            page = try PageV2(ParamsV2(["cursor": .string(next)]), method: "space.list")
        }
        XCTAssertEqual(seen, items)
        XCTAssertEqual(pages, 3)
        XCTAssertNil(try PageV2(ParamsV2(["limit": .number(500)]), method: "space.list").slice(items).nextCursor)
        let first = try PageV2(ParamsV2(["limit": .number(10)]), method: "space.list").slice(items)
        XCTAssertEqual(first.items, Array(0..<10))
        let cursor = try XCTUnwrap(first.nextCursor)
        // Cursors are signed by this app instance: an edited offset, a cursor built by hand or a v1-style unsigned one fails.
        let forged = Data("c1|space.list|20".utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        let signature = String(cursor.split(separator: ".").last ?? "")
        for bad in [cursor + "x", "not a cursor", "Yzl8c3BhY2UubGlzdHwtMQ", forged, forged + "." + signature] {
            XCTAssertThrowsError(try PageV2(ParamsV2(["cursor": .string(bad)]), method: "space.list")) { XCTAssertEqual(($0 as? ControlError)?.appCode, "INVALID_CURSOR", bad) }
        }
        XCTAssertThrowsError(try PageV2(ParamsV2(["cursor": .string(cursor)]), method: "host.list"), "A cursor belongs to one list") {
            XCTAssertEqual(($0 as? ControlError)?.appCode, "INVALID_CURSOR")
        }
        for limit in [0.0, 501, 2.5] {
            XCTAssertThrowsError(try PageV2(ParamsV2(["limit": .number(limit)]), method: "space.list")) { XCTAssertEqual(($0 as? ControlError)?.code, -32602) }
        }
    }

    func testExpectedRevisionAndIdempotencyKeys() throws {
        XCTAssertNoThrow(try ConventionsV2.checkRevision(expected: nil, current: 4))
        XCTAssertNoThrow(try ConventionsV2.checkRevision(expected: 4, current: 4))
        XCTAssertThrowsError(try ConventionsV2.checkRevision(expected: 3, current: 4)) { error in
            let error = error as? ControlError
            XCTAssertEqual(error?.appCode, "CONFLICT")
            XCTAssertEqual(error?.retryable, false)
            XCTAssertEqual(error?.details, .object(["currentRevision": .number(4)]))
        }
        XCTAssertTrue(ConventionsV2.isValidIdempotencyKey("a"))
        XCTAssertTrue(ConventionsV2.isValidIdempotencyKey(String(repeating: "~", count: 128)))
        for bad in ["", String(repeating: "a", count: 129), "tab\t", "line\n", "é", "\u{7F}"] { XCTAssertFalse(ConventionsV2.isValidIdempotencyKey(bad), bad.debugDescription) }
    }

    func testCapabilitiesMapFromV1WithoutWidening() {
        XCTAssertEqual(CapabilityV2(.metadataRead), .workspaceRead)
        XCTAssertEqual(CapabilityV2(.layoutWrite), .workspaceWrite)
        for capability in Capability.allCases where ![.metadataRead, .layoutWrite].contains(capability) {
            XCTAssertEqual(CapabilityV2(capability).rawValue, capability.rawValue)
        }
        XCTAssertEqual(Set(Capability.allCases.map(CapabilityV2.init)).count, Capability.allCases.count)
        let permissions = (try? page("permissions.md")) ?? ""
        for capability in CapabilityV2.allCases where ![.themeRead, .themeWrite].contains(capability) {
            XCTAssertTrue(permissions.contains("| `\(capability.rawValue)` |"), "\(capability.rawValue) is in the capability table")
        }
    }
}
