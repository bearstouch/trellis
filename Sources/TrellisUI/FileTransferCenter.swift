import Foundation
import TrellisCore

/// The copies the Files view runs (FR-FB10–FR-FB13): each one's progress for the bar, and the name conflicts they wait on,
/// asked one at a time. Published apart from the Files state, so a progress tick redraws the bar alone.
@MainActor public final class FileTransferCenter: ObservableObject {
    public struct Run: Identifiable, Equatable {
        public let id: UUID
        public let title: String
        /// Toward a host, rather than toward this Mac.
        public let upload: Bool
        public internal(set) var progress = FileTransferProgress()
    }

    public struct Prompt: Identifiable, Equatable {
        public let id: UUID
        public let runID: UUID
        public let conflict: FileTransferConflict
    }

    @Published public private(set) var runs: [Run] = []
    /// The conflict shown now; others wait behind it.
    @Published public private(set) var prompt: Prompt?
    private var waiting: [(Prompt, CheckedContinuation<FileTransferDecision?, Never>)] = []
    private var tasks: [UUID: Task<FileTransferReport, Never>] = [:]

    public init() {}

    /// Runs `operation` with a resolver and a progress reporter bound to a new run, and removes the run when it ends.
    @discardableResult
    func start(title: String, upload: Bool, _ operation: @escaping @Sendable (@escaping FileTransferRun.Resolve, @escaping FileTransferRun.Report) async -> FileTransferReport)
        -> Task<FileTransferReport, Never>
    {
        let id = UUID()
        runs.append(Run(id: id, title: title, upload: upload))
        let resolve: FileTransferRun.Resolve = { [weak self] conflict in await self?.ask(conflict, runID: id) ?? nil }
        let report: FileTransferRun.Report = { [weak self] progress in Task { @MainActor in self?.update(id, progress) } }
        let task = Task { [weak self] in
            let result = await operation(resolve, report)
            self?.finish(id)
            return result
        }
        tasks[id] = task
        return task
    }

    private func update(_ id: UUID, _ progress: FileTransferProgress) {
        guard let index = runs.firstIndex(where: { $0.id == id }) else { return }
        runs[index].progress = progress
    }

    private func finish(_ id: UUID) {
        runs.removeAll { $0.id == id }
        tasks[id] = nil
        answerAll(of: id, with: nil)
    }

    private func ask(_ conflict: FileTransferConflict, runID: UUID) async -> FileTransferDecision? {
        guard tasks[runID]?.isCancelled == false else { return nil }
        return await withCheckedContinuation { continuation in
            waiting.append((Prompt(id: UUID(), runID: runID, conflict: conflict), continuation))
            if prompt == nil { prompt = waiting.first?.0 }
        }
    }

    /// The answer to the conflict shown (or to `promptID`, ignored once that one is answered); nil stops that copy.
    public func answer(_ decision: FileTransferDecision?, to promptID: UUID? = nil) {
        guard let shown = prompt, promptID == nil || promptID == shown.id, let index = waiting.firstIndex(where: { $0.0.id == shown.id }) else { return }
        let (_, continuation) = waiting.remove(at: index)
        prompt = waiting.first?.0
        continuation.resume(returning: decision)
    }

    private func answerAll(of runID: UUID, with decision: FileTransferDecision?) {
        let ended = waiting.filter { $0.0.runID == runID }
        waiting.removeAll { $0.0.runID == runID }
        if let shown = prompt, shown.runID == runID { prompt = waiting.first?.0 }
        for (_, continuation) in ended { continuation.resume(returning: decision) }
    }

    /// Stops a copy after its current chunk; what was finished stays.
    public func cancel(_ id: UUID) {
        tasks[id]?.cancel()
        answerAll(of: id, with: nil)
    }

    /// Waits for every copy; for tests.
    public func waitForAll() async { for task in Array(tasks.values) { _ = await task.value } }
}
