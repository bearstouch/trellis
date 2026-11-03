import TrellisCore
import XCTest
@testable import TrellisCLI

final class CLIHelpTests: XCTestCase {
    private func allHelpTexts() -> [(String, String)] {
        var texts = [("overview", CLIHelp.text(noun: nil, verb: nil))]
        for (noun, verbs) in CLICommands.table {
            texts.append((noun, CLIHelp.text(noun: noun, verb: nil)))
            for verb in verbs.keys { texts.append(("\(noun) \(verb)", CLIHelp.text(noun: noun, verb: verb))) }
        }
        return texts
    }

    func testEveryHelpFormGoesToStdoutAndExitsZeroWithoutTouchingTheApp() {
        for arguments in [
            ["--help"], ["-h"], ["help"], ["--help", "--json"], ["--json", "--help"], ["help", "--help"], ["window", "--help"], ["window", "-h"], ["help", "window"], ["window", "--json", "--help"],
            ["window", "create", "--help"], ["window", "create", "-h"], ["help", "window", "create"], ["layout", "apply", "--help"], ["window", "rename", "--window", "x", "--help"]
        ] {
            let h = CLIHarness()
            XCTAssertEqual(h.run(arguments), 0, "\(arguments)")
            XCTAssertEqual(h.out.count, 1, "\(arguments)")
            XCTAssertEqual(h.err, [], "\(arguments)")
            XCTAssertEqual(h.transport.calls.count, 0, "\(arguments)")
            XCTAssertEqual(h.stdinReads, 0, "Help never reads the token: \(arguments)")
            XCTAssertEqual(h.launches, 0, "\(arguments)")
        }
    }

    func testHelpNarrowsToTheRequestedTopic() throws {
        let h = CLIHarness()
        XCTAssertEqual(h.run(["--help"]), 0)
        let overview = h.out[0]
        XCTAssertTrue(overview.hasPrefix("trellis - "))
        for section in ["Usage:", "Nouns:", "Options:", "Exit status:", "Examples:"] { XCTAssertTrue(overview.contains(section), section) }
        for noun in CLICommands.table.keys { XCTAssertTrue(overview.contains("\n  \(noun) "), noun) }

        let noun = CLIHarness()
        XCTAssertEqual(noun.run(["window", "--help"]), 0)
        XCTAssertTrue(noun.out[0].hasPrefix("trellis window - "))
        for verb in try XCTUnwrap(CLICommands.table["window"]).keys { XCTAssertTrue(noun.out[0].contains("\n  \(verb) "), verb) }

        let command = CLIHarness()
        XCTAssertEqual(command.run(["window", "rename", "--help"]), 0)
        XCTAssertTrue(command.out[0].contains("trellis window rename --window WINDOW --name NAME"))
        XCTAssertTrue(command.out[0].contains("--idempotency-key KEY"), "Flags the synopsis omits are still listed")
        XCTAssertTrue(command.out[0].contains("--token-stdin"))

        let local = CLIHarness()
        XCTAssertEqual(local.run(["cli", "install-link", "--help"]), 0)
        XCTAssertFalse(local.out[0].contains("--token-stdin"), "cli commands need no credentials")

        let layout = CLIHarness()
        XCTAssertEqual(layout.run(["layout", "apply", "--help"]), 0, "A missing FILE doesn't block help")
        XCTAssertTrue(layout.out[0].contains("Arguments:\n  FILE"))
    }

    func testHelpTablesMatchTheCommandTable() throws {
        XCTAssertEqual(Set(CLIHelp.nouns.keys), Set(CLICommands.table.keys))
        XCTAssertEqual(Set(CLIHelp.commands.keys), Set(CLICommands.table.keys))
        var used: Set<String> = []
        for (noun, verbs) in CLICommands.table {
            let docs = try XCTUnwrap(CLIHelp.commands[noun], noun)
            XCTAssertEqual(Set(docs.keys), Set(verbs.keys), noun)
            for (verb, spec) in verbs {
                let name = "\(noun) \(verb)"
                let doc = try XCTUnwrap(docs[verb], name)
                XCTAssertFalse(doc.summary.isEmpty, name)
                // The synopsis may leave out only --idempotency-key, which every mutating command takes.
                let flags = spec.options.union(spec.switches)
                XCTAssertEqual(Set(CLIHelp.synopsisOptions(doc)), flags.subtracting(["idempotency-key"]), name)
                XCTAssertEqual(CLIHelp.optionOrder(doc, spec).count, flags.count, name)
                XCTAssertEqual(doc.usage.allSatisfy { $0.hasPrefix("FILE") }, spec.positionals == 1, name)
                for flag in flags {
                    XCTAssertNotNil(CLIHelp.overrides["\(name) --\(flag)"] ?? CLIHelp.options[flag], "\(name) --\(flag)")
                    if CLIHelp.options[flag] != nil { used.insert(flag) }
                }
            }
        }
        XCTAssertEqual(Set(CLIHelp.options.keys), used, "No documentation for flags that no longer exist")
        for key in CLIHelp.overrides.keys {
            let parts = key.split(separator: " ").map(String.init)
            XCTAssertEqual(parts.count, 3, key)
            let spec = try XCTUnwrap(CLICommands.table[parts[0]]?[parts[1]], key)
            XCTAssertTrue(spec.options.union(spec.switches).contains(String(parts[2].dropFirst(2))), key)
        }
    }

