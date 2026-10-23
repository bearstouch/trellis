import SwiftUI
import UniformTypeIdentifiers
import TrellisCore
import TrellisTerminal
import class SwiftTerm.TerminalView

public struct WorkspaceRootView: View {
    @ObservedObject private var model: AppWorkspaceModel
    @State private var windowToRename: ManagedWindow?
    /// The scratchpad's width; layout only, never persisted.
    @State private var scratchpadWidth: CGFloat = 380
    @State private var scratchpadDragStart: CGFloat?
    /// Whether the resize cursor is pushed, so it is popped exactly once, also when the panel closes under the mouse.
    @State private var scratchpadCursorPushed = false
    static let scratchpadWidths: ClosedRange<CGFloat> = 280...640
    @State private var windowName = ""
    @FocusState private var tabNameFocused: Bool
    @State private var hoveredTabID: UUID?
    @State private var draggedTabID: UUID?
    @State private var tabDropTargetID: UUID?
    @State private var draggedWindowID: UUID?
    @State private var windowDropTargetID: UUID?
    @State private var windowDragStarts = 0
    public init(model: AppWorkspaceModel) { self.model = model }
    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar.frame(width: model.sidebarCollapsed ? 52 : 205).animation(.easeInOut(duration: 0.15), value: model.sidebarCollapsed)
                    .disabled(model.isRestoring || model.recoveryMessage != nil)
                Divider().overlay(model.separatorOverlay)
                mainArea
            }
            Divider().overlay(model.separatorOverlay)
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high).frame(width: 14, height: 14).accessibilityHidden(true)
                    Text("Trellis")
                    Text(AppVersion.current).monospacedDigit().opacity(0.7).accessibilityLabel("Version \(AppVersion.current)")
                }
                Spacer()
                if model.persistenceReadOnly { Text("Changes won’t be saved") }
                if let notice = model.themeNotice { Text(notice).lineLimit(1).help(notice) }
                if let notice = model.appearanceNotice { Text(notice).lineLimit(1).help(notice) }
                Text(model.accessibility.status).foregroundStyle(sessionStatusColor).accessibilityLabel("Session status \(model.accessibility.status)")
                Text("·  UTF-8  ·  Local")
                if let name = model.presentation.selectedWindow?.name {
                    Text("·").accessibilityHidden(true)
                    Text(name).lineLimit(1).truncationMode(.middle).help(name).accessibilityLabel("Window \(name)")
                }
            }
            .font(.system(size: 11)).foregroundStyle(model.themeColor(.mutedForeground)).padding(.horizontal, 12).frame(height: 28)
            .background(model.themeColor(.surface))
        }
        .foregroundStyle(model.themeColor(.foreground))
        .background(model.usesNativeChrome ? model.themeColor(.surface) : model.themeColor(.background))
        .tint(model.chromeTint)
        .preferredColorScheme(model.effectiveChromeMode.colorScheme)
        .modifier(CommandPaletteHost(model: model))
        .onChange(of: model.tabRenameRequest) { _, _ in
            if let tab = model.presentation.selectedTab { beginTabRename(tab) }
        }
        .onChange(of: model.windowRenameRequest) { _, _ in
            if let window = model.presentation.selectedWindow { beginWindowRename(window) }
        }
        // A cancelled drag leaves its ID behind; starting one in the other list clears it, so a tab over a window row
        // (or a window over the tab bar) never shows a landing bar.
        .onChange(of: draggedTabID) { _, value in if value != nil { draggedWindowID = nil; windowDropTargetID = nil } }
        .onChange(of: draggedWindowID) { _, value in if value != nil { draggedTabID = nil; tabDropTargetID = nil } }
        .onChange(of: model.editingTabID) { _, value in
            if value == nil, let terminal = model.activeTerminal {
                DispatchQueue.main.async { terminal.view.window?.makeFirstResponder(terminal.view) }
            }
        }
        .sheet(item: $windowToRename) { window in
            VStack(alignment: .leading, spacing: 16) {
                Text("Rename Window").font(.headline)
                TextField("Window name", text: $windowName).onSubmit { rename(window) }
                HStack {
                    Spacer()
                    Button("Cancel") { windowToRename = nil }.keyboardShortcut(.cancelAction)
                    Button("Rename") { rename(window) }.keyboardShortcut(.defaultAction)
                }
            }.padding(24).frame(width: 330)
        }
        .sheet(item: Binding(get: { model.pendingPaste }, set: { if $0 == nil { model.cancelPaste() } })) { paste in
            VStack(alignment: .leading, spacing: 14) {
                Text(paste.plan.isPath ? "Review Escaped Path" : "Review Paste").font(.headline)
                Text("Target: \(paste.targetName)").font(.subheadline)
                Text("\(paste.plan.lineCount) line(s) · \(paste.plan.text.utf8.count) bytes · No newline added")
                    .font(.caption).foregroundStyle(model.themeColor(.mutedForeground))
                if paste.plan.unsupportedShell {
                    Text("This shell is not supported for path escaping. POSIX quoting is shown below; check it before pasting as text.")
                        .font(.callout)
                }
                ScrollView {
                    Text(paste.plan.preview).font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }.frame(height: 220).background(model.themeColor(.background))
                Text("Controls appear in ⟨brackets⟩. Changing panes discards this review.")
                    .font(.caption).foregroundStyle(model.themeColor(.mutedForeground))
                HStack {
                    Spacer()
                    Button("Cancel") { model.cancelPaste() }.keyboardShortcut(.cancelAction)
                    Button(paste.plan.unsupportedShell ? "Paste Quoted Text" : "Paste") { model.confirmPaste(paste.id) }
                }
            }.padding(24).frame(width: 540)
        }
        .sheet(item: Binding(get: { model.pendingProjectReview }, set: { if $0 == nil, let id = model.pendingProjectReview?.id { Task { await model.resolveProjectReview(id, .cancel) } } })) {
            ProjectFileReviewView(model: model, review: $0)
        }
        .sheet(item: Binding(get: { model.pendingTaskReview }, set: { if $0 == nil, let id = model.pendingTaskReview?.id { model.resolveTaskReview(id, trust: false) } })) {
            TaskReviewView(model: model, review: $0)
        }
        .sheet(item: Binding(get: { model.pendingProjectSave }, set: { if $0 == nil { model.cancelProjectSave() } })) {
            ProjectFileSaveView(model: model, draft: $0)
        }
        .alert("Trellis", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var sessionStatusColor: Color {
        if model.usesNativeChrome { return .secondary }
        guard let terminal = model.activeTerminal else { return model.themeColor(.mutedForeground) }
        if terminal.sessionState == .failed || (terminal.sessionState == .exited && terminal.exitCode != 0) { return model.themeColor(.error) }
        return model.themeColor(terminal.sessionState == .running ? .success : .mutedForeground)
    }

    private var sidebar: some View {
        Group {
            if model.sidebarCollapsed { collapsedSidebar } else { expandedSidebar }
        }
        .font(.system(size: 12)).padding(.top, 20).padding(.bottom, 14)
        .background(model.themeColor(.sidebarBackground))
    }

    private var sidebarToggle: some View {
        Button {
            model.toggleSidebar()
        } label: {
            Image(systemName: "sidebar.left")
        }
        .buttonStyle(.plain).help(shortcutHelp(model.sidebarCollapsed ? "Show Sidebar" : "Hide Sidebar", .toggleSidebar))
        .accessibilityLabel(model.sidebarCollapsed ? "Show Sidebar" : "Hide Sidebar")
    }

    private var newWindowButton: some View {
        Button {
            Task { await model.createWindow() }
        } label: {
            Image(systemName: "plus")
        }
        .buttonStyle(.plain).help(shortcutHelp("New Window", .newWindow)).accessibilityLabel("New Window")
    }

    private var expandedSidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                sidebarToggle
                Text("WINDOWS").font(.system(size: 10, weight: .semibold)).foregroundStyle(model.themeColor(.mutedForeground))
                    .accessibilityHidden(true)
                Spacer()
                newWindowButton
            }.padding(.horizontal, 10).padding(.bottom, 8)
            ScrollView {
                let descriptors = model.accessibility.windows
                VStack(spacing: 6) {
                    ForEach(model.snapshot.windows) { window in
                        windowRow(window, descriptor: descriptors.first { $0.id == window.id })
                    }
                }.accessibilityElement(children: .contain).accessibilityLabel("Windows")
            }
            Spacer(minLength: 0)
            Divider().overlay(model.separatorOverlay)
            Button {
                model.openHosts?()
            } label: {
                Label("Hosts", systemImage: "server.rack")
            }
            .buttonStyle(.plain).help("Saved SSH hosts").padding(.horizontal, 10).padding(.top, 6)
            Button {
                model.openSettings?()
            } label: {
                Label("Settings", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.plain).help("Settings (⌘,)").padding(.horizontal, 10).padding(.top, 6)
        }
        .padding(.horizontal, 10)
    }

    private var collapsedSidebar: some View {
        VStack(spacing: 10) {
            sidebarToggle.padding(.bottom, 8)
            newWindowButton
            // Padding leaves room for the tile corner markers, which the scroll view would otherwise clip.
            ScrollView {
                let descriptors = model.accessibility.windows
                VStack(spacing: 8) {
                    ForEach(model.snapshot.windows) { window in
                        windowTile(window, descriptor: descriptors.first { $0.id == window.id })
                    }
                }.padding(.vertical, 8).frame(maxWidth: .infinity).accessibilityElement(children: .contain).accessibilityLabel("Windows")
            }.scrollIndicators(.hidden)
            Spacer(minLength: 0)
            Divider().overlay(model.separatorOverlay)
            Button {
                model.openHosts?()
            } label: {
                Image(systemName: "server.rack")
            }
            .buttonStyle(.plain).help("Saved SSH hosts").accessibilityLabel("Hosts")
            Button {
                model.openSettings?()
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(.plain).help("Settings (⌘,)").accessibilityLabel("Settings")
        }
        .frame(maxWidth: .infinity)
    }

    private func windowRow(_ window: ManagedWindow, descriptor: AccessibilityDescriptor?) -> some View {
        let selected = window.id == model.snapshot.activeWindowID
        return Button {
            Task { await model.selectWindow(window.id) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "macwindow").foregroundStyle(model.themeColor(.mutedForeground))
                Text(window.name).lineLimit(1).fontWeight(selected ? .semibold : .regular)
                Spacer()
                if model.windowsNeedingInput.contains(window.id) {
                    Image(systemName: "keyboard").font(.system(size: 10)).help("Waiting for input")
                }
                if model.activity[window.id]?.hasExit == true {
                    Image(systemName: "stop.circle").help("A session exited")
                } else if model.activity[window.id]?.hasOutput == true {
                    Circle().fill(model.themeColor(.accent)).frame(width: 6, height: 6).help("New terminal output")
                }
                Text("\(window.tabIDs.count)").foregroundStyle(model.themeColor(.mutedForeground)).font(.system(size: 10))
            }.padding(.horizontal, 10).padding(.vertical, 8)
                .background(selected ? model.sidebarSelectionBackground : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(windowDrag(window))
        .modifier(WindowItemActions(window: window, descriptor: descriptor, selected: selected, model: model, rename: beginWindowRename))
    }

    private func windowDrag(_ window: ManagedWindow) -> DragReorder {
        DragReorder(
            id: window.id, order: model.snapshot.windows.map(\.id), axis: .vertical, enabled: true, marker: model.themeColor(.accent),
            draggedID: $draggedWindowID, dropTargetID: $windowDropTargetID, onStart: { windowDragStarts += 1 },
            move: { [model] in await model.moveWindow($0, to: $1) })
    }

    private func windowTile(_ window: ManagedWindow, descriptor: AccessibilityDescriptor?) -> some View {
        let selected = window.id == model.snapshot.activeWindowID
        let shape = RoundedRectangle(cornerRadius: 7)
        return Button {
            Task { await model.selectWindow(window.id) }
        } label: {
            Text(WorkspaceAccessibility.initials(for: window.name))
                .font(.system(size: 12, weight: selected ? .bold : .medium)).lineLimit(1).minimumScaleFactor(0.6)
                .foregroundStyle(selected ? AnyShapeStyle(model.accentForeground) : AnyShapeStyle(.foreground))
                .frame(width: 32, height: 32)
                .background(selected ? model.themeColor(.accent) : model.themeColor(.surface), in: shape)
                // Selection is a filled square with bold initials and a border, never color alone.
                .overlay(shape.strokeBorder(selected ? model.themeColor(.accent) : model.themeColor(.border).opacity(0.6), lineWidth: selected ? 2 : 1))
                .overlay(alignment: .bottomTrailing) {
                    if model.windowsNeedingInput.contains(window.id) {
                        Image(systemName: "keyboard.fill").font(.system(size: 8)).foregroundStyle(model.themeColor(.accent))
                            .background(Circle().fill(model.themeColor(.sidebarBackground)).padding(-2)).offset(x: 4, y: 4).help("Waiting for input")
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if model.activity[window.id]?.hasExit == true {
                        Image(systemName: "stop.circle.fill").font(.system(size: 9)).foregroundStyle(model.themeColor(.mutedForeground))
                            .background(Circle().fill(model.themeColor(.sidebarBackground))).offset(x: 4, y: -4).help("A session exited")
                    } else if model.activity[window.id]?.hasOutput == true {
                        Circle().fill(model.themeColor(.accent)).frame(width: 7, height: 7).offset(x: 3, y: -3).help("New terminal output")
                    }
                }
                .contentShape(shape)
        }
        // The hover card carries the full name (FR-W06), so no tooltip competes with it.
        .buttonStyle(.plain)
        .modifier(windowDrag(window))
        .modifier(WindowItemActions(window: window, descriptor: descriptor, selected: selected, model: model, rename: beginWindowRename))
        .modifier(WindowHoverPreview(window: window, model: model, dragStarts: windowDragStarts))
    }

    private func beginWindowRename(_ window: ManagedWindow) {
        windowName = window.name
        windowToRename = window
    }

    private func rename(_ window: ManagedWindow) {
        let name = windowName
        windowToRename = nil
        Task { await model.renameWindow(window.id, name: name) }
    }

    @ViewBuilder private var mainArea: some View {
        if model.isRestoring {
            ProgressView("Restoring workspace…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let message = model.recoveryMessage {
            VStack(spacing: 16) {
                Text("Recover Workspace").font(.title2)
                Text(message).multilineTextAlignment(.center).frame(maxWidth: 430)
                if model.backupAvailable {
                    Button("Use Backup") { Task { await model.recoverWorkspace(useBackup: true) } }
                }
                Button("Start Empty") { Task { await model.recoverWorkspace(useBackup: false) } }
            }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.presentation.isEmpty {
            VStack(spacing: 14) {
                TrellisLogoMark(blinks: !model.reduceMotion).frame(width: 64, height: 64)
                Text("Your terminals, organized.").font(.system(size: 19, weight: .medium))
                // A view's key equivalent runs before the menu's, which the open palette disables (FR-CP02).
                Button("New Window") { Task { await model.createWindow() } }.keyboardShortcut("n").disabled(model.commandPaletteVisible)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(model.themeColor(.background))
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ScrollView(.horizontal) {
                        HStack(spacing: 0) {
                            ForEach(model.presentation.visibleTabs) { tab in
                                tabLabel(tab)
                                Divider().overlay(model.separatorOverlay).frame(height: 20)
                            }
                        }.accessibilityElement(children: .contain).accessibilityLabel("Tabs")
                    }.scrollIndicators(.hidden)
                    Button {
                        Task { await model.createTab() }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.plain).padding(.horizontal, 14).help(shortcutHelp("New Tab", .newTab)).accessibilityLabel("New Tab")
                }.frame(height: 40).background(model.themeColor(.surface))
                Divider().overlay(model.separatorOverlay)
                HStack(spacing: 0) {
                    terminalCanvas
                    if model.scratchpadVisible {
                        scratchpadResizeHandle
                        ScratchpadPanel(model: model, buffer: model.scratchpadBuffer).frame(width: scratchpadWidth)
                    }
                }
            }
        }
    }

    /// Drag to resize the scratchpad; the canvas takes the rest, so split minimums follow (FR-SP01).
    private var scratchpadResizeHandle: some View {
        // A 1-point line, like the other dividers, with a wider invisible grab area over its neighbors.
        Color.clear.frame(width: 7).overlay(model.themeColor(.border).frame(width: 1)).contentShape(Rectangle()).padding(.horizontal, -3).zIndex(1)
            .onHover { inside in
                guard inside != scratchpadCursorPushed else { return }
                scratchpadCursorPushed = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .onDisappear { if scratchpadCursorPushed { scratchpadCursorPushed = false; NSCursor.pop() } }
            .gesture(
                DragGesture(minimumDistance: 1).onChanged { value in
                    let start = scratchpadDragStart ?? scratchpadWidth
                    scratchpadDragStart = start
                    scratchpadWidth = min(max(start - value.translation.width, Self.scratchpadWidths.lowerBound), Self.scratchpadWidths.upperBound)
                }.onEnded { _ in scratchpadDragStart = nil }
            )
            .accessibilityElement().accessibilityLabel("Scratchpad width").accessibilityValue("\(Int(scratchpadWidth)) points")
            .accessibilityAdjustableAction { direction in
                let next = scratchpadWidth + (direction == .increment ? 20 : -20)
                scratchpadWidth = min(max(next, Self.scratchpadWidths.lowerBound), Self.scratchpadWidths.upperBound)
            }
    }

    private func tabLabel(_ tab: WorkspaceTab) -> some View {
        let selected = tab.id == model.presentation.selectedTab?.id
        let busy = model.busyTabIDs.contains(tab.id)
        let wait = model.inputWait(tabID: tab.id)
        let progress = model.progress(tabID: tab.id)
        let descriptor = model.accessibility.tabs.first { $0.id == tab.id }
        let offer = model.projectFileOffer(tabID: tab.id)
        let shownOffer = hoveredTabID == tab.id || selected ? offer : nil
        let parts: [String] = [
            descriptor?.value ?? "", wait?.text.lowercased() ?? "", progress?.spokenText ?? "", busy ? "output in progress" : "",
            offer.map { "workspace \($0.name) available" } ?? ""
        ]
        let value = parts.filter { !$0.isEmpty }.joined(separator: ", ")
        let label = HStack(spacing: 8) {
            Image(systemName: "terminal").font(.system(size: 10)).foregroundStyle(tab.color.map { AnyShapeStyle($0.swatchColor) } ?? AnyShapeStyle(.foreground))
                .accessibilityHidden(true)
            if model.editingTabID == tab.id {
                TextField("Tab name", text: $model.tabRenameDraft)
                    .textFieldStyle(.plain).focused($tabNameFocused)
                    .accessibilityLabel("Tab name")
                    .accessibilityHint("Return saves, Escape cancels")
                    .onAppear { tabNameFocused = true }
                    .onChange(of: model.tabRenameFocusRequest) { _, _ in
                        // The palette's AppKit field took focus without SwiftUI noticing, so `true` alone may change nothing.
                        tabNameFocused = false
                        DispatchQueue.main.async { tabNameFocused = true }
                    }
                    .onSubmit { commitTabRename(tab.id) }
                    .onExitCommand {
                        Task { await model.finishTabRename(tab.id, draft: model.tabRenameDraft, action: .cancel) }
                    }
            } else {
                // Simultaneous double-tap: an exclusive one delays every single click by the double-click interval.
                Text(model.displayTitle(tab)).lineLimit(1)
                    .onTapGesture { Task { await model.selectTab(tab.id) } }
                    .simultaneousGesture(TapGesture(count: 2).onEnded { beginTabRename(tab) })
            }
            if let code = tab.root.paneIDs.lazy.compactMap(model.failedCommandExit(paneID:)).first {
                // A symbol plus spoken text; never color alone (FR-SI04).
                Image(systemName: "exclamationmark.circle").font(.system(size: 10))
                    .help(WorkspaceAccessibility.commandFailureText(code))
                    .accessibilityLabel(WorkspaceAccessibility.commandFailureText(code))
            }
            if let wait {
                // A word in a capsule, not color alone (FR-T06); the tab's value speaks it.
                Label("Input", systemImage: "keyboard").labelStyle(.titleAndIcon).font(.system(size: 10, weight: .medium)).lineLimit(1)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(model.themeColor(.accent).opacity(0.18)))
                    .overlay(Capsule().strokeBorder(model.themeColor(.accent).opacity(0.6), lineWidth: 1))
                    .fixedSize().help(wait.text).accessibilityHidden(true)
            }
            if let progress {
                // The bar's state in words (FR-T09); the tab's value speaks it.
                Text(progress.visibleText).font(.system(size: 10, weight: .medium)).monospacedDigit().lineLimit(1).fixedSize()
                    .foregroundStyle(progress.state == .error ? Color.red : progress.state == .paused ? Color.orange : model.themeColor(.mutedForeground))
                    .accessibilityHidden(true)
            }
            if let shownOffer { ProjectOfferButton(model: model, offer: shownOffer, expanded: hoveredTabID == tab.id) }
            Button {
                Task { await model.closeTab(tab.id) }
            } label: {
                Image(systemName: "xmark").font(.system(size: 9))
            }
            .buttonStyle(.plain).help("Close Tab").accessibilityLabel("Close \(model.displayTitle(tab))")
        }.foregroundStyle(selected ? model.themeColor(.activeTabForeground) : model.themeColor(.foreground))
            .font(.system(size: 12, weight: selected ? .semibold : .regular)).padding(.horizontal, 14).frame(minWidth: 125, maxWidth: 220).frame(height: 40)
            // The tint sits above the opaque active background, so a selected tab keeps it.
            .background(tab.color.map { $0.swatchColor.opacity(selected ? 0.2 : 0.12) } ?? .clear)
            .background(selected ? model.themeColor(.activeTabBackground) : .clear)
            .overlay(alignment: .top) { tabTopEdge(tab, busy: busy, progress: progress) }
            .overlay(alignment: .bottom) {
                if selected { Rectangle().fill(model.themeColor(.accent)).frame(height: model.increaseContrast ? 3 : 2) }
            }
            .contentShape(Rectangle())
        return
            label
            .modifier(TabProjectOffer(model: model, offer: offer, tabID: tab.id, hoveredTabID: $hoveredTabID))
            .modifier(
                DragReorder(
                    id: tab.id, order: model.presentation.visibleTabs.map(\.id), axis: .horizontal, enabled: model.editingTabID != tab.id,
                    marker: model.themeColor(.accent), draggedID: $draggedTabID, dropTargetID: $tabDropTargetID
                ) { await model.moveTab($0, to: $1) }
            )
            .onTapGesture { if model.editingTabID != tab.id { Task { await model.selectTab(tab.id) } } }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(descriptor?.label ?? "Tab \(model.displayTitle(tab))")
            .accessibilityValue(value)
            .accessibilityAddTraits(selected ? [.isSelected, .isButton] : [.isButton])
            .accessibilityAction { Task { await model.selectTab(tab.id) } }
            .accessibilityAction(named: "Rename") { beginTabRename(tab) }
            .accessibilityAction(named: "Move Left") { Task { await model.moveTab(tab.id, offset: -1) } }
            .accessibilityAction(named: "Move Right") { Task { await model.moveTab(tab.id, offset: 1) } }
            .contextMenu {
                TabContextMenu(
                    model: model, tab: tab, canMoveLeft: model.presentation.visibleTabs.first?.id != tab.id,
                    canMoveRight: model.presentation.visibleTabs.last?.id != tab.id, separator: model.separatorOverlay, offer: offer,
                    rename: { beginTabRename(tab) }
                ).equatable()
            }
    }

    /// Progress outranks the busy bar, which outranks the color label stripe.
    @ViewBuilder private func tabTopEdge(_ tab: WorkspaceTab, busy: Bool, progress: TerminalProgress?) -> some View {
        if let progress {
            let fill =
                switch progress.state {
                case .error: Color.red
                case .paused: Color.orange
                default: tab.color?.swatchColor ?? model.themeColor(.accent)
                }
            TabProgressBar(progress: progress, fill: fill, animated: !model.reduceMotion).help("Progress: \(progress.visibleText)")
        } else if busy {
            let fill = tab.color?.swatchColor ?? model.themeColor(.accent)
            TabBusyBar(fill: fill, track: tab.color?.swatchColor.opacity(0.3) ?? .clear, animated: !model.reduceMotion)
                .help(tab.color.map { "Printing output · \($0.displayName) label" } ?? "Printing output")
        } else if let color = tab.color {
            Rectangle().fill(color.swatchColor).frame(height: 3).help("\(color.displayName) label")
        }
    }

    private func beginTabRename(_ tab: WorkspaceTab) {
        Task { await model.beginTabRename(tab.id) }
    }
    private func commitTabRename(_ id: UUID) {
        let draft = model.tabRenameDraft
        Task { await model.finishTabRename(id, draft: draft, action: .commit) }
    }
    private func shortcutHelp(_ title: String, _ action: ShortcutAction) -> String {
        model.keyboard.shortcuts[action].map { "\(title) (\($0))" } ?? title
    }

    private var terminalCanvas: some View {
        GeometryReader { geometry in
            if let tab = model.presentation.selectedTab {
                let fullSize = CanvasDimensions.minimum(for: tab.root).fitting(width: geometry.size.width, height: geometry.size.height)
                let visible = model.maximizedPanes[tab.id].map(PaneLayout.pane) ?? tab.root
                let size = CanvasDimensions.minimum(for: visible).fitting(width: geometry.size.width, height: geometry.size.height)
                ScrollView([.horizontal, .vertical]) {
                    PaneTreeView(model: model, layout: visible, activePaneID: tab.activePaneID, tabID: tab.id)
                        .frame(width: size.width, height: size.height)
                }.background(model.terminalBackground)
                    .onAppear { model.setCanvasSize(fullSize, tabID: tab.id) }
                    .onChange(of: tab.id) { _, _ in model.setCanvasSize(fullSize, tabID: tab.id) }
                    .onChange(of: fullSize) { _, next in model.setCanvasSize(next, tabID: tab.id) }
            } else {
                model.terminalBackground
            }
        }
    }
}

extension TabColor {
    /// Adaptive system colors, so labels stay distinct in light and dark chrome.
    var nsColor: NSColor {
        switch self {
        case .red: .systemRed
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .blue: .systemBlue
        case .purple: .systemPurple
        case .gray: .systemGray
        }
    }
    var swatchColor: Color { Color(nsColor: nsColor) }
    /// Menus render symbols as templates and drop their tint; a drawn, non-template image keeps the color.
    /// One image per color: a fresh image on every redraw makes an open menu look changed, which closes it.
    @MainActor var swatchImage: Image { Self.swatchImages[self]! }

    @MainActor private static let swatchImages: [TabColor: Image] = Dictionary(
        uniqueKeysWithValues: allCases.map { label in
            let color = label.nsColor
            let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
                color.setFill(); NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill(); return true
            }
            image.isTemplate = false
            return (label, Image(nsImage: image))
        })
}

/// Drag reordering of tabs (FR-T10) and windows (FR-W07): the dragged item takes the target's place, so it lands on
/// the side it comes from, where an accent bar marks it. The payload is the item's UUID and the drop reads it back, so
/// text dragged in from another app, the state a cancelled drag leaves behind, or a tab dropped on a window never moves
/// anything. Off while renaming, so a drag in the name field selects text.
private struct DragReorder: ViewModifier {
    let id: UUID
    let order: [UUID]
    let axis: Axis
    let enabled: Bool
    let marker: Color
    @Binding var draggedID: UUID?
    @Binding var dropTargetID: UUID?
    var onStart: () -> Void = {}
    let move: @MainActor @Sendable (UUID, UUID) async -> Void

    private var edge: Alignment? {
        guard dropTargetID == id, let draggedID, draggedID != id, let from = order.firstIndex(of: draggedID), let to = order.firstIndex(of: id) else { return nil }
        return axis == .horizontal ? (from > to ? .leading : .trailing) : (from > to ? .top : .bottom)
    }

    func body(content: Content) -> some View {
        if enabled {
            content
                .overlay(alignment: edge ?? .center) {
                    if edge != nil {
                        Rectangle().fill(marker).frame(width: axis == .horizontal ? 3 : nil, height: axis == .vertical ? 3 : nil).accessibilityHidden(true)
                    }
                }
                .onDrag {
                    draggedID = id; onStart()
                    return NSItemProvider(object: id.uuidString as NSString)
                }
                .onDrop(of: [.text], delegate: ReorderDropDelegate(targetID: id, draggedID: $draggedID, dropTargetID: $dropTargetID, move: move))
        } else {
            content
        }
    }
}

@MainActor private struct ReorderDropDelegate: DropDelegate {
    let targetID: UUID
    @Binding var draggedID: UUID?
    @Binding var dropTargetID: UUID?
    let move: @MainActor @Sendable (UUID, UUID) async -> Void

    func validateDrop(info: DropInfo) -> Bool { draggedID != nil && info.hasItemsConforming(to: [.text]) }
    func dropEntered(info: DropInfo) { dropTargetID = targetID }
    func dropExited(info: DropInfo) { if dropTargetID == targetID { dropTargetID = nil } }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        let dragged = draggedID
        dropTargetID = nil; draggedID = nil
        guard let dragged, let provider = info.itemProviders(for: [.text]).first else { return false }
        let move = move, target = targetID
        // Only the drag this list started: a stale ID from a cancelled drag plus foreign UUID text never moves anything.
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let id = (object as? NSString).flatMap({ UUID(uuidString: $0 as String) }), id == dragged else { return }
            Task { @MainActor in await move(id, target) }
        }
        return true
    }
}

