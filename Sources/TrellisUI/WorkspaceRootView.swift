import SwiftUI
import UniformTypeIdentifiers
import TrellisCore
import TrellisTerminal
import class SwiftTerm.TerminalView

public struct WorkspaceRootView: View {
    @ObservedObject private var model: AppWorkspaceModel
    @State private var spaceToRename: Space?
    /// The scratchpad's width; layout only, never persisted.
    @State private var sidebarWidth: CGFloat = 380
    @State private var sidebarDragStart: CGFloat?
    /// Whether the resize cursor is pushed, so it is popped exactly once, also when the panel closes under the mouse.
    @State private var sidebarCursorPushed = false
    static let sidebarWidths: ClosedRange<CGFloat> = 280...640
    @State private var spaceName = ""
    @FocusState private var tabNameFocused: Bool
    @State private var draggedTabID: UUID?
    @State private var tabDropTargetID: UUID?
    @State private var draggedSpaceID: UUID?
    @State private var spaceDropTargetID: UUID?
    @State private var spaceDragStarts = 0
    public init(model: AppWorkspaceModel) { self.model = model }
    public var body: some View {
        VStack(spacing: 0) {
            // Translucent, the window draws no title bar; its edge is a border like the others (FR-TH10).
            if model.panesTranslucent { Divider().overlay(model.separatorOverlay).background(model.translucentChromeBackground) }
            HStack(spacing: 0) {
                sidebar.frame(width: model.sidebarCollapsed ? 52 : 205).animation(.easeInOut(duration: 0.15), value: model.sidebarCollapsed)
                    .disabled(model.isRestoring || model.recoveryMessage != nil)
                Divider().overlay(model.separatorOverlay).background(model.translucentChromeBackground)
                mainArea
            }
            Divider().overlay(model.separatorOverlay).background(model.translucentChromeBackground)
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
                let status = model.accessibility.status
                Text(status).foregroundStyle(sessionStatusColor).accessibilityLabel("Session status \(status)")
                Text("·  UTF-8  ·")
                PaneMachineLabel(machine: model.focusedMachine, model: model)
                if let name = model.presentation.selectedSpace?.name {
                    Text("·").accessibilityHidden(true)
                    HStack(spacing: 4) {
                        Image(systemName: "folder").accessibilityHidden(true)
                        Text(name).lineLimit(1).truncationMode(.middle).help(name).accessibilityLabel("Space \(name)")
                    }
                }
            }
            .font(.system(size: 11)).foregroundStyle(model.themeColor(.mutedForeground)).padding(.horizontal, 12).frame(height: 28)
            .background(model.chromeFill(.surface))
        }
        .foregroundStyle(model.themeColor(.foreground))
        // A zero-height strip on the top edge grows into the title bar's safe area: the title bar's chrome fill.
        .background(alignment: .top) { if model.panesTranslucent { model.chromeFill(.surface).frame(height: 0).ignoresSafeArea(edges: .top) } }
        .background { windowBackground.ignoresSafeArea() }
        .tint(model.chromeTint)
        .preferredColorScheme(model.effectiveChromeMode.colorScheme)
        .modifier(CommandPaletteHost(model: model))
        .modifier(WelcomeTourHost(model: model))
        .onChange(of: model.tabRenameRequest) { _, _ in
            if let tab = model.presentation.selectedTab { beginTabRename(tab) }
        }
        .onChange(of: model.spaceRenameRequest) { _, _ in
            if let space = model.presentation.selectedSpace { beginSpaceRename(space) }
        }
        // A cancelled drag leaves its ID behind; starting one in the other list clears it, so a tab over a space row
        // (or a space over the tab bar) never shows a landing bar.
        .onChange(of: draggedTabID) { _, value in if value != nil { draggedSpaceID = nil; spaceDropTargetID = nil } }
        .onChange(of: draggedSpaceID) { _, value in if value != nil { draggedTabID = nil; tabDropTargetID = nil } }
        .onChange(of: model.editingTabID) { _, value in
            if value == nil, let terminal = model.activeTerminal {
                DispatchQueue.main.async { terminal.view.window?.makeFirstResponder(terminal.view) }
            }
        }
        .sheet(item: $spaceToRename) { space in
            VStack(alignment: .leading, spacing: 16) {
                Text("Rename Space").font(.headline)
                TextField("Space name", text: $spaceName).onSubmit { rename(space) }
                HStack {
                    Spacer()
                    Button("Cancel") { spaceToRename = nil }.keyboardShortcut(.cancelAction)
                    Button("Rename") { rename(space) }.keyboardShortcut(.defaultAction)
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
        .modifier(TaskSheets(model: model))
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
        .background(model.chromeFill(.sidebarBackground))
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

    private var newSpaceButton: some View {
        Button {
            Task { await model.createSpace() }
        } label: {
            Image(systemName: "plus")
        }
        .buttonStyle(.plain).help(shortcutHelp("New Space", .newSpace)).accessibilityLabel("New Space")
    }

    private var expandedSidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                sidebarToggle
                Text("SPACES").font(.system(size: 10, weight: .semibold)).foregroundStyle(model.themeColor(.mutedForeground))
                    .accessibilityHidden(true)
                Spacer()
                newSpaceButton
            }.padding(.horizontal, 10).padding(.bottom, 8)
            ScrollView {
                let descriptors = model.accessibility.spaces
                VStack(spacing: 6) {
                    ForEach(model.snapshot.spaces) { space in
                        spaceRow(space, descriptor: descriptors.first { $0.id == space.id })
                    }
                }.accessibilityElement(children: .contain).accessibilityLabel("Spaces")
            }
            Spacer(minLength: 0)
            Divider().overlay(model.separatorOverlay)
            Button {
                model.openProjects?()
            } label: {
                Label("Projects", systemImage: "folder.badge.gearshape")
            }
            .buttonStyle(.plain).help(model.keyboard.shortcuts[.showProjects].map { "Project library (\($0))" as String } ?? "Project library").padding(.horizontal, 10).padding(.top, 6)
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
            newSpaceButton
            // Padding leaves room for the tile corner markers, which the scroll view would otherwise clip.
            ScrollView {
                let descriptors = model.accessibility.spaces
                VStack(spacing: 8) {
                    ForEach(model.snapshot.spaces) { space in
                        spaceTile(space, descriptor: descriptors.first { $0.id == space.id })
                    }
                }.padding(.vertical, 8).frame(maxWidth: .infinity).accessibilityElement(children: .contain).accessibilityLabel("Spaces")
            }.scrollIndicators(.hidden)
            Spacer(minLength: 0)
            Divider().overlay(model.separatorOverlay)
            Button {
                model.openProjects?()
            } label: {
                Image(systemName: "folder.badge.gearshape")
            }
            .buttonStyle(.plain).help("Project library").accessibilityLabel("Projects")
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

    private func spaceRow(_ space: Space, descriptor: AccessibilityDescriptor?) -> some View {
        let selected = space.id == model.snapshot.activeSpaceID
        return Button {
            Task { await model.selectSpace(space.id) }
        } label: {
            HStack(spacing: 8) {
                let project = model.projectName(of: space)
                Image(systemName: space.remoteHostID != nil ? "server.rack" : project != nil ? "folder" : "macwindow")
                    .foregroundStyle(model.themeColor(.mutedForeground)).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(space.name).lineLimit(1).fontWeight(selected ? .semibold : .regular)
                    // FR-W08: the project this space was loaded from, when it isn't simply its name.
                    if let project, project != space.name {
                        Label(project, systemImage: "folder").font(.caption).foregroundStyle(model.themeColor(.mutedForeground)).lineLimit(1)
                            .help("Loaded from the project \(project)")
                    }
                    // FR-RW16: the link in words and a symbol, never color alone.
                    if let host = space.remoteHostID {
                        let link = model.remoteLinks[host] ?? .disconnected(nil)
                        Label("\(model.remoteHostName(host)) · \(link.label)", systemImage: link.symbol)
                            .font(.caption).foregroundStyle(model.themeColor(.mutedForeground)).lineLimit(1)
                            .help(link == .connected ? "Connected to \(model.remoteHostName(host))" : linkHelp(link))
                    }
                }
                Spacer()
                if model.spacesNeedingInput.contains(space.id) {
                    Image(systemName: "keyboard").font(.system(size: 10)).help("Waiting for input")
                }
                if model.activity[space.id]?.hasExit == true {
                    Image(systemName: "stop.circle").help("A session exited")
                } else if model.activity[space.id]?.hasOutput == true {
                    Circle().fill(model.themeColor(.accent)).frame(width: 6, height: 6).help("New terminal output")
                }
                Text("\(space.tabIDs.count)").foregroundStyle(model.themeColor(.mutedForeground)).font(.system(size: 10))
            }.padding(.horizontal, 10).padding(.vertical, 8)
                .background(selected ? model.sidebarSelectionBackground : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(spaceDrag(space))
        .modifier(SpaceItemActions(space: space, descriptor: descriptor, selected: selected, model: model, rename: beginSpaceRename))
    }

    private func linkHelp(_ link: RemoteLinkDisplay) -> String {
        [link.label, link.detail, link.isUp ? nil : "The space’s menu has Retry Now and Reconnect…."].compactMap { $0 }.joined(separator: " ")
    }

    private func spaceDrag(_ space: Space) -> DragReorder {
        DragReorder(
            id: space.id, order: model.snapshot.spaces.map(\.id), axis: .vertical, enabled: true, marker: model.themeColor(.accent),
            draggedID: $draggedSpaceID, dropTargetID: $spaceDropTargetID, onStart: { spaceDragStarts += 1 },
            move: { [model] in await model.moveSpace($0, to: $1) })
    }

    private func spaceTile(_ space: Space, descriptor: AccessibilityDescriptor?) -> some View {
        let selected = space.id == model.snapshot.activeSpaceID
        let shape = RoundedRectangle(cornerRadius: 7)
        return Button {
            Task { await model.selectSpace(space.id) }
        } label: {
            Text(WorkspaceAccessibility.initials(for: space.name))
                .font(.system(size: 12, weight: selected ? .bold : .medium)).lineLimit(1).minimumScaleFactor(0.6)
                .foregroundStyle(selected ? AnyShapeStyle(model.accentForeground) : AnyShapeStyle(.foreground))
                .frame(width: 32, height: 32)
                .background(selected ? model.themeColor(.accent) : model.themeColor(.surface), in: shape)
                // Selection is a filled square with bold initials and a border, never color alone.
                .overlay(shape.strokeBorder(selected ? model.themeColor(.accent) : model.themeColor(.border).opacity(0.6), lineWidth: selected ? 2 : 1))
                .overlay(alignment: .bottomTrailing) {
                    if model.spacesNeedingInput.contains(space.id) {
                        Image(systemName: "keyboard.fill").font(.system(size: 8)).foregroundStyle(model.themeColor(.accent))
                            .background(Circle().fill(model.themeColor(.sidebarBackground)).padding(-2)).offset(x: 4, y: 4).help("Waiting for input")
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if let host = space.remoteHostID {
                        Image(systemName: (model.remoteLinks[host] ?? .disconnected(nil)).symbol).font(.system(size: 8))
                            .background(Circle().fill(model.themeColor(.sidebarBackground)).padding(-2)).offset(x: -4, y: 4)
                            .help("\(model.remoteHostName(host)) · \((model.remoteLinks[host] ?? .disconnected(nil)).label)")
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if model.activity[space.id]?.hasExit == true {
                        Image(systemName: "stop.circle.fill").font(.system(size: 9)).foregroundStyle(model.themeColor(.mutedForeground))
                            .background(Circle().fill(model.themeColor(.sidebarBackground))).offset(x: 4, y: -4).help("A session exited")
                    } else if model.activity[space.id]?.hasOutput == true {
                        Circle().fill(model.themeColor(.accent)).frame(width: 7, height: 7).offset(x: 3, y: -3).help("New terminal output")
                    }
                }
                .contentShape(shape)
        }
        // The hover card carries the full name (FR-W06), so no tooltip competes with it.
        .buttonStyle(.plain)
        .modifier(spaceDrag(space))
        .modifier(SpaceItemActions(space: space, descriptor: descriptor, selected: selected, model: model, rename: beginSpaceRename))
        .modifier(SpaceHoverPreview(space: space, model: model, dragStarts: spaceDragStarts))
    }

    private func beginSpaceRename(_ space: Space) {
        spaceName = space.name
        spaceToRename = space
    }

    private func rename(_ space: Space) {
        let name = spaceName
        spaceToRename = nil
        Task { await model.renameSpace(space.id, name: name) }
    }

    @ViewBuilder private var mainArea: some View {
        if model.isRestoring {
            ProgressView("Restoring workspace…").frame(maxWidth: .infinity, maxHeight: .infinity).background(model.translucentChromeBackground)
        } else if let message = model.recoveryMessage {
            VStack(spacing: 16) {
                Text("Recover Workspace").font(.title2)
                Text(message).multilineTextAlignment(.center).frame(maxWidth: 430)
                if model.backupAvailable {
                    Button("Use Backup") { Task { await model.recoverWorkspace(useBackup: true) } }
                }
                Button("Start Empty") { Task { await model.recoverWorkspace(useBackup: false) } }
            }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity).background(model.translucentChromeBackground)
        } else if model.presentation.isEmpty {
            VStack(spacing: 14) {
                TrellisLogoMark(blinks: !model.reduceMotion).frame(width: 64, height: 64)
                Text("Your terminals, organized.").font(.system(size: 19, weight: .medium))
                // A view's key equivalent runs before the menu's, which the open palette or tour disables (FR-CP02, FR-ON04).
                Button("New Space") { Task { await model.createSpace() } }.keyboardShortcut("n").disabled(model.commandPaletteVisible || model.welcomeTourVisible)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(model.chromeFill(.background))
        } else {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    tabBar
                    Divider().overlay(model.separatorOverlay).background(model.translucentChromeBackground)
                    HStack(spacing: 0) {
                        if model.reviewVisible, let review = model.currentReview {
                            ReviewTabView(model: model, review: review).frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            terminalCanvas
                        }
                        if let view = model.visibleSidebarView {
                            sidebarResizeHandle
                            RightSidebarPanel(model: model, view: view).frame(width: sidebarWidth)
                        }
                    }
                }
                SidebarDock(model: model)
            }
        }
    }

    private var tabBar: some View {
        // Built once per render: the descriptors cover the whole workspace, so one per tab label made the bar quadratic.
        let descriptors = model.accessibility.tabs
        return HStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(model.presentation.visibleTabs) { tab in
                        tabLabel(tab, descriptor: descriptors.first { $0.id == tab.id })
                        Divider().overlay(model.separatorOverlay).frame(height: 20)
                    }
                    if let review = model.currentReview {
                        reviewTabLabel(review)
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
        }.frame(height: 40).background(model.chromeFill(.surface))
    }

    /// Drag to resize the sidebar, whichever view it shows; the canvas takes the rest, so split minimums follow (FR-SB03).
    private var sidebarResizeHandle: some View {
        // A 1-point line, like the other dividers, with a wider invisible grab area over its neighbors.
        Color.clear.frame(width: 7).overlay(model.themeColor(.border).frame(width: 1)).contentShape(Rectangle()).padding(.horizontal, -3).zIndex(1)
            .onHover { inside in
                guard inside != sidebarCursorPushed else { return }
                sidebarCursorPushed = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .onDisappear { if sidebarCursorPushed { sidebarCursorPushed = false; NSCursor.pop() } }
            .gesture(
                DragGesture(minimumDistance: 1).onChanged { value in
                    let start = sidebarDragStart ?? sidebarWidth
                    sidebarDragStart = start
                    sidebarWidth = min(max(start - value.translation.width, Self.sidebarWidths.lowerBound), Self.sidebarWidths.upperBound)
                }.onEnded { _ in sidebarDragStart = nil }
            )
            .accessibilityElement().accessibilityLabel("Sidebar width").accessibilityValue("\(Int(sidebarWidth)) points")
            .accessibilityAdjustableAction { direction in
                let next = sidebarWidth + (direction == .increment ? 20 : -20)
                sidebarWidth = min(max(next, Self.sidebarWidths.lowerBound), Self.sidebarWidths.upperBound)
            }
    }

    /// The space's Review tab (FR-GC05): after the terminal tabs, never saved, not reorderable.
    private func reviewTabLabel(_ review: ReviewTab) -> some View {
        let selected = model.reviewVisible
        return HStack(spacing: 8) {
            Image(systemName: "plus.forwardslash.minus").font(.system(size: 10)).accessibilityHidden(true)
            Text(review.file.name).lineLimit(1).truncationMode(.middle)
            Button {
                model.closeReview()
            } label: {
                Image(systemName: "xmark").font(.system(size: 9))
            }
            .buttonStyle(.plain).help("Close Review").accessibilityLabel("Close Review of \(review.file.name)")
        }
        .foregroundStyle(selected ? model.themeColor(.activeTabForeground) : model.themeColor(.foreground))
        .font(.system(size: 12, weight: selected ? .semibold : .regular)).padding(.horizontal, 14).frame(minWidth: 125, maxWidth: 240).frame(height: 40)
        .background(selected ? model.themeColor(.activeTabBackground) : .clear)
        .overlay(alignment: .bottom) { if selected { Rectangle().fill(model.themeColor(.accent)).frame(height: model.increaseContrast ? 3 : 2) } }
        .contentShape(Rectangle())
        .onTapGesture { model.showReview() }
        .help("Review: \(review.file.path)")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Review \(review.file.name)")
        .accessibilityValue("diff of \(review.file.path)")
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : [.isButton])
        .accessibilityAction { model.showReview() }
    }

    private func tabLabel(_ tab: WorkspaceTab, descriptor: AccessibilityDescriptor?) -> some View {
        let selected = tab.id == model.presentation.selectedTab?.id && !model.reviewVisible
        let busy = model.busyTabIDs.contains(tab.id)
        let wait = model.inputWait(tabID: tab.id)
        let progress = model.progress(tabID: tab.id)
        let agentBadge = model.agentBadge(tabID: tab.id)
        let agent = model.tabAgent(tabID: tab.id)
        let linkDown = model.tabLinkDown(tabID: tab.id)
        let temporary = model.isTemporaryTab(tab)
        let parts: [String] = [
            descriptor?.value ?? "", temporary ? "temporary tab" : "", linkDown.map { "\($0.hostName), \($0.link.label)" } ?? "", agentBadge.map { "\($0.agent.name) \($0.state.spokenText)" } ?? "",
            wait?.text.lowercased() ?? "", progress?.spokenText ?? "", busy ? "output in progress" : ""
        ]
        let value = parts.filter { !$0.isEmpty }.joined(separator: ", ")
        let label = HStack(spacing: 8) {
            // FR-AG09: a running agent's icon replaces the terminal's, in the same tint.
            Group {
                if let agent, let agentBadge, agentBadge.state == .working {
                    // FR-AG10: no word on the tab while working, so the tooltip names the agent that is (it can differ from the icon's).
                    // A plain reset doesn't stop a repeating animation, so turning on Reduce Motion replaces the view (`id`).
                    AgentBreathingMark(tint: tab.color?.swatchColor ?? model.themeColor(.accent), animated: !model.reduceMotion) {
                        AgentIconView(icon: agent.icon, directory: model.agentCatalog.iconDirectories[agent.id])
                    }.id(model.reduceMotion).help("\(agentBadge.agent.name): \(agentBadge.state.label)")
                } else if let agent {
                    AgentIconView(icon: agent.icon, directory: model.agentCatalog.iconDirectories[agent.id]).help(agent.name)
                } else {
                    Image(systemName: "terminal").font(.system(size: 10))
                }
            }
            .foregroundStyle(tab.color.map { AnyShapeStyle($0.swatchColor) } ?? AnyShapeStyle(.foreground))
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
                // FR-W08: a tab the space's project doesn't define reads as temporary, in italics and in words.
                Text(model.displayTitle(tab)).lineLimit(1).italic(temporary)
                    .help(temporary ? "Temporary tab: not part of this space's project" : "")
                    .onTapGesture { Task { await model.selectTab(tab.id) } }
                    .simultaneousGesture(TapGesture(count: 2).onEnded { beginTabRename(tab) })
            }
            if let linkDown {
                // A symbol beside the red line, never color alone (FR-RW16); the tab's value speaks it.
                Image(systemName: linkDown.link.symbol).font(.system(size: 10)).foregroundStyle(Color.red)
                    .help("\(linkDown.hostName) · \(linkDown.link.label)").accessibilityHidden(true)
            }
            if let code = tab.root.paneIDs.lazy.compactMap(model.failedCommandExit(paneID:)).first {
                // A symbol plus spoken text; never color alone (FR-SI04).
                Image(systemName: "exclamationmark.circle").font(.system(size: 10))
                    .help(WorkspaceAccessibility.commandFailureText(code))
                    .accessibilityLabel(WorkspaceAccessibility.commandFailureText(code))
            }
            switch TabCapsuleKind.resolve(agentState: agentBadge?.state, waitingForInput: wait != nil) {
            case .agent(let state):
                // FR-AG10: the agent's state as a word and symbol; it outranks the generic Input capsule.
                AgentTabBadge(state: state).help("\(agentBadge?.agent.name ?? ""): \(state.label)")
            case .input:
                // A word in a capsule, not color alone (FR-T06); the tab's value speaks it.
                Label("Input", systemImage: "keyboard").labelStyle(.titleAndIcon).font(.system(size: 10, weight: .medium)).lineLimit(1)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(model.themeColor(.accent).opacity(0.18)))
                    .overlay(Capsule().strokeBorder(model.themeColor(.accent).opacity(0.6), lineWidth: 1))
                    .fixedSize().help(wait?.text ?? "").accessibilityHidden(true)
            case nil:
                EmptyView()
            }
            if let progress {
                // The bar's state in words (FR-T09); the tab's value speaks it.
                Text(progress.visibleText).font(.system(size: 10, weight: .medium)).monospacedDigit().lineLimit(1).fixedSize()
                    .foregroundStyle(progress.state == .error ? Color.red : progress.state == .paused ? Color.orange : model.themeColor(.mutedForeground))
                    .accessibilityHidden(true)
            }
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
            .overlay(alignment: .top) { tabTopEdge(tab, busy: busy, progress: progress, agentState: agentBadge?.state) }
            .overlay(alignment: .bottom) {
                // Every tab on a host that's down, selected or not, until its panes are back (FR-RW07).
                if selected || linkDown != nil { Rectangle().fill(linkDown != nil ? Color.red : model.themeColor(.accent)).frame(height: model.increaseContrast ? 3 : 2) }
            }
            .contentShape(Rectangle())
        return
            label
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
                    canMoveRight: model.presentation.visibleTabs.last?.id != tab.id, separator: model.separatorOverlay,
                    rename: { beginTabRename(tab) }
                ).equatable()
            }
    }

