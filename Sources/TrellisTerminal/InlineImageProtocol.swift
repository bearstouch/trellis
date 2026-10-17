import AppKit
import ImageIO
import SwiftTerm
import UniformTypeIdentifiers

/// The `File`/`MultipartFile` arguments of iTerm2's inline image protocol (FR-IM01). Values come from untrusted
/// output; the file name is never read.
struct InlineImageArguments: Equatable {
    let values: [String: String]

    init(_ data: ArraySlice<UInt8>) {
        var values: [String: String] = [:]
        for pair in data.split(separator: UInt8(ascii: ";")) {
            guard let equal = pair.firstIndex(of: UInt8(ascii: "=")), let key = String(bytes: pair[..<equal], encoding: .utf8),
                let value = String(bytes: pair[(equal + 1)...], encoding: .utf8)
            else { continue }
            values[key] = value
        }
        self.values = values
    }

    /// `inline=0` asks to download a file; Trellis never writes one (FR-IM04).
    var inline: Bool { values["inline"] == "1" }
    var declaredSize: Int? { values["size"].flatMap { Int($0) }.flatMap { $0 >= 0 ? $0 : nil } }
    var width: ImageSizeRequest { Self.dimension(values["width"]) }
    var height: ImageSizeRequest { Self.dimension(values["height"]) }
    var preserveAspectRatio: Bool { (values["preserveAspectRatio"] ?? "1") == "1" }

    /// `auto`, `N` cells, `Npx` or `N%`, with upstream SwiftTerm's limits; anything else is `auto`.
    static func dimension(_ value: String?) -> ImageSizeRequest {
        guard let value, value != "auto" else { return .auto }
        if value.hasSuffix("%") { if let n = Int(value.dropLast()), (1...100).contains(n) { return .percent(n) }; return .auto }
        if value.hasSuffix("px") { if let n = Int(value.dropLast(2)), (1..<4096).contains(n) { return .pixels(n) }; return .auto }
        if let n = Int(value), (1..<200).contains(n) { return .cells(n) }
        return .auto
    }
}

/// One OSC 1337 payload (the bytes after `1337;`).
enum InlineImageCommand: Equatable {
    case file(InlineImageArguments, payload: ArraySlice<UInt8>)
    case multipartBegin(InlineImageArguments)
    case filePart(ArraySlice<UInt8>)
    case fileEnd
    case reportCellSize
    /// Other iTerm2 commands (`SetMark`, `SetUserVar`, …) and malformed images are ignored.
    case other

    init(_ data: ArraySlice<UInt8>) {
        let equal = data.firstIndex(of: UInt8(ascii: "="))
        let key = String(decoding: data[..<(equal ?? data.endIndex)], as: UTF8.self)
        let rest = equal.map { data[($0 + 1)...] } ?? []
        switch (key, equal == nil) {
        case ("File", false):
            guard let colon = rest.firstIndex(of: UInt8(ascii: ":")) else { self = .other; return }
            self = .file(InlineImageArguments(rest[..<colon]), payload: rest[(colon + 1)...])
        case ("MultipartFile", false): self = .multipartBegin(InlineImageArguments(rest))
        case ("FilePart", false): self = .filePart(rest)
        case ("FileEnd", true): self = .fileEnd
        case ("ReportCellSize", true): self = .reportCellSize
        default: self = .other
        }
    }

    /// iTerm2's reply: cell height and width in points, then the backing scale.
    static func cellSizeReport(size: CGSize, scale: CGFloat) -> String {
        "\u{1b}]1337;ReportCellSize=" + [size.height, size.width, scale].map { String(format: "%.1f", Double($0)) }.joined(separator: ";") + "\u{1b}\\"
    }
}

/// Reassembles a `MultipartFile` … `FilePart`* … `FileEnd` transfer (FR-IM02). Parts are decoded as they arrive,
/// so at most `maxBytes` of image data and three base64 characters are held.
struct MultipartImageTransfer {
    static let maxBytes = 32 * 1024 * 1024
    private var arguments: InlineImageArguments?
    private var bytes = Data()
    private var remainder: [UInt8] = []

    var isActive: Bool { arguments != nil }

    /// A non-inline transfer is not kept, so its parts are dropped as they arrive.
    mutating func begin(_ arguments: InlineImageArguments) {
        reset()
        if arguments.inline, (arguments.declaredSize ?? 0) <= Self.maxBytes { self.arguments = arguments }
    }