/// The tab's context menu. Equatable on what it shows, so a busy tab redrawing every second (FR-T05) leaves an
/// open menu alone instead of rebuilding and closing it.
private struct TabContextMenu: View, Equatable {
    let model: AppWorkspaceModel
    let tab: WorkspaceTab
    let canMoveLeft: Bool
    let canMoveRight: Bool
    let separator: Color
    let offer: ProjectFileOffer?
    let rename: () -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.tab.id == rhs.tab.id && lhs.tab.color == rhs.tab.color && lhs.canMoveLeft == rhs.canMoveLeft && lhs.canMoveRight == rhs.canMoveRight
            && lhs.separator == rhs.separator && lhs.offer == rhs.offer
    }

    var body: some View {
        Button("Rename…", action: rename)
        Picker("Color", selection: Binding(get: { tab.color }, set: { color in Task { await model.setTabColor(tab.id, color: color) } })) {
            Text("None").tag(TabColor?.none)
            ForEach(TabColor.allCases, id: \.self) { color in
                Label {
                    Text(color.displayName)
                } icon: {
                    color.swatchImage
                }.tag(TabColor?.some(color))
            }
        }
        Button("Duplicate Tab") { Task { await model.createTab(windowID: tab.windowID, duplicate: tab.id) } }
        Button("Move Left") { Task { await model.moveTab(tab.id, offset: -1) } }.disabled(!canMoveLeft)
        Button("Move Right") { Task { await model.moveTab(tab.id, offset: 1) } }.disabled(!canMoveRight)
        if let offer {
            Divider().overlay(separator)
            Button("Load Project “\(offer.name)”") { Task { await model.loadProjectFile(root: offer.root) } }
            Button("Don’t Offer for This Folder") { model.stopOfferingProjectFile(root: offer.root) }
        }
        Divider().overlay(separator)
        Button("Close Tab…") { Task { await model.closeTab(tab.id) } }
    }
}

