import Foundation
import TrellisCore

// FR-AG22, FR-AG23: Claude Code's and Codex's subscription usage in the Agents view. Off until turned on in Settings → Agents;
// asked for only while the Agents view is on screen.

extension AppWorkspaceModel {
    public static let claudeUsageAgentID = "trellis-claude-code"
    public static let codexUsageAgentID = "trellis-codex"
    static let agentUsageKeys = [claudeUsageAgentID: "agents.usage.claude", codexUsageAgentID: "agents.usage.codex"]
    static let agentUsageInterval: TimeInterval = 300
    /// The view appearing again soon after, or a poll racing a refresh, doesn't ask twice.
    static let agentUsageMinimumGap: TimeInterval = 60
    /// After a 429 even Refresh waits this long.
    static let agentUsageRateLimitedRetry: TimeInterval = 900

    public func agentUsageEnabled(_ agentID: String) -> Bool {
        guard let key = Self.agentUsageKeys[agentID] else { return false }
        return preferences.object(forKey: key) as? Bool ?? false
    }

    public func setAgentUsageEnabled(_ agentID: String, _ enabled: Bool) {
        guard let key = Self.agentUsageKeys[agentID] else { return }
        objectWillChange.send()
        preferences.set(enabled, forKey: key)
        // A 429's wait outlives the switch, so flipping it can't ask the usage service again early.
        if !enabled { agentUsage[agentID] = nil; agentUsageAskedAt[agentID] = nil }
    }

    public var claudeUsageEnabled: Bool {
        get { agentUsageEnabled(Self.claudeUsageAgentID) }
        set { setAgentUsageEnabled(Self.claudeUsageAgentID, newValue) }
    }

    public var codexUsageEnabled: Bool {
        get { agentUsageEnabled(Self.codexUsageAgentID) }
        set { setAgentUsageEnabled(Self.codexUsageAgentID, newValue) }
    }

    /// The agents whose usage the Agents view shows, in catalog order; empty hides the section.
    public var agentUsageAgents: [AgentDefinition] { agentCatalog.definitions.filter { agentUsageEnabled($0.id) } }

    public var agentUsageRefreshing: Bool { !agentUsageInFlight.isEmpty }

    /// Whether **Open <agent>** on a usage card would open it on this Mac, whose sign-in the card reads.
    var agentUsageCanOpenLocally: Bool {
        guard let pane = presentation.activePane?.id, sidebarUnavailableReason(.agents) == nil else { return false }
        return !isRemoteWorkspace(paneID: pane)
    }

    /// Asks every opted-in agent whose last ask is over a minute old; `force` (Refresh) skips that wait, but not a 429's.
    public func refreshAgentUsage(force: Bool = false) async {
        let now = activityNow()
        let due = agentUsageAgents.map(\.id).filter { id in
            guard !agentUsageInFlight.contains(id) else { return false }
            if let retry = agentUsageRetryAt[id], now < retry { return false }
            if !force, let asked = agentUsageAskedAt[id], now.timeIntervalSince(asked) < Self.agentUsageMinimumGap { return false }
            return true
        }
        // Each read is the model's own task, not the caller's: closing the view or turning another agent on cancels the
        // view's poll, and a read cut off there would show a failure that never happened.
        let reads = due.map { id in Task { await self.readAgentUsage(id) } }
        for read in reads { await read.value }
    }

    /// Runs while the Agents view is open in the sidebar: a refresh now, then every five minutes.
    public func pollAgentUsage() async {
        while !Task.isCancelled, !agentUsageAgents.isEmpty {
            await refreshAgentUsage()
            await activitySleep(Self.agentUsageInterval)
        }
    }

    private func readAgentUsage(_ id: String) async {
        agentUsageInFlight.insert(id); objectWillChange.send()
        defer { agentUsageInFlight.remove(id); objectWillChange.send() }
        agentUsageAskedAt[id] = activityNow()
        let last = agentUsage[id]?.snapshot
        agentUsage[id] = .loading(last: last)
        let status = id == Self.claudeUsageAgentID ? await claudeUsageStatus(last: last) : await codexUsageStatus(last: last)
        agentUsageRetryAt[id] = status == .unavailable(.rateLimited, last: last) ? activityNow().addingTimeInterval(Self.agentUsageRateLimitedRetry) : nil
        // Turned off while it was asking.
        guard agentUsageEnabled(id) else { agentUsage[id] = nil; return }
        agentUsage[id] = status
    }

    private func claudeUsageStatus(last: AgentUsageSnapshot?) async -> AgentUsageStatus {
        guard let credential = await agentUsageClient.claudeCredential() else { return .unavailable(.notSignedIn, last: last) }
        // Trellis never renews Claude Code's sign-in: renewing rotates it and could sign Claude Code out.
        guard !credential.isExpired(at: activityNow()) else { return .unavailable(.signInExpired, last: last) }
        switch await agentUsageClient.claudeUsage(credential.accessToken) {
        case .ok(let data):
            guard let snapshot = ClaudeUsage.parse(data, plan: credential.plan, now: activityNow()) else { return .unavailable(.failed, last: last) }
            return snapshot.windows.isEmpty ? .unavailable(.noPlanLimits, last: nil) : .ready(snapshot)
        case .status(401), .status(403): return .unavailable(.signInExpired, last: last)
        case .status(429): return .unavailable(.rateLimited, last: last)
        case .status, .failed: return .unavailable(.failed, last: last)
        }
    }

    private func codexUsageStatus(last: AgentUsageSnapshot?) async -> AgentUsageStatus {
        guard let definition = agentCatalog.definitions.first(where: { $0.id == Self.codexUsageAgentID }) else { return .unavailable(.notInstalled, last: nil) }
        let executable: String?
        switch agentAvailability[definition.id] {
        case .installed(let path)?: executable = path
        case .missing?: executable = nil
        case .checking?, nil:
            // The Agents view's own PATH check may be running: wait for it rather than start a second login shell.
            if let probe = agentPathProbe { await probe.value }
            if case .installed(let path)? = agentAvailability[definition.id] {
                executable = path
                break
            }
            if agentLoginPath == nil {
                let shell = defaultShell
                agentLoginPath = await Task.detached { AgentPathProbe.loginPath(shell: shell) }.value
            }
            executable = AgentPathProbe.resolve(definition.executable, path: agentLoginPath)
        }
        guard let executable else { return .unavailable(.notInstalled, last: last) }
        switch await agentUsageClient.codexRateLimits(executable, agentLoginPath) {
        case .reply(.result(let data)):
            guard let snapshot = CodexUsage.parse(data, now: activityNow()) else { return .unavailable(.failed, last: last) }
            return snapshot.windows.isEmpty ? .unavailable(.noPlanLimits, last: nil) : .ready(snapshot)
        case .reply(.error(let message)):
            let lower = message.lowercased()
            let signedOut = ["auth", "login", "logged", "sign in", "signed in"].contains { lower.contains($0) }
            return .unavailable(signedOut ? .notSignedIn : .failed, last: last)
        case .failed: return .unavailable(.failed, last: last)
        }
    }
}