    /// Bad base64 or a transfer that grows past its limit is discarded whole.
    mutating func append(_ part: ArraySlice<UInt8>) {
        guard let arguments else { return }
        let chunk = remainder + part
        let usable = chunk.count - chunk.count % 4
        remainder = Array(chunk[usable...])
        guard let decoded = Data(base64Encoded: Data(chunk[..<usable])) else { reset(); return }
        bytes.append(decoded)
        if bytes.count > min(arguments.declaredSize ?? Self.maxBytes, Self.maxBytes) { reset() }
    }

    mutating func finish() -> (InlineImageArguments, Data)? {
        defer { reset() }
        guard let arguments, remainder.isEmpty, !bytes.isEmpty else { return nil }
        return (arguments, bytes)
    }

    mutating func reset() { arguments = nil; bytes = Data(); remainder = [] }
}

/// Bounds the box `insertImage` draws an image into (FR-IM01, FR-IM04). Upstream doesn't bound a side derived from
/// the aspect ratio: a 10,000 × 1 px image asked to be ten rows tall would be about 1.7 M points wide, allocated
/// row by row. An image that would be wider than the pane, or taller than the largest decodable image, is shrunk
/// to fit, keeping its shape. Two explicit sizes are already bounded and pass through unchanged.
enum InlineImageLayout {
    static func requests(image: CGSize, _ arguments: InlineImageArguments, cell: CGSize, pane: CGSize, scale: CGFloat) -> (
        width: ImageSizeRequest, height: ImageSizeRequest, preserveAspectRatio: Bool
    ) {
        let unchanged = (arguments.width, arguments.height, arguments.preserveAspectRatio)
        let (autoWidth, autoHeight) = (isAuto(arguments.width), isAuto(arguments.height))
        guard autoWidth || autoHeight, image.width > 0, image.height > 0, scale > 0 else { return unchanged }
        var width = points(arguments.width, natural: image.width, cell: cell.width, pane: pane.width, scale: scale)
        var height = points(arguments.height, natural: image.height, cell: cell.height, pane: pane.height, scale: scale)
        // Mirrors `insertImage`: with one side given, the other follows the image's shape.
        if arguments.preserveAspectRatio, autoWidth != autoHeight {
            if autoHeight { height = width * image.height / image.width } else { width = height * image.width / image.height }
        }
        let factor = min(1, max(pane.width, cell.width) / width, CGFloat(InlineImageDecoder.maxPixelDimension) / scale / height)
        guard factor < 1 else { return unchanged }
        return (.pixels(max(1, Int(width * factor))), .pixels(max(1, Int(height * factor))), false)
    }

    private static func isAuto(_ request: ImageSizeRequest) -> Bool { if case .auto = request { return true }; return false }

    private static func points(_ request: ImageSizeRequest, natural: CGFloat, cell: CGFloat, pane: CGFloat, scale: CGFloat) -> CGFloat {
        switch request {
        case .auto: natural / scale
        case .cells(let n): cell * CGFloat(n)
        case .pixels(let n): CGFloat(n)
        case .percent(let n): CGFloat(n) * 0.01 * pane
        }
    }
}

/// Decodes only bitmap formats within pixel limits (FR-IM04). Formats NSImage would also accept from output, such
/// as PDF, EPS or SVG, are refused, and the size is read from the header before any pixels are decoded.
enum InlineImageDecoder {
    static let maxPixelDimension = 10_000
    static let maxPixelCount = 40_000_000
    static let allowedTypes: Set<String> = Set([UTType.png, .jpeg, .gif, .bmp, .tiff, .webP, .heic, .heif].map(\.identifier))

    static func image(from data: Data) -> NSImage? {
        guard let (source, size) = acceptedSource(data) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(size.width, size.height), kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        // Points equal pixels, as for sixel and Kitty images, so `auto` sizing divides by the backing scale.
        return NSImage(cgImage: cgImage, size: CGSize(width: cgImage.width, height: cgImage.height))
    }

    static func acceptedSource(_ data: Data) -> (CGImageSource, CGSize)? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options), let type = CGImageSourceGetType(source),
            allowedTypes.contains(type as String), CGImageSourceGetCount(source) > 0,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
            (1...maxPixelDimension).contains(width), (1...maxPixelDimension).contains(height), width * height <= maxPixelCount
        else { return nil }
        return (source, CGSize(width: width, height: height))
    }
}