/// A tab's top edge filling and unfilling while its panes print output (FR-T05). Static under Reduce Motion.
/// The app icon's prompt mark (geometry from `Design/AppIcon/Trellis-small.svg`, 824-unit
/// canvas) with a terminal-style blinking cursor block.
private struct TrellisLogoMark: View {
    let blinks: Bool
    private static let green = Color(red: 0x9C / 255, green: 1, blue: 0x62 / 255)

    var body: some View {
        if blinks {
            TimelineView(.periodic(from: .now, by: 0.53)) { context in
                mark(cursorVisible: Int(context.date.timeIntervalSinceReferenceDate / 0.53).isMultiple(of: 2))
            }
        } else {
            mark(cursorVisible: true)
        }
    }

    private func mark(cursorVisible: Bool) -> some View {
        GeometryReader { geometry in
            let s = min(geometry.size.width, geometry.size.height) / 824
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 185 * s, style: .continuous).fill(Color(red: 0x14 / 255, green: 0x14 / 255, blue: 0x17 / 255))
                RoundedRectangle(cornerRadius: 130 * s, style: .continuous).fill(Color(red: 0x02 / 255, green: 0x03 / 255, blue: 0x02 / 255))
                    .frame(width: 684 * s, height: 684 * s).offset(x: 70 * s, y: 70 * s)
                Path { path in
                    path.move(to: CGPoint(x: 200 * s, y: 300 * s)); path.addLine(to: CGPoint(x: 370 * s, y: 412 * s)); path.addLine(to: CGPoint(x: 200 * s, y: 524 * s))
                }
                .stroke(Self.green, style: StrokeStyle(lineWidth: 86 * s, lineCap: .round, lineJoin: .round))
                .shadow(color: Self.green.opacity(0.6), radius: 22 * s)
                RoundedRectangle(cornerRadius: 10 * s).fill(Self.green).frame(width: 170 * s, height: 280 * s).offset(x: 440 * s, y: 272 * s)
                    .shadow(color: Self.green.opacity(0.6), radius: 22 * s).opacity(cursorVisible ? 1 : 0)
            }
            .frame(width: 824 * s, height: 824 * s)
        }
        .accessibilityElement().accessibilityLabel("Trellis").accessibilityAddTraits(.isImage)
    }
}

