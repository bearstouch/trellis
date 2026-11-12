import Foundation
import TrellisControl
import TrellisCore

/// `layout.*` (docs/api/layouts.md) and `theme.*`/`appearance.*` (methods.md#layouts-themes-and-appearance). Layouts are
/// planned by `LayoutPlanner` against the bindings in `layout-bindings.json`; namespaces follow the key pattern, so a
/// layout never reads or writes a project launch's `project:…` bindings.
extension AutomationServiceV2 {
    @MainActor func performLayouts(_ call: CallV2) async throws -> JSONValue {
        let p = call.params
        switch call.spec.name {
        case "layout.validate":
            let raw = p["document"]
            let document: LayoutDocument
            switch LayoutJSON.parse(raw) {
            case .success(let parsed): document = parsed
            case .failure(let error) where error.unsupportedVersion: throw Self.unsupportedLayout(error)
            case .failure(let error):
                return .object(["valid": .bool(false), "errors": LayoutJSON.issuesJSON(error.issues), "warnings": .array([]), "version": .number(3)])
            }
            let result = try plan(document, namespace: nil, call)
            var object: [String: JSONValue] = [
                "valid": .bool(result.errors.isEmpty), "errors": LayoutJSON.issuesJSON(result.errors), "warnings": LayoutJSON.issuesJSON(result.warnings),
                "version": ConventionsV2.number(LayoutJSON.currentVersion)
            ]
            if let version = LayoutJSON.declaredVersion(raw), version < LayoutJSON.currentVersion { object["upgradedFrom"] = ConventionsV2.number(version) }
            return .object(object)
        case "layout.plan":
            let result = try plan(try parsed(p), namespace: try namespace(p), call)
            return planJSON(result, call)
        case "layout.apply": return try await apply(call)
        case "layout.export": return try export(call)
        default: throw ControlError.methodNotFound
        }
    }

    // MARK: Layouts

    private static func unsupportedLayout(_ error: LayoutParseError) -> ControlError {
        .api(.unsupportedVersion, error.text, details: .object(["supported": .array(LayoutJSON.supportedVersions.map { ConventionsV2.number($0) })]))
    }

    @MainActor private func parsed(_ p: ParamsV2) throws -> LayoutDocument {
        switch LayoutJSON.parse(p["document"]) {
        case .success(let document): return document
        case .failure(let error) where error.unsupportedVersion: throw Self.unsupportedLayout(error)
        case .failure(let error): throw ControlError.invalidParams("The layout document is invalid.", fields: ["document": "a valid layout document"]).withIssues(error.issues)
        }
    }

    @MainActor private func namespace(_ p: ParamsV2) throws -> String {
        let namespace = try p.string("namespace")
        guard LayoutPlanner.isValidKey(namespace) else { throw ControlError.invalidParams("namespace must match the layout key pattern.", fields: ["namespace": "layout key"]) }
        return namespace
    }

    /// Hosts and projects outside the grant look exactly like missing ones, and bindings to spaces outside it are ignored,
    /// so a plan never reveals hidden resources. Agents outside the agent scope are errors; unknown ones only warnings.
    @MainActor private func plan(_ document: LayoutDocument, namespace: String?, _ call: CallV2) throws -> LayoutPlan {
        let access = call.access
        var bindings: [String: LayoutBinding] = [:]
        if let namespace {
            do { bindings = try model.layoutBindings(namespace) } catch { throw Self.map(error) }
            let kinds: [LayoutResourceKind: ResourceKind] = [.space: .space, .tab: .tab, .split: .branch, .pane: .pane]
            bindings = bindings.filter { _, binding in kinds[binding.kind].flatMap { access.owningSpace($0, binding.id) }.map(access.canSee) == true }
        }
        var result = LayoutPlanner.plan(
            document, bindings: bindings, snapshot: model.snapshot, home: FileManager.default.homeDirectoryForCurrentUser.path,
            hostExists: { id in access.hostAccess(self.hosts.hosts.first { $0.id == id }) == .allowed },
            directoryExists: { path in
                var isDirectory: ObjCBool = false; return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
            })
        let library = projects.flatMap { $0.isLoaded ? Set($0.projects.map(\.id)) : nil }
        for space in document.spaces {
            if let project = space.projectID, !access.reaches(project: project) || library.map({ !$0.contains(project) }) ?? false {
                result.errors.append(LayoutIssue(key: space.key, "Project \(ConventionsV2.id(project)) does not exist."))
            }
            for (key, launch) in space.tabs.flatMap({ LayoutPlanner.launches($0.root) }) {
                guard case .agent(let agentID, _) = launch else { continue }
                if !access.canUse(agent: agentID) {
                    result.errors.append(LayoutIssue(key: key, "The agent \(agentID) is outside this grant's agent scope."))
                } else if model.agentCatalog.definition(agentID) == nil {
                    result.warnings.append(LayoutIssue(key: key, "The agent \(agentID) isn't in the agent catalog; its pane says so when it starts."))
                }
            }
        }
        return result
    }

