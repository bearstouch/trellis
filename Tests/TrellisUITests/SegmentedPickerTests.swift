import AppKit
import SwiftUI
import TrellisCore
import XCTest

@testable import TrellisUI

/// Segmented pickers must not read a model: on macOS 26 that leaks Observation registrars on every publish, and each
/// later update re-registers all of them.
@MainActor final class SegmentedPickerTests: XCTestCase {
    private final class Model: ObservableObject {
        @Published var ratio = 0
        var selected: [String] = []
    }

    private struct Host: View {
        @ObservedObject var model: Model
        var body: some View {
            let ratio = model.ratio
            SegmentedPicker("Direction", selection: 0, options: [(0, "A"), (1, "B")]) { model.selected.append("\($0) at \(ratio)") }
        }
    }

    private func settle(_ view: NSView) { view.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.01)); view.layoutSubtreeIfNeeded() }

    private func host<V: View>(_ view: V) -> NSHostingView<V> {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 480), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        settle(host)
        return host
    }

    private func segments(in view: NSView) -> NSSegmentedControl? { view as? NSSegmentedControl ?? view.subviews.lazy.compactMap(segments).first }

    private func click(_ segment: Int, in view: NSView) throws {
        let control = try XCTUnwrap(segments(in: view))
        control.selectedSegment = segment
        NSApp.sendAction(try XCTUnwrap(control.action), to: control.target, from: control)
    }

    func testShowsItsOptionsAndCallsTheAction() throws {
        _ = NSApplication.shared
        let model = Model()
        let view = host(Host(model: model))
        let control = try XCTUnwrap(segments(in: view))
        XCTAssertEqual((0..<control.segmentCount).map { control.label(forSegment: $0) }, ["A", "B"])
        XCTAssertEqual(control.selectedSegment, 0)
        try click(1, in: view)
        XCTAssertEqual(model.selected, ["1 at 0"])
    }

    /// The action sees what the caller last rendered, even when the picker's own values never changed.
    func testActionUsesTheLatestCapturedValues() throws {
        _ = NSApplication.shared
        let model = Model()
        let view = host(Host(model: model))
        for ratio in [40, 70] { model.ratio = ratio; settle(view) }
        try click(1, in: view)
        XCTAssertEqual(model.selected, ["1 at 70"])
    }

    /// Live Observation registrars in this process, from `heap`; nil when the tool can't report them.
    private func observationRegistrars() -> Int? {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/heap"); process.arguments = ["\(getpid())"]
        process.standardOutput = pipe; process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0, output.contains("CLASS_NAME") else { return nil }
        let line = output.split(separator: "\n").first { $0.contains("ObservationRegistrar.(State") && $0.contains("LockedBuffer") }
        return line.flatMap { Int($0.split(separator: " ").first ?? "") } ?? 0
    }

    /// The Agents view holds the picker that is on screen all day. Written inline it leaked two registrars per publish.
    func testAgentsViewKeepsNoRegistrarsAcrossModelPublishes() async throws {
        _ = NSApplication.shared
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-seg-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let preferences = try XCTUnwrap(UserDefaults(suiteName: "trellis-seg-\(UUID().uuidString)"))
        let model = AppWorkspaceModel(store: try WorkspaceStore(), preferences: preferences, persistence: WorkspacePersistence(directory: scratch))
        _ = await model.loadWorkspace()
        let view = host(AgentsSidebarView(model: model).frame(width: 300, height: 460))
        XCTAssertNotNil(segments(in: view), "the placement picker isn't on screen, so the test observes nothing")

        for _ in 0..<20 { model.objectWillChange.send(); settle(view) }
        guard let before = observationRegistrars() else { throw XCTSkip("heap could not inspect this process") }
        for _ in 0..<150 { model.objectWillChange.send(); settle(view) }
        let after = try XCTUnwrap(observationRegistrars())
        XCTAssertLessThan(after - before, 30, "150 publishes left \(after - before) Observation registrars behind")
    }

    /// A segmented `Picker` written inline in a view can read a model again; they all go through `SegmentedPicker`.
    func testNoViewDeclaresItsOwnSegmentedPicker() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)).compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 50, "the sources were not found")
        let offenders = try files.filter { $0.lastPathComponent != "SegmentedPicker.swift" }.filter {
            let text = try String(contentsOf: $0, encoding: .utf8).filter { !$0.isWhitespace }
            return text.contains(".pickerStyle(.segmented)") || text.contains("SegmentedPickerStyle()")
        }
        XCTAssertEqual(offenders.map(\.lastPathComponent), [], "use SegmentedPicker instead of an inline segmented Picker")
    }
}
