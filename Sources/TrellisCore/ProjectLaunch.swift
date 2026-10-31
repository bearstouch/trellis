import Foundation

/// A project resolved for one target and folder (FR-PL06–FR-PL08): its window layout, the commands typed into new
/// panes, what setup must do, and the setup script.
public struct ProjectLaunch: Equatable, Sendable {
    /// One repository checkout at its absolute folder on the target.
    public struct Checkout: Equatable, Sendable {
        public enum State: Equatable, Sendable {
            /// The folder is missing (for the project folder: it has no `.git`), so setup clones or initializes it.
            case clone
            case present
            /// A folder that isn't a checkout; setup never touches it.
            case blocked
        }
        public let repository: ProjectRepository
        /// Relative to the project folder; "" for the project folder itself.
        public let folder: String
        public let path: String
        public var state: State
    }

    public let project: ProjectDefinition
    public let target: ProjectTarget
    /// Absolute on the target.
    public let root: String
    /// As remembered for the target: an absolute path on this Mac, a path relative to home on a host.
    public let folder: String
    public let layout: LayoutDocument
    /// Layout pane key → command.
    public let commands: [String: String]
    public var checkouts: [Checkout]
    public var rootExists = true

    /// Where this launch's window bindings live, so launching the same project, target and folder reconciles its window.
    public var namespace: String { "project:\(project.id.uuidString):\(target.key):\(root)" }
    public var needsSetup: Bool { !rootExists || checkouts.contains { $0.state == .clone } }

    public static func windowKey() -> String { "trellis-window" }

    /// Nil when the folder isn't usable for the target: on this Mac an absolute path (or `~/…`), on a host a path
    /// relative to its home. Either way, nothing the setup script can't quote.
    public static func resolve(_ project: ProjectDefinition, target: ProjectTarget, folder typed: String, home: String) -> ProjectLaunch? {
        let folder = typed.trimmingCharacters(in: .whitespaces)
        let root: String
        switch target {
        case .local:
            guard let expanded = LayoutPlanner.expand(folder, home: home), safe(expanded) else { return nil }
            root = URL(fileURLWithPath: expanded).standardizedFileURL.path
        case .host:
            // The host's home is quoted too, so it must be as safe as a typed folder.
            guard let relative = GitRepository.folder(folder.hasPrefix("~/") ? String(folder.dropFirst(2)) : folder), !relative.isEmpty, safe(home + "/" + relative)
            else { return nil }
            root = home + "/" + relative
        }
        guard root != "/", root != home else { return nil }
        func absolute(_ relative: String) -> String { relative.isEmpty ? root : root + "/" + relative }
        var commands: [String: String] = [:]
        func layoutNode(_ node: ProjectNode, tab: Int, path: [Int], in projectTab: ProjectTab) -> LayoutNode {
            let key = "t\(tab + 1)-" + (path.isEmpty ? "0" : path.map { String($0 + 1) }.joined())
            switch node {
            case .pane(let pane):
                if let command = pane.command { commands[key] = command }
                return .pane(key: key, title: pane.title, launch: .shell(directory: absolute(ProjectDefinition.folder(of: pane, in: projectTab))))
            case .split(let axis, let ratio, let first, let second):
                return .split(
                    key: key, axis: axis, ratio: ratio,
                    children: [layoutNode(first, tab: tab, path: path + [0], in: projectTab), layoutNode(second, tab: tab, path: path + [1], in: projectTab)])
            }
        }
        let tabs = project.tabs.enumerated().map { index, tab in
            LayoutTab(key: "t\(index + 1)", title: tab.title, color: tab.color, root: layoutNode(tab.root, tab: index, path: [], in: tab))
        }
        let checkouts = project.checkouts.map { Checkout(repository: $0.repository, folder: $0.folder, path: absolute($0.folder), state: .present) }
        let remembered = target == .local ? root : String(root.dropFirst(home.count + 1))
        return ProjectLaunch(
            project: project, target: target, root: root, folder: remembered,
            layout: LayoutDocument(windows: [LayoutWindow(key: windowKey(), name: project.name, tabs: tabs)]), commands: commands, checkouts: checkouts)
    }

    /// What setup finds on the target: `exists` and `isDirectory` answer for absolute paths there.
    public mutating func check(exists: (String) -> Bool, isDirectory: (String) -> Bool) {
        rootExists = isDirectory(root)
        for index in checkouts.indices {
            let checkout = checkouts[index]
            let isCheckout = exists(checkout.path + "/.git")
            if checkout.folder.isEmpty {
                checkouts[index].state = isCheckout ? .present : .clone
            } else {
                checkouts[index].state = isCheckout ? .present : exists(checkout.path) ? .blocked : .clone
            }
        }
    }

    /// The setup as one POSIX `sh` line, run from the target's home: create the folder, then clone or initialize each
    /// missing checkout. Each step is skipped when its folder appeared meanwhile, so Retry continues where a failure
    /// stopped. Values are validated to hold no quotes, `$`, backticks, backslashes or `!`, so double quotes are exact.
    public var setupScript: String {
        var lines = ["set -e", "mkdir -p -- \"\(root)\"", "cd -- \"\(root)\""]
        for checkout in checkouts where checkout.state == .clone {
            let url = checkout.repository.url
            if checkout.folder.isEmpty {
                let branch =
                    checkout.repository.branch.map { "git checkout --track \"origin/\($0)\"" }
                    ?? "git remote set-head origin --auto >/dev/null && git checkout --track \"$(git symbolic-ref --short refs/remotes/origin/HEAD)\""
                // `set -e` ignores a failure inside an && list, so it exits explicitly. A failure, or Cancel's hangup, removes
                // the .git this step just made: the folder is as it was, and Retry initializes it again instead of skipping it.
                lines.append(
                    "if [ ! -e .git ]; then echo \"Setting up the project folder from \(url)\"; trap \"rm -rf .git; exit 129\" HUP INT TERM; git init -q && git remote add origin \"\(url)\" && git fetch origin && \(branch) || { failed=$?; rm -rf .git; exit $failed; }; trap - HUP INT TERM; fi"
                )
            } else {
                let branch = checkout.repository.branch.map { "--branch \"\($0)\" " } ?? ""
                lines.append("if [ ! -e \"./\(checkout.folder)\" ]; then git clone \(branch)-- \"\(url)\" \"./\(checkout.folder)\"; fi")
            }
        }
        lines.append("echo \"Project ready.\"")
        return lines.joined(separator: "; ")
    }

    /// `setupScript` as the argument of a login shell's `-c`: it reads the same in sh, bash, zsh, fish and csh, because the
    /// script is one line with no single quotes or `!`.
    public var setupCommand: String { "exec /bin/sh -c '\(setupScript)'" }

    /// An absolute folder the setup script can quote.
    static func safe(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.contains(where: { "\"'\\!$`\n\r".contains($0) }) && !ProjectText.hasHiddenCharacters(path)
    }

    /// The folder offered for a target: the last one used there, else `~/<name>` (lower case, spaces as `-`).
    public static func suggestedFolder(_ project: ProjectDefinition, target: ProjectTarget) -> String {
        if let last = project.lastFolders[target.key] { return last }
        let slug = project.name.lowercased().map { $0.isLetter || $0.isNumber || "-_.".contains($0) ? String($0) : "-" }.joined()
        let name = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-.")).isEmpty ? "project" : slug.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return target == .local ? "~/" + name : name
    }
}