    @MainActor private func planJSON(_ result: LayoutPlan, _ call: CallV2) -> JSONValue {
        let access = call.access
        let unmanaged = result.unmanaged.filter { id in
            access.owningSpace(.space, id).map(access.canSee) ?? access.owningSpace(.tab, id).map(access.canSee) ?? false
        }
        return .object([
            "baseRevision": ConventionsV2.number(result.baseRevision), "applicable": .bool(result.canApply), "errors": LayoutJSON.issuesJSON(result.errors),
            "warnings": LayoutJSON.issuesJSON(result.warnings), "conflicts": LayoutJSON.issuesJSON(result.conflicts),
            "creates": Self.keyed(result.creates), "updates": Self.keyed(result.updates), "unmanaged": .array(unmanaged.map(ConventionsV2.idJSON))
        ])
    }

    private static func keyed(_ items: [(kind: LayoutResourceKind, key: String)]) -> JSONValue {
        .array(items.map { .object(["kind": .string($0.kind.rawValue), "key": .string($0.key)]) })
    }

    /// What the document's contents need beyond the declaration's capabilities: a remote machine remote.connect, a project
    /// project.launch, an agent pane agent.control (layouts.md).
    @MainActor private func requireDocumentAccess(_ document: LayoutDocument, _ call: CallV2) throws {
        var missing: Set<CapabilityV2> = []
        let launches = document.spaces.flatMap { $0.tabs.flatMap { LayoutPlanner.launches($0.root) } }
        if document.spaces.contains(where: { $0.remoteHostID != nil }), !call.grant.holds(.remoteConnect) { missing.insert(.remoteConnect) }
        if document.spaces.contains(where: { $0.projectID != nil }), !call.grant.holds(.projectLaunch) { missing.insert(.projectLaunch) }
        if launches.contains(where: { if case .agent = $0.launch { true } else { false } }), !call.grant.holds(.agentControl) { missing.insert(.agentControl) }
        guard missing.isEmpty else {
            throw ControlError.api(
                .permissionDenied, "This layout binds a remote machine or a project, or has agent panes, which this grant doesn't allow.",
                details: .object(["missing": .array(missing.sorted().map { .string($0.rawValue) })]))
        }
    }