private struct TabBusyBar: View {
    let fill: Color
    let track: Color
    let animated: Bool
    @State private var filled = false

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                track
                fill.frame(width: animated ? geometry.size.width * (filled ? 1 : 0.08) : geometry.size.width)
            }
        }
        .frame(height: 3)
        .onAppear { start(animated) }
        .onChange(of: animated) { _, next in start(next) }
    }

    private func start(_ animated: Bool) {
        filled = false
        guard animated else { return }
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { filled = true }
    }
}

/// OSC 9;4 progress along the tab's top edge (FR-T09). Indeterminate sweeps, or fills statically under Reduce Motion.
private struct TabProgressBar: View {
    let progress: TerminalProgress
    let fill: Color
    let animated: Bool
    @State private var swept = false

    private var sweeping: Bool { animated && progress.state == .indeterminate }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                fill.opacity(0.25)
                if sweeping {
                    fill.frame(width: geometry.size.width * 0.3).offset(x: swept ? geometry.size.width * 0.7 : 0)
                } else {
                    fill.frame(width: geometry.size.width * CGFloat(progress.state == .indeterminate ? 100 : progress.percent ?? 100) / 100)
                }
            }
        }
        .frame(height: 3).clipped()
        .onAppear { start(sweeping) }
        .onChange(of: sweeping) { _, next in start(next) }
    }

    private func start(_ sweeping: Bool) {
        swept = false
        guard sweeping else { return }
        withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { swept = true }
    }
}

