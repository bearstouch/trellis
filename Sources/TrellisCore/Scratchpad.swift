import Foundation

/// A language the command scratchpad can highlight, check and run (FR-SP03). The selector lists `all`, so another
/// language is one more entry here.
public struct ScratchpadLanguage: Hashable, Identifiable, Sendable {
    public enum Grammar: Sendable { case shell, javascript, markdown }

    public let id: String
    public let displayName: String
    public let fileExtension: String
    /// The program Run types; the pane's shell finds it on its own PATH. Nil for text that is never run, like Markdown.
    public let interpreter: String?
    /// Placed before the file to check its syntax without running it.
    public let checkArguments: [String]
    public let grammar: Grammar

    public static let sh = ScratchpadLanguage(id: "sh", displayName: "sh", fileExtension: "sh", interpreter: "sh", checkArguments: ["-n"], grammar: .shell)
    public static let bash = ScratchpadLanguage(id: "bash", displayName: "bash", fileExtension: "sh", interpreter: "bash", checkArguments: ["-n"], grammar: .shell)
    public static let javascript = ScratchpadLanguage(
        id: "javascript", displayName: "JavaScript", fileExtension: "js", interpreter: "node", checkArguments: ["--check"], grammar: .javascript)
    public static let markdown = ScratchpadLanguage(id: "markdown", displayName: "Markdown", fileExtension: "md", interpreter: nil, checkArguments: [], grammar: .markdown)
    public static let all: [ScratchpadLanguage] = [.sh, .bash, .javascript, .markdown]

    /// Can be checked, run and saved as a task.
    public var isRunnable: Bool { interpreter != nil }

    /// The language of a saved script: by extension, and for `.sh` by its `#!` line (`sh` only when it names sh).
    public static func detect(fileName: String, text: String) -> ScratchpadLanguage? {
        let ext = (fileName as NSString).pathExtension
        let candidates = all.filter { $0.fileExtension == ext }
        guard candidates.count > 1 else { return candidates.first }
        let shebang = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        guard shebang.hasPrefix("#!") else { return candidates.first { $0 == .bash } ?? candidates.first }
        let words = shebang.dropFirst(2).split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        let program = words.first == "/usr/bin/env" ? words.dropFirst().first { !$0.hasPrefix("-") } : words.first
        let name = program.map { ($0 as NSString).lastPathComponent }
        return candidates.first { $0.interpreter == name } ?? candidates.first { $0 == .bash } ?? candidates.first
    }

    /// What the syntax check runs, as shown to the user.
    public var checkDescription: String? { interpreter.map { ([$0] + checkArguments).joined(separator: " ") } }
}

/// The scratchpad's buffer. It lives in memory; only Run and Save write it to a file (FR-SP07).
public struct ScratchpadDocument: Equatable, Sendable {
    public static let maximumBytes = 65_536
    public static let maximumNameLength = 64
    public static let defaultName = "untitled"
    /// Saved scripts live here, relative to the project folder, so tasks can name them.
    public static let projectDirectory = ProjectFile.directoryName + "/scratch"

    public var name: String
    public var language: ScratchpadLanguage
    public var text: String
    public init(name: String = Self.defaultName, language: ScratchpadLanguage = .bash, text: String = "") {
        self.name = name; self.language = language; self.text = text
    }

    public var fileName: String { name + "." + language.fileExtension }
    public var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The command a saved task runs from the project folder. The name needs no quoting (see `nameProblem`).
    public var taskCommand: String? { language.interpreter.map { $0 + " " + Self.projectDirectory + "/" + fileName } }

    /// The line Run types for a script written to `path`.
    public func runLine(path: String, kind: ShellIntegrationKind) -> String? {
        guard let interpreter = language.interpreter else { return nil }
        let line = interpreter + " " + TaskCommand.shellQuote(path, kind: kind)
        return ProjectFile.commandProblem(line) == nil ? line : nil
    }

    /// Saved scripts the scratchpad can open: names it could have written, with a registered extension.
    public static func isScriptFileName(_ fileName: String) -> Bool {
        let name = fileName as NSString
        return nameProblem(name.deletingPathExtension) == nil && ScratchpadLanguage.all.contains { $0.fileExtension == name.pathExtension }
    }