    @MainActor private func apply(_ call: CallV2) async throws -> JSONValue {
        let p = call.params
        let document = try parsed(p), namespace = try namespace(p)
        guard let expected = p.expectedRevision else {
            throw ControlError.invalidParams("layout.apply needs expectedRevision: the baseRevision layout.plan returned.", fields: ["expectedRevision": "plan baseRevision"])
        }
        try requireDocumentAccess(document, call)
        let startNew = try p.optionalBool("startNew") == true
        var result = try plan(document, namespace: namespace, call)
        guard result.errors.isEmpty else { throw ControlError.invalidParams("The layout document is invalid.", fields: ["document": "a valid layout document"]).withIssues(result.errors) }
        guard result.canApply else {
            throw ControlError.api(.conflict, "The layout conflicts with the current workspace.", details: .object(["conflicts": LayoutJSON.issuesJSON(result.conflicts)]))
        }
        guard result.baseRevision == expected else {
            throw ControlError.api(
                .conflict, "The workspace changed since the plan. Plan again and apply with the new baseRevision.",
                details: .object(["expectedRevision": ConventionsV2.number(expected), "currentRevision": ConventionsV2.number(result.baseRevision)]))
        }
        if startNew {
            // Everything a start needs is checked, and a host connected, before anything is created.
            let launches = result.createdPanes.compactMap { pane in result.target?.panes[pane.id].flatMap { result.target?.sessions[$0.sessionID]?.launch } }
            for launch in launches { try requireLaunchAccess(launch, call) }
            for host in Set(launches.compactMap(\.remoteHostID)).sorted(by: { $0.uuidString < $1.uuidString }) {
                if launches.contains(where: { $0.agent?.hostID == host }) { try await readyAgentHost(host, call) } else { try await readyRemoteLink(host, call) }
            }
            // Connecting re-attaches the host's panes, which moves the workspace revision on; the document is planned again
            // against the workspace as it now is, and the store applies that plan atomically with its revision.
            result = try plan(document, namespace: namespace, call)
            guard result.errors.isEmpty, result.canApply else { throw ControlError.api(.conflict, "The workspace changed while connecting. Plan again and retry.") }
        }
        let committed: WorkspaceCommandResult
        do { committed = try await model.automationApplyLayout(result, namespace: namespace) } catch { throw Self.map(error) }
        // Starts are independent of the committed layout: a failure is reported, never rolled back or retried.
        var launches: [JSONValue] = []
        if startNew {
            for (key, paneID) in result.createdPanes {
                var failure: ControlError?
                do { try await model.automationStartSession(paneID, launch: nil, environment: [:]) } catch { failure = Self.map(error) }
                var object = ResultObjectV2()
                object.set("key", key)
                object.set("paneId", paneID)
                await model.waitForUpdates()
                if let sessionID = model.snapshot.panes[paneID]?.sessionID { object.set("session", try? session(call, sessionID)) }
                if let failure { object.set("error", JSONValue.object(["code": .string(failure.appCode ?? "INTERNAL_ERROR"), "message": .string(failure.message)])) }
                launches.append(object.json)
            }
        }
        return .object([
            "workspaceRevision": ConventionsV2.number(model.snapshot.revision), "changed": .bool(committed.snapshot.revision != result.baseRevision),
            "mapping": .object(result.bindings.mapValues { .object(["kind": .string($0.kind.rawValue), "id": ConventionsV2.idJSON($0.id)]) }),
            "creates": Self.keyed(result.creates), "launches": .array(launches)
        ])
    }

    /// Spaces in scope as a version 3 document with fresh keys. Directories and agents need session.execute, a remote
    /// machine and ssh hosts host.read (and the host in scope), a project project.read; anything withheld marks the
    /// document redacted, so it can't be imported as if it were whole.
    @MainActor private func export(_ call: CallV2) throws -> JSONValue {
        let access = call.access
        let requested = call.params.sent("spaceIds") ? Set(try call.params.uuids("spaceIds")) : nil
        let snapshot = model.snapshot
        var counter = 0, redacted = false
        func key(_ prefix: String) -> JSONValue {
            counter += 1
            return .string("\(prefix)\(counter)")
        }
        func host(_ id: UUID) -> Bool { access.allows(.hostRead) && access.hostAccess(hosts.hosts.first { $0.id == id }) == .allowed }
        func shell(_ directory: String?) -> JSONValue {
            guard let directory, access.allows(.sessionExecute) else {
                if directory != nil { redacted = true }
                return .object(["kind": .string("shell")])
            }
            return .object(["kind": .string("shell"), "directory": .string(directory)])
        }
        func pane(_ id: UUID) -> [String: JSONValue] {
            switch snapshot.panes[id].flatMap({ snapshot.sessions[$0.sessionID] })?.launch {
            case .host(let hostID)? where host(hostID): return ["launch": .object(["kind": .string("ssh"), "hostId": ConventionsV2.idJSON(hostID)])]
            case .shell(let directory)?, .remoteShell(_, let directory)?: return ["launch": shell(directory)]
            case .process(_, let arguments, let directory)? where arguments == ["-l"]: return ["launch": shell(directory)]
            case .agent(let agent)? where access.allows(.sessionExecute): return ["launch": shell(agent.directory), "agent": .string(agent.agentID)]
            default:
                redacted = true
                return ["launch": .object(["kind": .string("shell")])]
            }
        }
        func node(_ layout: PaneLayout) -> JSONValue {
            switch layout {
            case .pane(let id):
                var object = pane(id)
                object["type"] = .string("pane"); object["key"] = key("p")
                if let title = snapshot.panes[id]?.title { object["title"] = .string(title) }
                return .object(object)
            case .split(_, let axis, let ratio, let children):
                return .object(["type": .string("split"), "key": key("s"), "axis": .string(axis.rawValue), "ratio": .number(ratio), "children": .array(children.map(node))])
            }
        }
        let spaces = snapshot.spaces.filter { access.canSee(space: $0.id) && (requested?.contains($0.id) ?? true) }
        if let requested, requested.count != spaces.count { throw Self.notFound }
        let exported: [JSONValue] = spaces.map { space in
            var object: [String: JSONValue] = ["key": key("sp"), "name": .string(space.name)]
            if let hostID = space.remoteHostID {
                if host(hostID) { object["machine"] = .object(["kind": .string("remote"), "hostId": ConventionsV2.idJSON(hostID)]) } else { redacted = true }
            }
            if let project = space.projectID {
                if access.allows(.projectRead), access.reaches(project: project) { object["projectId"] = ConventionsV2.idJSON(project) } else { redacted = true }
            }
            object["tabs"] = .array(
                space.tabIDs.compactMap { snapshot.tabs[$0] }.map { tab in .object(["key": key("t"), "title": .string(model.displayTitle(tab)), "root": node(tab.root)]) })
            return .object(object)
        }
        let document: JSONValue = .object(["version": ConventionsV2.number(LayoutJSON.currentVersion), "spaces": .array(exported)])
        return .object(["document": document, "redacted": .bool(redacted), "importable": .bool(!redacted)])
    }