/// Shared by the expanded row and the collapsed tile so both expose the same
/// VoiceOver description and window commands.
private struct WindowItemActions: ViewModifier {
    let window: ManagedWindow
    let descriptor: AccessibilityDescriptor?
    let selected: Bool
    @ObservedObject var model: AppWorkspaceModel
    let rename: (ManagedWindow) -> Void

    func body(content: Content) -> some View {
        content
            .accessibilityLabel(descriptor?.label ?? window.name)
            .accessibilityValue(descriptor?.value ?? "")
            .accessibilityAddTraits(selected ? [.isSelected] : [])
            .accessibilityAction(named: "Rename") { rename(window) }
            .accessibilityAction(named: "Move Up") { Task { await model.moveWindow(window.id, offset: -1) } }
            .accessibilityAction(named: "Move Down") { Task { await model.moveWindow(window.id, offset: 1) } }
            .contextMenu {
                Button("Rename…") { rename(window) }
                Button("Move Up") { Task { await model.moveWindow(window.id, offset: -1) } }
                    .disabled(model.snapshot.windows.first?.id == window.id)
                Button("Move Down") { Task { await model.moveWindow(window.id, offset: 1) } }
                    .disabled(model.snapshot.windows.last?.id == window.id)
                Button("Save as Project…") { model.beginSaveProjectFile(windowID: window.id) }
                Divider().overlay(model.separatorOverlay)
                Button("Delete Window…", role: .destructive) { Task { await model.deleteWindow(window.id) } }
            }
    }
}

