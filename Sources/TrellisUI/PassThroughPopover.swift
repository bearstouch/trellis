import AppKit
import SwiftUI

/// A hover card that never eats a click (FR-W06). SwiftUI's `.popover` is transient, and a transient popover
/// consumes the outside click that dismisses it, so a click on a tab, Settings or Hosts did nothing while a card
/// was up. This one is application-defined: an outside click closes it and still reaches its target.
@MainActor final class PassThroughPopover: NSObject, NSPopoverDelegate {
    let popover = NSPopover()
    /// Called when a click outside, the app deactivating or AppKit closed the card, never for `close()`.
    var onDismiss: () -> Void = {}
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?
    /// Ours, not `popover.isShown`, which stays true while the close animates.
    private(set) var isShown = false

    override init() {
        super.init()
        popover.behavior = .applicationDefined
        popover.delegate = self
    }

    func show(_ content: AnyView, relativeTo view: NSView, edge: NSRectEdge) {
        if let hosting = popover.contentViewController as? NSHostingController<AnyView> {
            hosting.rootView = content
        } else {
            popover.contentViewController = NSHostingController(rootView: content)
        }
        // AppKit places a popover for its size at the moment it shows, and the default is 320 x 320: content that then
        // shrinks to fit ends up beside its anchor, with the arrow pointing at nothing.
        if let measured = popover.contentViewController?.view.fittingSize, measured.width > 0, measured.height > 0, popover.contentSize != measured {
            popover.contentSize = measured
        }
        guard !isShown, view.window != nil else { return }
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: edge)
        isShown = true
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            self?.handleMouseDown(event) ?? event
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.dismiss() }
        }
    }

    /// Always returns the event: a click inside the card works the card, one outside closes it and passes through.
    func handleMouseDown(_ event: NSEvent) -> NSEvent {
        guard isShown, event.window == nil || event.window !== popover.contentViewController?.view.window else { return event }
        dismiss()
        return event
    }

    func close() {
        removeMonitors()
        guard isShown else { return }
        isShown = false
        popover.close()
    }

    private func dismiss() {
        guard isShown else { return }
        close()
        onDismiss()
    }

    private func removeMonitors() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        monitor = nil; resignObserver = nil
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        // A card shown again while the last close animated stays open. One AppKit closed by itself (its anchor's
        // window went away) reports a dismissal, so `presented` doesn't stay true and reopen it on the next update.
        MainActor.assumeIsolated {
            guard !popover.isShown else { return }
            let unexpected = isShown
            removeMonitors(); isShown = false
            if unexpected { onDismiss() }
        }
    }
}

/// Anchors a `PassThroughPopover` to the view it backs, driven by `presented`.
struct PassThroughPopoverAnchor: NSViewRepresentable {
    @Binding var presented: Bool
    let edge: NSRectEdge
    let content: AnyView

    func makeCoordinator() -> PassThroughPopover { PassThroughPopover() }
    func makeNSView(context: Context) -> NSView { AnchorView() }

    func updateNSView(_ view: NSView, context: Context) {
        let card = context.coordinator
        let binding = $presented
        card.onDismiss = { binding.wrappedValue = false }
        if presented { card.show(content, relativeTo: view, edge: edge) } else { card.close() }
    }

    static func dismantleNSView(_ view: NSView, coordinator: PassThroughPopover) { coordinator.close() }
}

/// Only a position for the card; clicks go to the tile above it.
private final class AnchorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
