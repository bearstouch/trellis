import Darwin
import TrellisAskpass
import XCTest
@testable import TrellisCore

private final class ScriptedTerminal: AskpassTerminal {
    var answers: [String?]
    var asked: [(prompt: String, echo: Bool)] = []
    var shown: [String] = []
    init(_ answers: [String?]) { self.answers = answers }
    func show(_ text: String) { shown.append(text) }
    func ask(_ prompt: String, echo: Bool) -> String? {
        asked.append((prompt, echo))
        return answers.isEmpty ? nil : answers.removeFirst()
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

final class AskpassTests: XCTestCase {
    private let secret = Data("s3cret-PASSWORD-VALUE".utf8)

    func testOnlyPasswordPromptsAreAnswerable() {
        XCTAssertEqual(AskpassPrompt.classify("deploy@prod's password: ", kind: nil), .password)
        XCTAssertEqual(AskpassPrompt.classify("(deploy@prod) Password:", kind: nil), .password)
        XCTAssertEqual(AskpassPrompt.classify("Enter passphrase for key '/Users/a/.ssh/id_ed25519': ", kind: nil), .typed(echo: false))
        XCTAssertEqual(
            AskpassPrompt.classify("Are you sure you want to continue connecting (yes/no/[fingerprint])? ", kind: nil), .typed(echo: true),
            "Host-key trust is always typed by the person")
        XCTAssertEqual(AskpassPrompt.classify("New password:", kind: nil), .typed(echo: false))
        XCTAssertEqual(AskpassPrompt.classify("Verification code:", kind: nil), .typed(echo: false))
        XCTAssertEqual(AskpassPrompt.classify("deploy@prod's password: ", kind: "confirm"), .confirm)
        XCTAssertEqual(AskpassPrompt.classify("Confirm user presence for key", kind: "none"), .notice)
    }

    func testNonceFraming() {
        let nonce = AskpassProtocol.makeNonce()
        XCTAssertNotEqual(nonce, AskpassProtocol.makeNonce())
        XCTAssertEqual(AskpassProtocol.nonce(from: AskpassProtocol.request(nonce: nonce)), nonce)
        XCTAssertNil(AskpassProtocol.nonce(from: Data(nonce.utf8)), "Unterminated")
        XCTAssertNil(AskpassProtocol.nonce(from: Data("short\n".utf8)))
        XCTAssertNil(AskpassProtocol.nonce(from: Data((nonce.uppercased() + "\n").utf8)))
    }

    func testHelperWritesBrokerPasswordWithoutTouchingTerminal() {
        let terminal = ScriptedTerminal([])
        var output = Data(), sent: (String, Data)?
        var helper = AskpassHelper(
            arguments: ["trellis-askpass", "deploy@prod's password: "],
            environment: [AskpassProtocol.socketVariable: "/tmp/s", AskpassProtocol.nonceVariable: AskpassProtocol.makeNonce()])
        helper.exchange = {
            sent = ($0, $1); return Data([AskpassProtocol.password]) + self.secret
        }
        helper.terminal = terminal
        helper.write = { output.append($0) }
        XCTAssertEqual(helper.run(), 0)
        XCTAssertEqual(output, secret + Data([0x0A]))
        XCTAssertEqual(sent?.0, "/tmp/s")
        XCTAssertTrue(terminal.asked.isEmpty)
    }

    func testHelperFallsBackToTerminalForEverythingElse() {
        var helper = AskpassHelper(
            arguments: ["trellis-askpass", "deploy@prod's password: "],
            environment: [AskpassProtocol.socketVariable: "/tmp/s", AskpassProtocol.nonceVariable: AskpassProtocol.makeNonce()])
        var output = Data(), exchanges = 0
        let terminal = ScriptedTerminal(["typed", "yes", nil])
        helper.exchange = { _, _ in
            exchanges += 1; return Data([AskpassProtocol.interactive])
        }
        helper.terminal = terminal
        helper.write = { output.append($0) }
        XCTAssertEqual(helper.run(), 0, "Refused by the broker: asked on the terminal, echo off")
        XCTAssertEqual(output, Data("typed\n".utf8))
        XCTAssertEqual(terminal.asked.last?.echo, false)

        helper.arguments = ["trellis-askpass", "Are you sure you want to continue connecting (yes/no/[fingerprint])? "]
        output = Data()
        XCTAssertEqual(helper.run(), 0)
        XCTAssertEqual(output, Data("yes\n".utf8))
        XCTAssertEqual(exchanges, 1, "Trust prompts never reach the broker")
        XCTAssertEqual(helper.run(), 1, "No terminal input fails the prompt")

        helper.environment = [:]
        helper.arguments = ["trellis-askpass", "deploy@prod's password: "]
        terminal.answers = ["manual"]
        output = Data()
        XCTAssertEqual(helper.run(), 0)
        XCTAssertEqual(output, Data("manual\n".utf8), "Without broker variables the prompt is typed")
        XCTAssertEqual(exchanges, 1)
    }

    private func broker(peer: (path: String, parent: pid_t)?) -> AskpassBroker {
        let broker = AskpassBroker(helperPath: "/fixture/trellis-askpass")
        broker.peerProcess = { _ in peer }
        return broker
    }

    func testBrokerAnswersOnceForTheSessionsHelper() throws {
        let broker = broker(peer: ("/fixture/trellis-askpass", 4242))
        defer { broker.stop() }
        let calls = Counter(), secret = secret
        let registration = try XCTUnwrap(
            broker.register(
                parent: { 4242 },
                answer: {
                    calls.increment(); return secret
                }))
        var info = stat()
        XCTAssertEqual(lstat(registration.socketPath, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        XCTAssertEqual(stat((registration.socketPath as NSString).deletingLastPathComponent, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o700)
        let request = AskpassProtocol.request(nonce: registration.nonce)
        XCTAssertEqual(AskpassHelper.exchange(registration.socketPath, request), Data([AskpassProtocol.password]) + secret)
        XCTAssertEqual(AskpassHelper.exchange(registration.socketPath, request), Data([AskpassProtocol.interactive]), "One answer per connection")
        XCTAssertEqual(calls.count, 1)
        let environment = registration.environment(helper: broker.helperPath)
        XCTAssertEqual(environment["SSH_ASKPASS_REQUIRE"], "force")
        XCTAssertFalse(environment.values.contains { $0.contains("s3cret") }, "The environment carries no secret")
    }

    func testBrokerRefusesOtherProcessesAndNonces() throws {
        let calls = Counter(), secret = secret
        for (peer, parent) in [(("/elsewhere/tool", pid_t(4242)), pid_t(4242)), (("/fixture/trellis-askpass", 999), 4242), (("/fixture/trellis-askpass", 4242), 7)] {
            let broker = broker(peer: peer)
            defer { broker.stop() }
            let registration = try XCTUnwrap(
                broker.register(
                    parent: { parent },
                    answer: {
                        calls.increment(); return secret
                    }))
            XCTAssertEqual(AskpassHelper.exchange(registration.socketPath, AskpassProtocol.request(nonce: registration.nonce)), Data([AskpassProtocol.interactive]))
            XCTAssertEqual(broker.registeredCount, 0, "A refused request still consumes the nonce")
        }
        let broker = broker(peer: ("/fixture/trellis-askpass", 4242))
        defer { broker.stop() }
        let registration = try XCTUnwrap(
            broker.register(
                parent: { 4242 },
                answer: {
                    calls.increment(); return secret
                }))
        XCTAssertEqual(
            AskpassHelper.exchange(registration.socketPath, AskpassProtocol.request(nonce: AskpassProtocol.makeNonce())), Data([AskpassProtocol.interactive]))
        broker.unregister(registration)
        XCTAssertEqual(AskpassHelper.exchange(registration.socketPath, AskpassProtocol.request(nonce: registration.nonce)), Data([AskpassProtocol.interactive]))
        XCTAssertEqual(calls.count, 0)
    }

    func testStopRemovesSocket() throws {
        let broker = broker(peer: nil)
        let registration = try XCTUnwrap(broker.register(parent: { nil }, answer: { nil }))
        broker.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: (registration.socketPath as NSString).deletingLastPathComponent))
    }

    /// The real helper binary, run by a child shell standing in for ssh.
    func testBuiltHelperEndToEnd() throws {
        let helper = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent(AskpassBroker.helperName).path
        guard FileManager.default.isExecutableFile(atPath: helper) else { throw XCTSkip("Run `swift build` first to build \(AskpassBroker.helperName).") }
        let broker = AskpassBroker(helperPath: helper)
        defer { broker.stop() }
        let parent = Counter(), secret = secret
        // `; :` keeps sh from exec'ing the helper, so its parent is the stand-in ssh.
        let second = Process(), secondOutput = Pipe()
        second.executableURL = URL(fileURLWithPath: "/bin/sh")
        second.arguments = ["-c", "read go; \"$0\" \"deploy@prod's password: \"; :", helper]
        let gate = Pipe()
        second.standardInput = gate
        second.standardOutput = secondOutput
        let holder = PIDHolder()
        let registered = try XCTUnwrap(
            broker.register(
                parent: { holder.pid },
                answer: {
                    parent.increment(); return secret
                }))
        second.environment = ProcessInfo.processInfo.environment.merging(registered.environment(helper: helper)) { $1 }
        try second.run()
        holder.pid = second.processIdentifier
        gate.fileHandleForWriting.write(Data("go\n".utf8))
        second.waitUntilExit()
        XCTAssertEqual(secondOutput.fileHandleForReading.readDataToEndOfFile(), secret + Data([0x0A]))
        XCTAssertEqual(parent.count, 1)
    }
}

private final class PIDHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int32?
    var pid: Int32? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