    /// A file name for a task name: lower case, other characters as single dashes, e.g. "Deploy preview!" → "deploy-preview".
    public static func suggestedName(for taskName: String) -> String {
        var name = ""
        for scalar in taskName.lowercased().unicodeScalars {
            let kept = scalar.isASCII && (scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) || scalar == "_" || scalar == ".")
            if kept { name.unicodeScalars.append(scalar) } else if !name.isEmpty, !name.hasSuffix("-") { name += "-" }
        }
        name = String(name.prefix(maximumNameLength)).trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return nameProblem(name) == nil ? name : "script"
    }

    /// The name becomes a file name and part of a typed command, so it is limited to characters that need no quoting.
    public static func nameProblem(_ name: String) -> String? {
        let allowed = name.unicodeScalars.allSatisfy { $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || "._-".unicodeScalars.contains($0)) }
        guard (1...maximumNameLength).contains(name.count), allowed, let first = name.first, first != ".", first != "-" else {
            return "The name needs 1–\(maximumNameLength) letters, digits, “.”, “-” or “_”, and can't start with “.” or “-”."
        }
        return nil
    }

    /// Problems found without running anything: an empty or oversized buffer, a bad name, or characters that would make
    /// what is shown differ from what runs.
    public var issues: [ScratchpadIssue] {
        var issues: [ScratchpadIssue] = []
        if let problem = Self.nameProblem(name) { issues.append(ScratchpadIssue(line: nil, problem)) }
        if isEmpty { issues.append(ScratchpadIssue(line: nil, "Write a command or script first.")) }
        if text.utf8.count > Self.maximumBytes { issues.append(ScratchpadIssue(line: nil, "The script is larger than 64 KB.")) }
        // Text that never runs may hold anything that renders, like emoji joined with zero-width joiners.
        guard language.isRunnable else { return issues }
        var line = 1, flagged = false
        for scalar in text.unicodeScalars {
            if scalar == "\n" { line += 1; flagged = false; continue }
            guard !flagged, scalar != "\t" else { continue }
            let hidden =
                [.format, .control, .lineSeparator, .paragraphSeparator].contains(scalar.properties.generalCategory) || scalar.properties.isDefaultIgnorableCodePoint
            if hidden {
                flagged = true
                issues.append(ScratchpadIssue(line: line, scalar == "\r" ? "Use Unix line endings; this line ends with a carriage return." : "Remove the control or invisible formatting character."))
                if issues.count >= ScratchpadValidator.maximumIssues { break }
            }
        }
        return issues
    }
}

public struct ScratchpadIssue: Equatable, Sendable {
    /// One-based; nil when the problem isn't on one line.
    public let line: Int?
    public let message: String
    public init(line: Int?, _ message: String) { self.line = line; self.message = message }
}

public struct ScratchpadCheck: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case passed
        case failed
        /// The interpreter wasn't found or couldn't start; Run is still allowed.
        case notChecked
    }
    public let outcome: Outcome
    public let issues: [ScratchpadIssue]
    /// What ran, such as `bash -n`; nil when only the static checks ran.
    public let checker: String?
    public init(_ outcome: Outcome, issues: [ScratchpadIssue] = [], checker: String? = nil) { self.outcome = outcome; self.issues = issues; self.checker = checker }
}

public struct ScratchpadProcessResult: Equatable, Sendable {
    public let status: Int32
    public let output: String
    public init(status: Int32, output: String) { self.status = status; self.output = output }
}

public struct ScratchpadCheckTimedOut: Error {}

/// Runs `executable` with `arguments`, killing it after `timeout`; injected by tests.
public typealias ScratchpadProcessRunner = @Sendable (_ executable: String, _ arguments: [String], _ timeout: TimeInterval) async throws -> ScratchpadProcessResult

/// Checks a buffer's syntax with its interpreter (FR-SP04), without running it.
public enum ScratchpadValidator {
    public static let timeout: TimeInterval = 5
    public static let maximumIssues = 20
    static let maximumOutput = 16_384

    /// Folders searched for an interpreter: the app's PATH, then the usual Homebrew and system folders, since an app
    /// started from the Finder gets a short PATH.
    public static func searchPath(environment: [String: String]) -> [String] {
        var seen = Set<String>()
        let folders = (environment["PATH"] ?? "").split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        return folders.filter { $0.hasPrefix("/") && seen.insert($0).inserted }
    }

