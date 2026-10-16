import Darwin
import Foundation

@MainActor
public protocol LocalSessionTransport: AnyObject {
    var onOutput: ((Data) -> Void)? { get set }
    var onExit: ((Int32?) -> Void)? { get set }
    var onInputError: ((Error) -> Void)? { get set }
    func launch(_ configuration: ValidatedLocalLaunch, size: TerminalSize) async throws -> Int32
    func send(_ data: Data) throws
    func resize(_ size: TerminalSize)
    func signalGroup(_ signal: Int32)
}

/// Engine-neutral lifecycle owner. Filesystem/spawn work runs asynchronously;
/// process callbacks and native rendering remain ordered on the main actor.
@MainActor
public final class LocalSessionController {
    public let id: UUID
    public private(set) var state: SessionState = .stopped
    public private(set) var processID: Int32?
    public private(set) var exitCode: Int32?
    public private(set) var failure: LocalLaunchError?
    public var onOutput: ((Data) -> Void)?
    public var onStateChanged: ((SessionState) -> Void)?
    public var onExit: ((Int32?) -> Void)?
    public var onInputError: ((Error) -> Void)?
    private let transport: any LocalSessionTransport
    private let validator: LocalLaunchValidator
    private var starting = false
    private var exitReceived = false
    private var exitNotified = false
    private var pendingExit: Int32?
    private var closeSignal: Int32?
    private var requestedSize: TerminalSize?

    public init(id: UUID = UUID(), transport: any LocalSessionTransport,
                validator: LocalLaunchValidator = LocalLaunchValidator()) {
        self.id = id; self.transport = transport; self.validator = validator
        transport.onOutput = { [weak self] in self?.onOutput?($0) }
        transport.onInputError = { [weak self] in self?.onInputError?($0) }
        transport.onExit = { [weak self] in self?.receivedExit($0) }
    }

    public func start(_ configuration: LocalLaunchConfiguration, size: TerminalSize) async {
        guard state == .stopped else { return }
        starting = true
        requestedSize = size
        changeState(.starting)
        do {
            let validator = validator
            let launch = try await Task.detached(priority: .userInitiated) { try validator.validate(configuration) }.value
            guard closeSignal == nil, !Task.isCancelled else { throw LocalLaunchError.cancelled }
            let pid = try await transport.launch(launch, size: size)
            guard pid > 0 else { throw LocalLaunchError.spawnFailed(EIO) }
            processID = pid
            // Validation and spawning suspend this actor; a resize in either
            // interval must reach the new PTY before it is exposed as running.
            if let requestedSize, requestedSize != size { transport.resize(requestedSize) }
            if Task.isCancelled, closeSignal == nil { closeSignal = SIGTERM }
            starting = false
            changeState(closeSignal == nil ? .running : .closing)
            if let closeSignal { transport.signalGroup(closeSignal) }
            if exitReceived { finishExit(pendingExit) }
        } catch {
            starting = false
            processID = nil
            failure = (error as? LocalLaunchError) ?? .spawnFailed(EIO)
            changeState(failure == .cancelled ? .exited : .failed)
            exitReceived = true
            notifyExit(nil)
        }
    }

    public func send(_ data: Data) throws {
        guard state == .running else { throw TerminalAdapterError.inputClosed }
        try transport.send(data)
    }

    public func resize(_ size: TerminalSize) {
        guard state == .running || state == .starting else { return }
        requestedSize = size
        transport.resize(size)
    }

    public func stop(signal: Int32 = SIGTERM) {
        guard state == .starting || state == .running || state == .closing else { return }
        guard closeSignal != signal, closeSignal != SIGKILL else { return }
        if closeSignal == nil || signal == SIGKILL { closeSignal = signal }
        changeState(.closing)
        if processID != nil { transport.signalGroup(closeSignal!) }
    }

    private func receivedExit(_ code: Int32?) {
        guard !exitReceived, state == .starting || state == .running || state == .closing else { return }
        exitReceived = true
        pendingExit = code
        if !starting { finishExit(code) }
    }

    private func finishExit(_ code: Int32?) {
        processID = nil
        exitCode = code
        changeState(.exited)
        notifyExit(code)
    }

    private func notifyExit(_ code: Int32?) {
        guard !exitNotified else { return }
        exitNotified = true
        onExit?(code)
    }

    private func changeState(_ next: SessionState) {
        guard state != next else { return }
        state = next
        onStateChanged?(next)
    }
}
