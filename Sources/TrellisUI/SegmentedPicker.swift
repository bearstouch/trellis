import SwiftUI

/// The app's only segmented `Picker`.
///
/// On macOS 26, each rebuild of a segmented `Picker` during a model publish leaks Observation registrars, and SwiftUI
/// re-registers all of them on every layout pass: updates slow down the longer the app runs (0.25 s each after two
/// days). So the picker here is rebuilt only when its title, selection or options change.
struct SegmentedPicker<Value: Hashable & Sendable>: View {
    private let title: String
    private let selection: Value
    private let options: [(value: Value, label: String)]
    private let onSelect: (Value) -> Void
    @State private var action = SegmentedPickerAction<Value>()

    init(_ title: String, selection: Value, options: [(value: Value, label: String)], onSelect: @escaping (Value) -> Void) {
        self.title = title; self.selection = selection; self.options = options; self.onSelect = onSelect
    }

    var body: some View {
        // Refreshed on every evaluation, so a picker that was not rebuilt still runs what the caller last rendered.
        let _ = action.perform = onSelect
        SegmentedPickerCore(title: title, selection: selection, values: options.map(\.value), labels: options.map(\.label), action: action).equatable()
    }
}

@MainActor final class SegmentedPickerAction<Value> {
    var perform: (Value) -> Void = { _ in }
}

struct SegmentedPickerCore<Value: Hashable & Sendable>: View, Equatable {
    let title: String
    let selection: Value
    let values: [Value]
    let labels: [String]
    let action: SegmentedPickerAction<Value>

    nonisolated static func == (a: Self, b: Self) -> Bool { a.title == b.title && a.selection == b.selection && a.values == b.values && a.labels == b.labels }

    var body: some View {
        Picker(title, selection: Binding(get: { selection }, set: { action.perform($0) })) {
            ForEach(Array(values.enumerated()), id: \.element) { index, value in Text(labels[index]).tag(value) }
        }
        .pickerStyle(.segmented)
    }
}
