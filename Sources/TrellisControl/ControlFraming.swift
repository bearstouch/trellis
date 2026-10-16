import Foundation

/// Newline-delimited frames. JSON encodes newlines inside strings as `\n`, so a
/// raw 0x0A byte always ends a frame. Frames are limited to 1 MiB.
public struct ControlFramer: Sendable {
    public static let maximumFrame = 1_048_576
    public enum Failure: Error, Equatable, Sendable { case frameTooLarge }

    private var buffer = Data()
    public init() {}

    /// Returns every complete frame in arrival order. After `frameTooLarge`
    /// the stream is unusable and the connection must close.
    public mutating func append(_ bytes: Data) throws(Failure) -> [Data] {
        // The retained partial frame holds no newline, so only new bytes are
        // scanned, and frames are consumed once at the end; both keep a client
        // trickling bytes or packing tiny frames from causing quadratic work.
        let scanned = buffer.count
        buffer.append(bytes)
        var frames: [Data] = []
        var start = buffer.startIndex, from = buffer.startIndex + scanned
        while let newline = buffer[from...].firstIndex(of: 0x0A) {
            let frame = buffer[start..<newline]
            guard frame.count <= Self.maximumFrame else { throw .frameTooLarge }
            frames.append(Data(frame.last == 0x0D ? frame.dropLast() : frame))
            start = newline + 1; from = start
        }
        buffer.removeSubrange(buffer.startIndex..<start)
        guard buffer.count <= Self.maximumFrame else { throw .frameTooLarge }
        return frames
    }
}