    /// Progress outranks a working agent's thread, then the busy bar, then the color label stripe.
    @ViewBuilder private func tabTopEdge(_ tab: WorkspaceTab, busy: Bool, progress: TerminalProgress?, agentState: AgentState?) -> some View {
        let fill = tab.color?.swatchColor ?? model.themeColor(.accent)
        switch TabTopEdgeKind.resolve(hasProgress: progress != nil, agentState: agentState, busy: busy, hasLabel: tab.color != nil) {
        case .progress:
            if let progress {
                let barFill =
                    switch progress.state {
                    case .error: Color.red
                    case .paused: Color.orange
                    default: fill
                    }
                TabProgressBar(progress: progress, fill: barFill, animated: !model.reduceMotion).help("Progress: \(progress.visibleText)")
            }
        case .agentWorking:
            TabAgentThread(fill: fill, animated: !model.reduceMotion)
        case .busy:
            TabBusyBar(fill: fill, track: tab.color?.swatchColor.opacity(0.3) ?? .clear, animated: !model.reduceMotion)
                .help(tab.color.map { "Printing output · \($0.displayName) label" } ?? "Printing output")
        case .label:
            Rectangle().fill(fill).frame(height: 3).help(tab.color.map { "\($0.displayName) label" } ?? "")
        case nil:
            EmptyView()
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
                }.background(canvasBackground)
                    .onAppear { model.setCanvasSize(fullSize, tabID: tab.id) }
                    .onChange(of: tab.id) { _, _ in model.setCanvasSize(fullSize, tabID: tab.id) }
                    .onChange(of: fullSize) { _, next in model.setCanvasSize(next, tabID: tab.id) }
            } else {
                canvasBackground
            }
        }
    }
    /// Translucent panes paint their own margins and background (FR-TH10); the window's blur is under them.
    @ViewBuilder private var canvasBackground: some View {
        if model.panesTranslucent { Color.clear } else { model.terminalBackground }
    }
    /// Translucent: one blur behind the whole window, so chrome and panes frost the desktop alike (FR-TH10).
    @ViewBuilder private var windowBackground: some View {
        if !model.panesTranslucent {
            model.chromeBackground
        } else if model.effectiveBackgroundBlur {
            BehindWindowBlur()
        } else {
            Color.clear
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

/// Drag reordering of tabs (FR-T10) and spaces (FR-W07): the dragged item takes the target's place, so it lands on
/// the side it comes from, where an accent bar marks it. The payload is the item's UUID and the drop reads it back, so
/// text dragged in from another app, the state a cancelled drag leaves behind, or a tab dropped on a space never moves
/// anything. Off while renaming, so a drag in the name field selects text.
/// The task review (FR-TK06) and project launch (FR-PL06) sheets, apart so the root's modifier chain type-checks.
private struct TaskSheets: ViewModifier {
    @ObservedObject var model: AppWorkspaceModel

    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(get: { model.pendingTaskReview }, set: { if $0 == nil, let id = model.pendingTaskReview?.id { model.resolveTaskReview(id, trust: false) } })) {
                TaskReviewView(model: model, review: $0)
            }
            .sheet(item: Binding(get: { model.projectLaunch }, set: { if $0 == nil, let session = model.projectLaunch { model.cancelProjectLaunch(session) } })) {
                ProjectLaunchSheet(model: model, session: $0)
            }
            .sheet(item: $model.agentInstallOffer) { AgentInstallSheet(model: model, offer: $0) }
    }
}

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
    let rename: () -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.tab.id == rhs.tab.id && lhs.tab.color == rhs.tab.color && lhs.canMoveLeft == rhs.canMoveLeft && lhs.canMoveRight == rhs.canMoveRight
            && lhs.separator == rhs.separator
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
        Button("Duplicate Tab") { Task { await model.createTab(spaceID: tab.spaceID, duplicate: tab.id) } }
        Button("Move Left") { Task { await model.moveTab(tab.id, offset: -1) } }.disabled(!canMoveLeft)
        Button("Move Right") { Task { await model.moveTab(tab.id, offset: 1) } }.disabled(!canMoveRight)
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