/// Hovering a rail tile opens a card of the window's tabs (FR-W06). A short grace lets the
/// pointer cross from the tile into the card without closing it.
private struct WindowHoverPreview: ViewModifier {
    let window: ManagedWindow
    @ObservedObject var model: AppWorkspaceModel
    let dragStarts: Int
    @State private var presented = false
    @State private var overTile = false
    @State private var overCard = false
    @State private var pending: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover {
                overTile = $0; schedule()
            }
            .accessibilityAction(named: "Show Tabs") { presented = true }
            .popover(isPresented: $presented, arrowEdge: .trailing) {
                WindowTabsPreviewCard(window: window, model: model) { tabID in
                    close()
                    Task { await model.selectWindowTab(windowID: window.id, tabID: tabID) }
                }
                .onHover {
                    overCard = $0; schedule()
                }
            }
            // A card dismissed by an outside click may never report the pointer leaving it.
            .onChange(of: presented) { _, shown in if !shown { overCard = false } }
            .onChange(of: model.sidebarCollapsed) { _, _ in close() }
            // Dragging a window (FR-W07) closes the card and drops a pending open, so it never pops up mid-drag.
            .onChange(of: dragStarts) { _, _ in close() }
            .onDisappear { close() }
    }

    private func schedule() {
        pending?.cancel()
        let open = overTile || overCard
        guard open != presented else { return }
        pending = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(open ? 400 : 250))
            guard !Task.isCancelled, (overTile || overCard) == open else { return }
            presented = open
        }
    }

    private func close() {
        pending?.cancel(); pending = nil
        overTile = false; overCard = false; presented = false
    }
}

private struct WindowTabsPreviewCard: View {
    let window: ManagedWindow
    @ObservedObject var model: AppWorkspaceModel
    let select: (UUID) -> Void

