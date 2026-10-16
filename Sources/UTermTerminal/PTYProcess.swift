import Darwin
import Foundation
import SwiftTerm
import UTermCore

/// Single owner for the child, PTY and dispatch sources. EOF and child exit are
/// independent: losing terminal I/O must never disable process termination.
@MainActor
final class PTYProcess {
    private(set) var pid: pid_t = 0
    private(set) var descriptor: Int32 = -1
    private(set) var isRunning = false
    var onOutput: ((Data) -> Void)?
    var onExit: ((Int32?) -> Void)?
    var onInputError: ((Error) -> Void)?
    static let inputQueueLimit = 1_048_576
    var pendingInputCount: Int { pending.count }
    private(set) var writeDescriptor: Int32 = -1
    private var reader: DispatchSourceRead?
    private var monitor: DispatchSourceProcess?
    private var writer: DispatchSourceWrite?
    private var pending = Data()

    func start(executable: String, arguments: [String], environment: [String], directory: String, size: winsize) throws {
        guard !isRunning, descriptor == -1 else { throw CocoaError(.fileWriteFileExists) }
        var size = size
        guard let child = PseudoTerminalHelpers.fork(andExec: executable, args: [executable] + arguments,
                env: environment, currentDirectory: directory, desiredWindowSize: &size) else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        pid = child.pid
        descriptor = child.masterFd
        isRunning = true
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        let fd = descriptor
        let readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        // Close only after dispatch releases the watched descriptor.
        readSource.setCancelHandler { _ = Darwin.close(fd) }
        readSource.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.drainOutput() } }
        reader = readSource
        readSource.activate()
        let exitSource = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        exitSource.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.reapChild() } }
        monitor = exitSource
        exitSource.activate()
    }

    func send(_ data: Data) throws {
        guard isRunning, descriptor >= 0 else { throw TerminalAdapterError.inputClosed }
        guard data.count <= Self.inputQueueLimit - pending.count else { throw TerminalAdapterError.inputQueueFull }
        pending.append(data)
        try flushInput()
    }

    func signalGroup(_ signal: Int32) {
        guard isRunning, pid > 0, getpgid(pid) == pid else { return }
        _ = kill(-pid, signal)
    }

    private func flushInput() throws {
        while !pending.isEmpty, descriptor >= 0 {
            let n = pending.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
            if n > 0 { pending.removeFirst(n); continue }
            if n < 0, errno == EINTR { continue }
            if n < 0, errno == EAGAIN {
                if writer == nil {
                    // Each dispatch source owns a distinct descriptor. Closing the
                    // read source can never invalidate the writer registration.
                    let fd = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
                    guard fd >= 0 else {
                        pending.removeAll()
                        throw TerminalAdapterError.inputFailed(errno)
                    }
                    let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: .main)
                    source.setCancelHandler { _ = Darwin.close(fd) }
                    source.setEventHandler { [weak self] in
                        MainActor.assumeIsolated {
                            guard let self else { return }
                            do { try self.flushInput() }
                            catch { self.onInputError?(error) }
                        }
                    }
                    writeDescriptor = fd
                    writer = source
                    source.activate()
                }
                return
            }
            let failure = errno
            pending.removeAll()
            cancelWriter()
            throw TerminalAdapterError.inputFailed(failure)
        }
        cancelWriter()
    }

    private func cancelWriter() {
        writer?.cancel()
        writer = nil
        writeDescriptor = -1
    }

    private func drainOutput() {
        guard descriptor >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 16_384)
        // Bound each turn so a noisy child cannot monopolize the UI actor.
        for _ in 0..<16 {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if n > 0 { onOutput?(Data(buffer.prefix(n))); continue }
            if n < 0, errno == EINTR { continue }
            if n < 0, errno == EAGAIN { return }
            // EOF ends I/O but the independent child monitor stays active.
            closeIO()
            return
        }
    }

    private func reapChild() {
        guard isRunning else { return }
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        if result == 0 || (result < 0 && errno == EINTR) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in self?.reapChild() }
            return
        }
        guard result == pid else { return }
        isRunning = false
        monitor?.cancel()
        monitor = nil
        // Read the child’s final bytes before releasing the master. A bounded
        // drain yields to queued read events until available output is empty.
        finishExit(status: status)
    }

    private func finishExit(status: Int32) {
        drainOutput()
        if descriptor >= 0 {
            let available = PseudoTerminalHelpers.availableBytes(fd: descriptor)
            if available.status == 0, available.size > 0 {
                DispatchQueue.main.async { [weak self] in self?.finishExit(status: status) }
                return
            }
        }
        closeIO()
        pid = 0
        let code: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        onExit?(code)
    }

    private func closeIO() {
        cancelWriter()
        pending.removeAll()
        descriptor = -1
        reader?.cancel()
        reader = nil
    }

    isolated deinit {
        // Emergency owner disposal: cancel callbacks before a background reaper
        // takes ownership. Ordinary UI shutdown uses graceful stop, not deinit.
        monitor?.cancel()
        writer?.cancel()
        reader?.cancel()
        if isRunning, pid > 0 {
            let child = pid
            if getpgid(child) == child { _ = kill(-child, SIGKILL) }
            DispatchQueue.global().async {
                var status: Int32 = 0
                while waitpid(child, &status, 0) < 0 && errno == EINTR {}
            }
        }
    }
}