/// A working agent along the tab's top edge (FR-AG10): a light sweeps over a faint track, or a full bar under Reduce Motion.
/// Taller than the bar only so its glow shows inside the tab; it takes no clicks, and the icon carries the tooltip.
private struct TabAgentThread: View {
    let fill: Color
    let animated: Bool
    @State private var swept = false

    var body: some View {
        GeometryReader { geometry in
            let comet = geometry.size.width * 0.4
            ZStack(alignment: .leading) {
                fill.opacity(0.18)
                if animated {
                    LinearGradient(stops: [.init(color: fill.opacity(0), location: 0), .init(color: fill, location: 0.7), .init(color: .white, location: 1)], startPoint: .leading, endPoint: .trailing)
                        .frame(width: comet).shadow(color: fill, radius: 3)
                        .offset(x: swept ? geometry.size.width : -comet)
                } else {
                    fill
                }
            }
            .frame(height: 3)
        }
        .frame(height: 9, alignment: .top).clipped().allowsHitTesting(false)
        .onAppear { start(animated) }
        .onChange(of: animated) { _, next in start(next) }
    }

    private func start(_ animated: Bool) {
        swept = false
        guard animated else { return }
        withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: false)) { swept = true }
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
/// VoiceOver description and space commands.
private struct SpaceItemActions: ViewModifier {
    let space: Space
    let descriptor: AccessibilityDescriptor?
    let selected: Bool
    @ObservedObject var model: AppWorkspaceModel
    let rename: (Space) -> Void