    var body: some View {
        let tabs = model.tabPreviews(windowID: window.id)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(window.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 12)
                Text("\(tabs.count) \(tabs.count == 1 ? "tab" : "tabs")").font(.system(size: 10)).foregroundStyle(model.themeColor(.mutedForeground))
            }.padding(.horizontal, 6).padding(.bottom, 4).accessibilityElement(children: .combine)
            ForEach(tabs) { tab in
                Button {
                    select(tab.id)
                } label: {
                    row(tab)
                }.buttonStyle(.plain)
                    .accessibilityLabel(Self.spoken(tab)).accessibilityAddTraits(tab.isActive ? [.isSelected] : [])
            }
        }
        .padding(10).frame(width: 280, alignment: .leading)
        .foregroundStyle(model.themeColor(.foreground))
        .background(model.themeColor(.surface))
        .accessibilityElement(children: .contain).accessibilityLabel("Tabs in \(window.name)")
    }

    private func row(_ tab: WindowTabPreview) -> some View {
        HStack(spacing: 6) {
            // The active tab is marked by a chevron and weight, never color alone.
            Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).opacity(tab.isActive ? 1 : 0)
            Circle().fill(tab.color?.swatchColor ?? .clear).frame(width: 7, height: 7)
            Text(tab.title).lineLimit(1).fontWeight(tab.isActive ? .semibold : .regular)
            Spacer(minLength: 8)
            if tab.paneCount > 1 { Text("\(tab.paneCount) panes").foregroundStyle(model.themeColor(.mutedForeground)) }
            if let code = tab.failedCommandExit { Label("exit \(code)", systemImage: "exclamationmark.circle").labelStyle(.titleAndIcon) }
            if tab.hasExitedSession { Label("Exited", systemImage: "stop.circle").labelStyle(.titleAndIcon) }
            if let wait = tab.inputWait {
                Label(wait == .password ? "Password" : "Input", systemImage: "keyboard").labelStyle(.titleAndIcon)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(model.themeColor(.accent).opacity(0.18)))
            } else if let progress = tab.progress {
                Label(progress.visibleText, systemImage: progress.state == .error ? "exclamationmark.triangle" : "chart.bar.fill").labelStyle(.titleAndIcon)
                    .monospacedDigit()
            } else if tab.isBusy {
                Label("Busy", systemImage: "waveform").labelStyle(.titleAndIcon).foregroundStyle(model.themeColor(.accent))
            }
        }
        .font(.system(size: 11)).lineLimit(1).padding(.horizontal, 6).padding(.vertical, 5)
        .background(tab.isActive ? model.sidebarSelectionBackground : .clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
    }

    static func spoken(_ tab: WindowTabPreview) -> String {
        var parts = ["Tab \(tab.title)"]
        if tab.isActive { parts.append("active") }
        if let color = tab.color { parts.append("\(color.displayName.lowercased()) label") }
        if tab.paneCount > 1 { parts.append("\(tab.paneCount) panes") }
        if let code = tab.failedCommandExit { parts.append(WorkspaceAccessibility.commandFailureText(code)) }
        if tab.hasExitedSession { parts.append("a session exited") }
        if let wait = tab.inputWait {
            parts.append(wait.text.lowercased())
        } else if let progress = tab.progress {
            parts.append(progress.spokenText)
        } else if tab.isBusy {
            parts.append("output in progress")
        }
        return parts.joined(separator: ", ")
    }
}

struct NativeTerminalSurface: NSViewRepresentable {
    let terminal: NativeTerminal
    var isFocused = true
    func makeNSView(context: Context) -> TerminalContainerView {
        let container = TerminalContainerView()
        container.display(terminal.view, focused: isFocused)
        return container
    }
    func updateNSView(_ view: TerminalContainerView, context: Context) { view.display(terminal.view, focused: isFocused) }
}

/// SwiftUI retains representables across selection changes. Keep a stable host,
/// but explicitly replace its terminal so input always reaches the selected pane.
final class TerminalContainerView: NSView {
    private var wasFocused = false
    private var desiredTerminal: NSView?

    override func layout() {
        super.layout()
        guard let terminal = subviews.first else { return }
        terminal.frame = bounds
        guard let grid = terminal as? TerminalView else { return }
        let gridHeight = grid.getOptimalFrameSize().height
        guard gridHeight > 0, gridHeight <= bounds.height else { return }
        // Keep whole terminal rows against the bottom. A tiny rounding allowance
        // prevents floating-point division from dropping the final row.
        let height = min(bounds.height, gridHeight + 0.001)
        terminal.frame = NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: height)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reconcileAfterTreeUpdate()
    }

    func display(_ terminal: NSView, focused: Bool = true) {
        desiredTerminal = terminal
        let changed = subviews.first !== terminal
        if changed {
            subviews.forEach { $0.removeFromSuperview() }
            terminal.frame = bounds
            terminal.autoresizingMask = [.width, .height]
            addSubview(terminal)
        }
        if focused && (changed || !wasFocused) {
            DispatchQueue.main.async { [weak self, weak terminal] in
                guard let self, let terminal, self.wasFocused, terminal.superview === self,
                    self.window?.isKeyWindow == true
                else { return }
                self.window?.makeFirstResponder(terminal)
            }
        }
        wasFocused = focused
        needsLayout = true
        reconcileAfterTreeUpdate()
    }

    private func reconcileAfterTreeUpdate() {
        // Collapsing a recursive SwiftUI split replaces several representable
        // hosts in one transaction. An old host can update after the new host
        // and temporarily reclaim its cached terminal. Reattach only from the
        // surviving native host once that transaction has finished.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil, let terminal = self.desiredTerminal else { return }
            if terminal.superview !== self {
                self.subviews.forEach { $0.removeFromSuperview() }
                terminal.frame = self.bounds
                terminal.autoresizingMask = [.width, .height]
                self.addSubview(terminal)
                self.needsLayout = true
                if self.wasFocused, self.window?.isKeyWindow == true {
                    self.window?.makeFirstResponder(terminal)
                }
            }
        }
    }
}