    // MARK: Themes and appearance

    @MainActor func performThemes(_ call: CallV2) async throws -> JSONValue {
        let p = call.params
        switch call.spec.name {
        case "theme.list":
            let page = try PageV2(p, method: call.spec.name).slice(model.allThemes)
            var object: [String: JSONValue] = ["themes": .array(page.items.map(themeSummary)), "appearanceRevision": ConventionsV2.number(model.appearanceRevision)]
            if let next = page.nextCursor { object["nextCursor"] = .string(next) }
            return .object(object)
        case "theme.get":
            let id = try p.string("id")
            guard let theme = model.allThemes.first(where: { $0.id == id }), let data = try? theme.encoded(), let palette = try? JSONDecoder().decode(JSONValue.self, from: data)
            else { throw Self.themeNotFound }
            var summary: [String: JSONValue] = [:]
            if case .object(let object) = themeSummary(theme) { summary = object }
            summary["resolved"] = palette
            summary["contrastWarnings"] = .array(theme.contrastWarnings.map { .string($0.message) })
            return .object(summary)
        case "theme.validate":
            do {
                let document = try ThemeValidator.validate(try themeData(p))
                return .object([
                    "valid": .bool(true), "id": .string(document.id), "appearance": .string(document.appearance.rawValue), "errors": .array([]),
                    "warnings": .array(document.resolved().contrastWarnings.map { .string($0.message) })
                ])
            } catch let error as ThemeValidationError {
                if error.code == .unsupportedVersion { throw ControlError.api(.unsupportedVersion, error.reason, details: .object(["supported": .array([.number(1)])])) }
                return .object(["valid": .bool(false), "errors": .array([.object(["path": .string(error.path), "message": .string(error.reason)])]), "warnings": .array([])])
            }
        case "theme.import":
            let document: ThemeDocument
            do { document = try await model.automationInstallTheme(try themeData(p), replace: try p.optionalBool("replace") == true) } catch let error as AutomationThemeError {
                throw Self.map(error)
            }
            guard let theme = model.allThemes.first(where: { $0.id == document.id }) else { throw ControlError.internalError }
            return .object(["theme": themeSummary(theme)])
        case "theme.export":
            let id = try p.string("id"), resolved = try p.optionalBool("resolved") == true
            let data: Data
            if let builtIn = ThemeAppearance.allCases.map(ResolvedTheme.builtIn).first(where: { $0.id == id }) {
                guard let encoded = try? builtIn.encoded() else { throw ControlError.internalError }
                data = encoded
            } else {
                do { data = try await model.exportTheme(id, resolved: resolved) } catch { throw Self.themeNotFound }
            }
            guard let document = try? JSONDecoder().decode(JSONValue.self, from: data) else { throw ControlError.internalError }
            return .object(["id": .string(id), "resolved": .bool(resolved), "document": document])
        case "theme.delete":
            let id = try p.string("id")
            do { try await model.automationDeleteTheme(id) } catch { throw Self.map(error) }
            return .object(["deleted": .object(["kind": .string("theme"), "id": .string(id)])])
        case "appearance.get": return appearance()
        case "appearance.set":
            var mode: ChromeMode?
            if let raw = try p.optionalString("mode") { mode = ChromeMode(rawValue: raw) }
            let light = try p.optionalString("lightThemeId"), dark = try p.optionalString("darkThemeId")
            // The dispatcher compared expectedRevision; the model compares it again atomically with the change.
            do { try model.automationSetAppearance(mode: mode, lightThemeID: light, darkThemeID: dark, expectedRevision: p.expectedRevision) } catch { throw Self.map(error) }
            return appearance()
        default: throw ControlError.methodNotFound
        }
    }