    public static func resolve(_ interpreter: String, searchPath: [String], isExecutable: (String) -> Bool) -> String? {
        searchPath.lazy.map { $0 + "/" + interpreter }.first(where: isExecutable)
    }

    /// Writes the buffer to a private file in `directory`, runs the language's check on it and removes it again.
    public static func check(
        _ document: ScratchpadDocument, directory: URL, searchPath: [String], isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        run: ScratchpadProcessRunner = runProcess
    ) async -> ScratchpadCheck {
        let issues = document.issues
        guard issues.isEmpty else { return ScratchpadCheck(.failed, issues: issues) }
        let language = document.language
        guard let interpreter = language.interpreter, let checker = language.checkDescription else {
            return ScratchpadCheck(.notChecked, issues: [ScratchpadIssue(line: nil, "\(language.displayName) has no syntax check.")])
        }
        guard let executable = resolve(interpreter, searchPath: searchPath, isExecutable: isExecutable) else {
            return ScratchpadCheck(.notChecked, issues: [ScratchpadIssue(line: nil, "\(interpreter) wasn't found, so the syntax wasn't checked.")])
        }
        let file = directory.appendingPathComponent("check-\(UUID().uuidString).\(language.fileExtension)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard FileManager.default.createFile(atPath: file.path, contents: Data(document.text.utf8), attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        } catch {
            return ScratchpadCheck(.notChecked, issues: [ScratchpadIssue(line: nil, "The script couldn't be written for checking.")])
        }
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            let result = try await run(executable, language.checkArguments + [file.path], timeout)
            if result.status == 0 { return ScratchpadCheck(.passed, checker: checker) }
            let output = result.output.replacingOccurrences(of: file.path, with: document.fileName)
            var found = parse(output, grammar: language.grammar)
            if found.isEmpty {
                let first = output.split(whereSeparator: \.isNewline).first.map(String.init) ?? "\(checker) exited with status \(result.status)."
                found = [ScratchpadIssue(line: nil, first)]
            }
            return ScratchpadCheck(.failed, issues: Array(found.prefix(maximumIssues)), checker: checker)
        } catch is ScratchpadCheckTimedOut {
            return ScratchpadCheck(.failed, issues: [ScratchpadIssue(line: nil, "The syntax check didn't finish within \(Int(timeout)) seconds.")], checker: checker)
        } catch {
            return ScratchpadCheck(.notChecked, issues: [ScratchpadIssue(line: nil, "\(executable) couldn't be started, so the syntax wasn't checked.")], checker: checker)
        }
    }

    /// bash and sh report `file: line N: message` (dash: `file: N: message`); node reports `file:N`, the source line,
    /// a caret line and then `SyntaxError: message`.
    static func parse(_ output: String, grammar: ScratchpadLanguage.Grammar) -> [ScratchpadIssue] {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        switch grammar {
        case .shell:
            return lines.compactMap { text in
                guard let match = text.firstMatch(of: #/: (?:line )?(\d+): (.+)$/#), let line = Int(match.1) else { return nil }
                return ScratchpadIssue(line: line, String(match.2))
            }
        case .markdown: return []
        case .javascript:
            guard let first = lines.first, let match = first.firstMatch(of: /:(\d+)$/), let line = Int(match.1) else { return [] }
            let message = lines.first { $0.firstMatch(of: #/^[A-Za-z]*Error: /#) != nil } ?? "Syntax error."
            return [ScratchpadIssue(line: line, message)]
        }
    }

    public static let runProcess: ScratchpadProcessRunner = { executable, arguments, timeout in
        try await Task.detached(priority: .userInitiated) {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let box = ProcessBox(process)
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if box.process.isRunning { box.process.terminate() } }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationReason == .uncaughtSignal { throw ScratchpadCheckTimedOut() }
            return ScratchpadProcessResult(status: process.terminationStatus, output: String(decoding: data.prefix(maximumOutput), as: UTF8.self))
        }.value
    }

    private final class ProcessBox: @unchecked Sendable {
        let process: Process
        init(_ process: Process) { self.process = process }
    }
}