public struct LaunchSettingsView: View {
    @ObservedObject private var model: AppWorkspaceModel
    @State private var shell: String
    @State private var directory: String
    @State private var message = ""
    @State private var saving = false
    @State private var customShell: Bool
    @State private var scrollbackLines: Int
    private let shells: [ShellOption]
    private static let customTag = ""
    public init(model: AppWorkspaceModel) {
        self.model = model
        let shells = ShellCatalog.options(current: model.defaultShell)
        self.shells = shells
        _shell = State(initialValue: model.defaultShell)
        _directory = State(initialValue: model.defaultDirectory)
        _customShell = State(initialValue: !shells.contains { $0.path == model.defaultShell })
        _scrollbackLines = State(initialValue: model.appearance.scrollbackLines)
    }
    /// GPU rendering (FR-TX05) and notifications (FR-T08, FR-SI08) are saved with the appearance settings
    /// but apply at once, like the other toggles here.
    private func appearanceSetting<Value>(_ keyPath: WritableKeyPath<AppearanceSettings, Value>) -> Binding<Value> {
        Binding(
            get: { model.appearance[keyPath: keyPath] },
            set: { value in
                var settings = model.appearance
                settings[keyPath: keyPath] = value
                _ = model.applyAppearance(settings)
            })
    }
    private var shellSelection: Binding<String> {
        Binding(
            get: { customShell ? Self.customTag : shell },
            set: { selected in
                customShell = selected == Self.customTag
                if !customShell { shell = selected }
            })
    }
    /// Spoken and visible, not color-only: whether the chosen shell gets integration (FR-SI01).
    private var integrationNote: String {
        let name = (shell as NSString).lastPathComponent
        guard ShellIntegrationKind(executable: shell) != nil else {
            return "\(name.isEmpty ? "This shell" : name) has no shell integration: Trellis won't track its directory or commands."
        }
        return model.shellIntegrationEnabled ? "\(name) supports shell integration." : "\(name) supports shell integration; it's turned off below."
    }
    /// A wrapping caption: the form never grows wider than the pane.
    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(model.themeColor(.mutedForeground)).wrappingSettingsCaption()
    }
    public var body: some View {
        Form {
            Picker("Shell", selection: shellSelection) {
                ForEach(shells) { option in
                    Text(option.integration == nil ? "\(option.name)  —  \(option.path)" : "\(option.name)  —  \(option.path)  ·  Shell integration")
                        .tag(option.path)
                }
                Divider()
                Text("Other…").tag(Self.customTag)
            }.accessibilityIdentifier("settings.shell")
            if customShell {
                TextField("Shell executable", text: $shell).accessibilityIdentifier("settings.shellPath")
            }
            caption(integrationNote).accessibilityIdentifier("settings.shellIntegrationNote")
            TextField("Working directory", text: $directory)
            caption("For new local sessions. Use an absolute path.")
            TextField("Scrollback lines (0–50,000)", value: $scrollbackLines, format: .number.grouping(.never))
                .accessibilityIdentifier("settings.scrollbackLines")
            caption("For every pane, up to 16 MiB of text. Lowering it drops older output.")
            if !message.isEmpty { Text(message).font(.caption).wrappingSettingsCaption().accessibilityIdentifier("settings.result") }
            Toggle(
                "Shell integration (zsh, bash, fish)",
                isOn: Binding(get: { model.shellIntegrationEnabled }, set: { model.setShellIntegrationEnabled($0) })
            ).accessibilityIdentifier("settings.shellIntegration")
            caption("Tracks the directory, commands and prompts without editing your dotfiles. For new sessions.")
            Toggle(
                "Keep sessions running after quit",
                isOn: Binding(get: { model.keepSessionsRunning }, set: { model.setKeepSessionsRunning($0) })
            ).accessibilityIdentifier("settings.keepSessionsRunning")
            caption("New sessions can keep running when you quit and reconnect next time. Closing the window or logging out ends them.")
            Toggle(
                "Restore scrollback after quit",
                isOn: Binding(get: { model.restoreScrollback }, set: { model.setRestoreScrollback($0) })
            ).accessibilityIdentifier("settings.restoreScrollback")
            caption("Shows each pane's last output after relaunch. Saved unencrypted; secrets are removed on a best-effort basis.")
            Toggle("Desktop notifications", isOn: appearanceSetting(\.desktopNotifications)).accessibilityIdentifier("settings.desktopNotifications")
            caption("Shows notifications from programs (OSC 9, 777, 99) when you aren’t looking at their pane.")
            Picker("Notify when a command finishes", selection: appearanceSetting(\.commandFinishedNotificationSeconds)) {
                ForEach(AppearanceSettings.commandFinishedNotificationChoices, id: \.self) { Text($0 == 0 ? "Off" : "After \($0) s").tag($0) }
            }.disabled(!model.appearance.desktopNotifications).accessibilityIdentifier("settings.commandFinishedNotification")
            caption("With shell integration, a long command notifies when it finishes out of view. Only the program name is shown, never the command line.")
            Toggle("GPU rendering (Metal)", isOn: appearanceSetting(\.gpuRendering)).accessibilityIdentifier("settings.gpuRendering")
            caption("Draws terminals with Metal, or with the CPU if Metal fails.")
            HStack {
                Spacer()
                Button("Save") {
                    guard (0...50_000).contains(scrollbackLines) else { message = "Use 0–50,000 scrollback lines."; return }
                    saving = true
                    Task {
                        // Nothing is saved unless the shell and directory are valid.
                        var saved = await model.saveLaunchSettings(shell: shell, directory: directory)
                        if saved {
                            var settings = model.appearance
                            settings.scrollbackLines = scrollbackLines
                            saved = model.applyAppearance(settings)
                        }
                        message = saved ? "Saved." : "Check that the shell is executable and the directory is accessible."
                        saving = false
                    }
                }.disabled(saving)
            }
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            .onChange(of: model.appearance.scrollbackLines) { _, value in scrollbackLines = value }
    }
}

/// A tab’s project offer (FR-WF02): words while hovered, a glyph on a selected tab so it can be found.
private struct ProjectOfferButton: View {
    @ObservedObject var model: AppWorkspaceModel
    let offer: ProjectFileOffer
    let expanded: Bool

    var body: some View {
        Button {
            Task { await model.loadProjectFile(root: offer.root) }
        } label: {
            Group {
                if expanded { Label("Load Project", systemImage: "square.grid.2x2").labelStyle(.titleAndIcon) } else { Image(systemName: "square.grid.2x2") }
            }
            .font(.system(size: 10, weight: .medium)).lineLimit(1).padding(.horizontal, expanded ? 5 : 0).padding(.vertical, 1)
            .background(Capsule().fill(model.themeColor(.accent).opacity(expanded ? 0.18 : 0)))
        }
        .buttonStyle(.plain).fixedSize().help("Load project “\(offer.name)” from \(offer.path)")
        .accessibilityLabel("Load Project \(offer.name)")
    }
}

/// Tracks the hovered tab and offers Load Project to VoiceOver, so the offer never needs a pointer.
private struct TabProjectOffer: ViewModifier {
    let model: AppWorkspaceModel
    let offer: ProjectFileOffer?
    let tabID: UUID
    @Binding var hoveredTabID: UUID?

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                if inside { hoveredTabID = tabID } else if hoveredTabID == tabID { hoveredTabID = nil }
            }
            .accessibilityActions {
                if let offer { Button("Load Project") { Task { await model.loadProjectFile(root: offer.root) } } }
            }
    }
}
