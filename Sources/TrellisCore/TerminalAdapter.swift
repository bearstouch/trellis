import Foundation

public struct TerminalSize: Equatable, Sendable {
    public let columns: Int
    public let rows: Int

    public init(columns: Int, rows: Int) throws {
        guard (1...Int(UInt16.max)).contains(columns),
              (1...Int(UInt16.max)).contains(rows) else {
            throw TerminalAdapterError.invalidSize
        }
        self.columns = columns
        self.rows = rows
    }
}

public enum TerminalRead: Sendable {
    case retainedText
    case commandExitStatus
}

public enum TerminalAdapterError: Error, Equatable {
    case detached
    case invalidSize
    case unsupportedRead
    case inputClosed
    case inputQueueFull
    case inputFailed(Int32)
}

/// Engine-neutral boundary. All events are delivered in order on the UI actor.
/// No terminal engine, process, or AppKit types escape through this API.
@MainActor
public final class TerminalAdapter {
    private var render: ((Data) -> Void)?
    private var write: ((Data) throws -> Void)?
    private var resizePTY: ((TerminalSize) -> Void)?
    private var readText: (() -> String)?
    private var cleanup: (() -> Void)?
    private var lastSize: TerminalSize?
    public private(set) var isDetached = false

    public init(render: @escaping (Data) -> Void,
                write: @escaping (Data) throws -> Void,
                resizePTY: @escaping (TerminalSize) -> Void,
                readText: @escaping () -> String,
                cleanup: @escaping () -> Void) {
        self.render = render
        self.write = write
        self.resizePTY = resizePTY
        self.readText = readText
        self.cleanup = cleanup
    }

    public func receive(_ data: Data) {
        guard !isDetached else { return }
        render?(data)
    }

    public func send(_ data: Data) throws {
        guard !isDetached else { throw TerminalAdapterError.detached }
        try write?(data)
    }

    public func resize(_ size: TerminalSize) throws {
        guard !isDetached else { throw TerminalAdapterError.detached }
        guard size != lastSize else { return }
        lastSize = size
        resizePTY?(size)
    }

    public func read(_ kind: TerminalRead) throws -> String {
        guard !isDetached else { throw TerminalAdapterError.detached }
        guard case .retainedText = kind else { throw TerminalAdapterError.unsupportedRead }
        return readText?() ?? ""
    }

    public func detach() {
        guard !isDetached else { return }
        isDetached = true
        let finish = cleanup
        render = nil
        write = nil
        resizePTY = nil
        readText = nil
        cleanup = nil
        finish?()
    }
}