    private static let themeNotFound = ControlError.api(.notFound, "No theme has that ID.")

    @MainActor private func themeSummary(_ theme: ResolvedTheme) -> JSONValue {
        var slots: [JSONValue] = []
        if model.appearance.lightThemeID == theme.id { slots.append(.string("light")) }
        if model.appearance.darkThemeID == theme.id { slots.append(.string("dark")) }
        return .object([
            "id": .string(theme.id), "name": .string(theme.name), "appearance": .string(theme.appearance.rawValue), "builtIn": .bool(theme.id.hasPrefix("trellis-")),
            "selectedFor": .array(slots)
        ])
    }

    /// Theme documents are checked by the same validator the UI uses; raw text keeps its duplicate-key checks exact.
    @MainActor private func themeData(_ p: ParamsV2) throws -> Data {
        if let text = try p.optionalString("documentText") { return Data(text.utf8) }
        guard let document = p["document"], let data = try? JSONEncoder().encode(document) else {
            throw ControlError.invalidParams("Send document or documentText.", fields: ["document": "theme object"])
        }
        return data
    }

    @MainActor private func appearance() -> JSONValue {
        let settings = model.appearance, stats = model.renderingStats
        return .object([
            "mode": .string(settings.chromeMode.rawValue), "lightThemeId": .string(settings.lightThemeID), "darkThemeId": .string(settings.darkThemeID),
            "effectiveThemeId": .string(model.effectiveTheme.id), "revision": ConventionsV2.number(model.appearanceRevision),
            // FR-TX05: the GPU setting and which renderer each pane is actually using.
            "rendering": .object([
                "gpuRendering": .bool(model.terminalAppearance.gpuRendering), "metalPanes": ConventionsV2.number(stats.metalPanes),
                "coreGraphicsPanes": ConventionsV2.number(stats.coreGraphicsPanes), "metalFrames": ConventionsV2.number(stats.metalFrames),
                "coreGraphicsFrames": ConventionsV2.number(stats.coreGraphicsFrames)
            ]),
            // FR-TH10: the saved setting and what panes show after Reduce Transparency / Increase Contrast.
            "backgroundOpacity": .number(settings.backgroundOpacity), "backgroundBlur": .bool(settings.backgroundBlur),
            "effectiveBackgroundOpacity": .number(model.effectiveBackgroundOpacity)
        ])
    }

    static func map(_ error: AutomationThemeError) -> ControlError {
        switch error {
        case .invalid(let validation) where validation.code == .unsupportedVersion:
            .api(.unsupportedVersion, validation.reason, details: .object(["supported": .array([.number(1)])]))
        case .invalid(let validation): .invalidParams("The theme is invalid: \(validation.reason)", fields: [validation.path: validation.reason])
        case .library(.reservedID): invalidState("Built-in trellis- themes cannot be replaced or deleted.", state: "builtIn")
        case .library(.duplicateID): .api(.conflict, "A theme with this ID exists. Repeat with replace: true to replace it.")
        case .library(.notFound), .notFound: themeNotFound
        case .library: invalidState("The theme library could not be updated.", retryable: true)
        case .unavailable: invalidState("Themes are busy or the app is restoring. Retry shortly.", state: "busy", retryable: true)
        case .mismatchedSlot(let message): .invalidParams(message, fields: ["themeId": "a theme for that light or dark slot"])
        case .conflict(_, let actual):
            .api(.conflict, "Appearance changed. Read it again and retry with its current revision.", details: .object(["currentRevision": ConventionsV2.number(actual)]))
        }
    }
}