    /// FR-RW16: VoiceOver hears the host and its link, for example "build-box, Disconnected".
    private var value: String {
        guard let host = space.remoteHostID else { return descriptor?.value ?? "" }
        let state = model.remoteLinks[host] ?? .disconnected(nil)
        let link = ["\(model.remoteHostName(host)), \(state.label)", state.detail].compactMap { $0 }.joined(separator: ". ")
        return [descriptor?.value, link].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private var canReconnect: Bool {
        guard let host = space.remoteHostID else { return false }
        return !(model.remoteLinks[host] ?? .disconnected(nil)).isUp
    }

    func body(content: Content) -> some View {
        content
            .accessibilityLabel(descriptor?.label ?? space.name)
            .accessibilityValue(value)
            .accessibilityAddTraits(selected ? [.isSelected] : [])
            .accessibilityAction(named: "Retry Now") { if canReconnect, let host = space.remoteHostID { model.remoteReconnector.retryNow(host) } }
            .accessibilityAction(named: "Reconnect") { if canReconnect, let host = space.remoteHostID { Task { await model.reconnectRemote(hostID: host) } } }
            .accessibilityAction(named: "Rename") { rename(space) }
            .accessibilityAction(named: "Move Up") { Task { await model.moveSpace(space.id, offset: -1) } }
            .accessibilityAction(named: "Move Down") { Task { await model.moveSpace(space.id, offset: 1) } }
            .contextMenu {
                if let host = space.remoteHostID {
                    // Retry Now never prompts; Reconnect… lets ssh ask for a password or a host-key decision (FR-RW07).
                    Button("Retry Now") { model.remoteReconnector.retryNow(host) }.disabled(!canReconnect)
                    Button("Reconnect to \(model.remoteHostName(host))…") { Task { await model.reconnectRemote(hostID: host) } }.disabled(!canReconnect)
                    Divider().overlay(model.separatorOverlay)
                }
                Button("Rename…") { rename(space) }
                Button("Move Up") { Task { await model.moveSpace(space.id, offset: -1) } }
                    .disabled(model.snapshot.spaces.first?.id == space.id)
                Button("Move Down") { Task { await model.moveSpace(space.id, offset: 1) } }
                    .disabled(model.snapshot.spaces.last?.id == space.id)
                Divider().overlay(model.separatorOverlay)
                Button("Delete Space…", role: .destructive) { Task { await model.deleteSpace(space.id) } }
            }
    }
}

/// Hovering a rail tile opens a card of the space's tabs (FR-W06). A short grace lets the
/// pointer cross from the tile into the card without closing it.
private struct SpaceHoverPreview: ViewModifier {
    let space: Space
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
            // Not `.popover`: a transient popover swallows the click that dismisses it, so tabs, Settings and Hosts
            // ignored the first click while a card was up.
            .background(PassThroughPopoverAnchor(presented: $presented, edge: .maxX, content: AnyView(card)))
            // A card dismissed by an outside click may never report the pointer leaving it.
            .onChange(of: presented) { _, shown in if !shown { overCard = false } }
            .onChange(of: model.sidebarCollapsed) { _, _ in close() }
            // Dragging a space (FR-W07) closes the card and drops a pending open, so it never pops up mid-drag.
            .onChange(of: dragStarts) { _, _ in close() }
            .onDisappear { close() }
    }