    func testHelpIsPlainTextThatFitsEightyColumns() {
        for (topic, text) in allHelpTexts() {
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                XCTAssertLessThanOrEqual(line.count, 80, "\(topic): \(line)")
                XCTAssertFalse(line.hasSuffix(" "), "\(topic): trailing space in \(line)")
            }
            XCTAssertTrue(text.allSatisfy(\.isASCII), "\(topic) must survive LANG=C")
            XCTAssertFalse(text.hasSuffix("\n"), "stdout adds the one newline")
        }
    }

    func testVersion() {
        for flag in ["--version", "-V"] {
            let h = CLIHarness()
            XCTAssertEqual(h.run([flag]), 0)
            XCTAssertEqual(h.out, ["trellis \(AppVersion.current)"])
            XCTAssertEqual(h.err, [])
            XCTAssertEqual(h.transport.calls.count, 0)
        }
    }

    func testJsonModeKeepsTheEnvelope() throws {
        for (arguments, key) in [(["--help", "--json"], "help"), (["window", "list", "--help", "--json"], "help"), (["--version", "--json"], "version")] {
            let h = CLIHarness()
            XCTAssertEqual(h.run(arguments), 0)
            XCTAssertEqual(h.out.count, 1)
            let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(h.out[0].utf8)) as? [String: Any])
            XCTAssertEqual(envelope["ok"] as? Bool, true)
            let result = try XCTUnwrap(envelope["result"] as? [String: String])
            XCTAssertEqual(Array(result.keys), [key])
            if key == "version" { XCTAssertEqual(result[key], AppVersion.current, "The bare version, for scripts") }
        }
        // A usage error in JSON mode has no extra fields and nothing on stderr.
        let h = CLIHarness()
        XCTAssertEqual(h.run(["nope", "--json"]), 2)
        XCTAssertEqual(h.err, [])
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(h.out[0].utf8)) as? [String: Any])
        XCTAssertEqual(Set(try XCTUnwrap(envelope["error"] as? [String: Any]).keys), ["code", "message", "exitStatus"])
    }

    func testUsageErrorsPointAtTheNarrowestHelpOnStderr() {
        let cases: [([String], String)] = [
            ([], "Try 'trellis --help'"), (["--json"], ""), (["nope"], "Try 'trellis --help'"), (["nope", "--help"], "Try 'trellis --help'"), (["help", "nope"], "Try 'trellis --help'"),
            (["window"], "Try 'trellis window --help'"), (["window", "explode"], "Try 'trellis window --help'"), (["help", "window", "explode"], "Try 'trellis window --help'"),
            (["window", "explode", "--help"], "Try 'trellis window --help'"), (["help", "window", "list", "extra"], "Try 'trellis window list --help'"),
            (["window", "list", "--bogus"], "Try 'trellis window list --help'")
        ]
        for (arguments, hint) in cases {
            let h = CLIHarness()
            XCTAssertEqual(h.run(arguments), 2, "\(arguments)")
            if arguments == ["--json"] {
                XCTAssertEqual(h.err, [])
                continue
            }
            XCTAssertEqual(h.out, [], "\(arguments)")
            XCTAssertEqual(h.err.count, 2, "\(arguments)")
            XCTAssertTrue(h.err[0].hasPrefix("trellis: "), "\(arguments)")
            XCTAssertTrue(h.err[0].hasSuffix("(INVALID_ARGUMENTS)"), "\(arguments)")
            XCTAssertTrue(h.err[1].contains(hint), "\(arguments): \(h.err[1])")
        }
        let bare = CLIHarness()
        XCTAssertEqual(bare.run([]), 2)
        XCTAssertTrue(bare.err[1].hasPrefix("Usage: trellis <noun> <verb> [options]\n"))

        // Argument errors found after parsing get the hint too.
        let noCredentials = CLIHarness()
        XCTAssertEqual(noCredentials.run(["window", "list"]), 2)
        XCTAssertEqual(noCredentials.err.last, "Try 'trellis window list --help' for more information.")
        let missingOption = CLIHarness()
        XCTAssertEqual(missingOption.run(["window", "get", "--token-stdin"]), 2)
        XCTAssertEqual(missingOption.err.count, 2)
        XCTAssertEqual(missingOption.err.last, "Try 'trellis window get --help' for more information.")

        // Failures from the app are not usage errors: no hint.
        let app = CLIHarness()
        app.discovery = nil
        XCTAssertEqual(app.run(["window", "list", "--token-stdin"]), 7)
        XCTAssertEqual(app.err.count, 1)
    }

    func testAnOptionValueThatLooksLikeHelpIsStillAValue() {
        let h = CLIHarness()
        let session = UUID().uuidString
        XCTAssertEqual(h.run(["session", "execute", "--session", session, "--command", "--help", "--submit", "--token-stdin"]), 0)
        XCTAssertEqual(h.transport.calls.last?.method, "session.execute")
        XCTAssertEqual(h.transport.calls.last?.params["command"], .string("--help"))
    }

    func testHintNeverEchoesAnArgument() {
        let secret = "trl_STDIN_SECRET_123"
        for arguments in [["window", "list", "--token", secret], ["window", "list", "--token-stdin", secret], ["window", secret, "--token-stdin"]] {
            XCTAssertFalse(CLIHelp.hint(arguments).contains(secret), "\(arguments)")
        }
        // A secret in a command position, as when --token=VALUE comes first, isn't echoed in the message either.
        for arguments in [[secret], ["--token=\(secret)", "window", "list"], ["window", "--token=\(secret)"], ["help", secret], ["help", "window", secret], [secret, "--help"]] {
            for mode in [arguments, arguments + ["--json"]] {
                let h = CLIHarness()
                XCTAssertEqual(h.run(mode), 2, "\(mode)")
                XCTAssertFalse((h.out + h.err).joined().contains(secret), "\(mode)")
            }
        }
        let h = CLIHarness()
        XCTAssertEqual(h.run(["window", "list", "--help", "--token", secret]), 0, "Help is answered first; the rest is ignored")
        XCTAssertFalse((h.out + h.err).joined().contains(secret))
    }
}