    private var card: some View {
        SpaceTabsPreviewCard(space: space, model: model) { tabID in
            close()
            Task { await model.selectSpaceTab(spaceID: space.id, tabID: tabID) }
        }
        .onHover {
            overCard = $0; schedule()
        }
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

private struct SpaceTabsPreviewCard: View {
    let space: Space
    @ObservedObject var model: AppWorkspaceModel
    let select: (UUID) -> Void

    var body: some View {
        let tabs = model.tabPreviews(spaceID: space.id)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(space.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
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
        .accessibilityElement(children: .contain).accessibilityLabel("Tabs in \(space.name)")
    }

    private func row(_ tab: SpaceTabPreview) -> some View {
        HStack(spacing: 6) {
            // The active tab is marked by a chevron and weight, never color alone.
            Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).opacity(tab.isActive ? 1 : 0)
            Circle().fill(tab.color?.swatchColor ?? .clear).frame(width: 7, height: 7)
            if let agent = tab.agent { AgentIconView(icon: agent.icon, directory: tab.agentIconDirectory).accessibilityHidden(true) }
            Text(tab.title).lineLimit(1).fontWeight(tab.isActive ? .semibold : .regular)
            Spacer(minLength: 8)
            if tab.paneCount > 1 { Text("\(tab.paneCount) panes").foregroundStyle(model.themeColor(.mutedForeground)) }
            if let code = tab.failedCommandExit { Label("exit \(code)", systemImage: "exclamationmark.circle").labelStyle(.titleAndIcon) }
            if tab.hasExitedSession { Label("Exited", systemImage: "stop.circle").labelStyle(.titleAndIcon) }
            // A working agent reads as busy, like any tab printing output; only states that need a look get a capsule.
            if tab.agentState == .working {
                BusyLabel(color: model.themeColor(.accent))
            } else if let state = tab.agentState {
                AgentTabBadge(state: state)
            } else if let wait = tab.inputWait {
                Label(wait == .password ? "Password" : "Input", systemImage: "keyboard").labelStyle(.titleAndIcon)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(model.themeColor(.accent).opacity(0.18)))
            } else if let progress = tab.progress {
                Label(progress.visibleText, systemImage: progress.state == .error ? "exclamationmark.triangle" : "chart.bar.fill").labelStyle(.titleAndIcon)
                    .monospacedDigit()
            } else if tab.isBusy {
                BusyLabel(color: model.themeColor(.accent))
            }
        }
        .font(.system(size: 11)).lineLimit(1).padding(.horizontal, 6).padding(.vertical, 5)
        .background(tab.isActive ? model.sidebarSelectionBackground : .clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
    }

    static func spoken(_ tab: SpaceTabPreview) -> String {
        var parts = ["Tab \(tab.title)"]
        if tab.isActive { parts.append("active") }
        if let color = tab.color { parts.append("\(color.displayName.lowercased()) label") }
        if tab.paneCount > 1 { parts.append("\(tab.paneCount) panes") }
        if let code = tab.failedCommandExit { parts.append(WorkspaceAccessibility.commandFailureText(code)) }
        if tab.hasExitedSession { parts.append("a session exited") }
        if let name = tab.agentStateName, let state = tab.agentState {
            parts.append("\(name) \(state.spokenText)")
        } else if let wait = tab.inputWait {
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
    /// The strips above and below the rows, painted with the terminal's background: under a translucent background
    /// (FR-TH10) nothing else paints them, so they would show as lighter bands.
    let gapAbove = NSView(), gapBelow = NSView()
    private var gaps: [NSView] { [gapAbove, gapBelow] }
    private var backgroundObservation: NSKeyValueObservation?
    private var hostedTerminal: NSView? { subviews.first { view in !gaps.contains { $0 === view } } }

    override func layout() {
        super.layout()
        gaps.forEach { $0.isHidden = true }
        guard let terminal = hostedTerminal else { return }
        terminal.frame = bounds
        guard let grid = terminal as? TerminalView else { return }
        let gridHeight = grid.getOptimalFrameSize().height
        guard gridHeight > 0, gridHeight <= bounds.height else { return }
        // Whole rows only, with the remainder of a row split evenly above and below them, so the top and bottom
        // padding always match. A tiny rounding allowance prevents floating-point division from dropping the final row.
        let height = min(bounds.height, gridHeight + 0.001)
        let below = ((bounds.height - height) / 2).rounded(.down)
        terminal.frame = NSRect(x: bounds.minX, y: bounds.minY + below, width: bounds.width, height: height)
        gapBelow.frame = NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: below)
        gapAbove.frame = NSRect(x: bounds.minX, y: terminal.frame.maxY, width: bounds.width, height: max(0, bounds.maxY - terminal.frame.maxY))
        gaps.forEach { $0.isHidden = $0.frame.height <= 0 }
        paintRowGaps()
    }
    private func attach(_ terminal: NSView) {
        subviews.forEach { $0.removeFromSuperview() }
        terminal.frame = bounds
        terminal.autoresizingMask = [.width, .height]
        addSubview(terminal)
        gaps.forEach { addSubview($0) }
        // Themes, previews, opacity and OSC 11 all set the grid's layer background; follow them.
        terminal.wantsLayer = true
        backgroundObservation = terminal.layer?.observe(\.backgroundColor) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.paintRowGaps() }
        }
    }
    private func paintRowGaps() {
        guard let grid = hostedTerminal as? TerminalView else { return }
        for gap in gaps {
            gap.wantsLayer = true
            // The native color carries the opacity; the grid's own layer is clear while Metal draws.
            gap.layer?.backgroundColor = grid.nativeBackgroundColor.cgColor
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reconcileAfterTreeUpdate()
    }

    func display(_ terminal: NSView, focused: Bool = true) {
        desiredTerminal = terminal
        let changed = subviews.first !== terminal
        if changed { attach(terminal) }
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
                self.attach(terminal)
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
                "Remember directories",
                isOn: Binding(get: { model.directoryHistoryEnabled }, set: { model.setDirectoryHistoryEnabled($0) })
            ).accessibilityIdentifier("settings.directoryHistory")
            caption("Lists where your shells have been under Jump to Directory (⌘J). Kept on this Mac; system, credential and network folders are skipped.")
            // Always enabled: a backup or set-aside copy can hold paths while the list is empty (FR-DJ08).
            Button("Clear Directory History…") { Task { await model.clearDirectoryHistory() } }
                .accessibilityIdentifier("settings.clearDirectoryHistory")
            Toggle(
                "Stop sessions when Trellis quits",
                isOn: Binding(get: { !model.keepSessionsRunning }, set: { model.setKeepSessionsRunning(!$0) })
            ).accessibilityIdentifier("settings.stopSessionsOnQuit")
            caption(
                model.keepSessionsRunning
                    ? "Sessions run in a background helper: they keep running when you quit, close the window or Trellis stops unexpectedly, and reconnect next time. Logging out or restarting ends them."
                    : "Quitting or closing the window stops every session. Sessions still survive if Trellis stops unexpectedly.")
            if model.sessionDefaultNoticePending {
                caption("New: sessions now keep running after quit by default. Turn this on to stop them when Trellis quits.")
                    .accessibilityIdentifier("settings.sessionDefaultNotice")
                    .onDisappear { model.dismissSessionDefaultNotice() }
            }
            Toggle(
                "Restore scrollback after quit",
                isOn: Binding(get: { model.restoreScrollback }, set: { model.setRestoreScrollback($0) })
            ).accessibilityIdentifier("settings.restoreScrollback")
            caption("Shows each pane's last output after relaunch. Saved unencrypted; secrets are removed on a best-effort basis.")
            Picker(
                "Workspace disk writes",
                selection: Binding(get: { model.saveBudgetMegabytesPerHour }, set: { model.setSaveBudget(megabytesPerHour: $0) })
            ) {
                ForEach(WorkspaceWriteBudget.choices, id: \.self) { Text("Up to \($0) MB per hour").tag($0) }
            }.accessibilityIdentifier("settings.saveBudget")
            caption(
                model.savesThrottled
                    ? "Limit reached: changes are now saved together every 5 minutes. Quit and ⌘S still save at once."
                    : "Past this, changes to spaces, tabs and settings are saved together every 5 minutes instead of right away."
            ).accessibilityIdentifier("settings.saveBudgetNote")
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
