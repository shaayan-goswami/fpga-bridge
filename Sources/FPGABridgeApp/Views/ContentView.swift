import FPGABridgeCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var hardware: HardwareManager

    var body: some View {
        Group {
            if model.hasProject {
                MainWindowView()
            } else {
                QuickStartView()
            }
        }
        .allowsFullScreen(model.hasProject)
        .sheet(isPresented: $model.showNewProject) {
            NewProjectWizard().environmentObject(model)
        }
        .sheet(isPresented: $model.showSettings) {
            ProjectSettingsView().environmentObject(model)
        }
        .sheet(isPresented: $model.showAddSources) {
            AddSourcesSheet().environmentObject(model)
        }
        .sheet(item: Binding(get: { hardware.sheetHost == "main" ? hardware.sheet : nil }, set: { hardware.sheet = $0 })) { kind in
            ProgramDeviceSheet(kind: kind).environmentObject(model).environmentObject(model.hardware)
        }
        .alert(model.unsavedPrompt?.title ?? "", isPresented: Binding(
            get: { model.unsavedPrompt != nil },
            set: { _ in }  // every button resolves the prompt itself
        )) {
            Button("Save") { model.resolveUnsaved(.save) }
                .keyboardShortcut(.defaultAction)
            Button("Don't Save", role: .destructive) { model.resolveUnsaved(.discard) }
            Button("Cancel", role: .cancel) { model.resolveUnsaved(.cancel) }
        } message: {
            Text("Your changes will be lost if you don't save them.")
        }
        .alert("FPGA Bridge", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

/// Vivado's layout: Flow Navigator | Sources + Properties | workspace over the console, with a status bar.
struct MainWindowView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showSidebar = true
    @State private var sidebarWidth: CGFloat = 250
    @State private var sourcesWidth: CGFloat = 330
    @State private var consoleHeight: CGFloat = 240

    /// Three panes like Vivado's: Flow Navigator, Sources, workspace over console. The sidebar has no background of
    /// its own, so it shows the window's Liquid Glass, the same glass as the home screen. (The system's split view
    /// draws its own sidebar on top, which never matched.) Every other pane is opaque.
    var body: some View {
        // The toolbar has no background, so the panes would otherwise extend under it and draw their edges through
        // it. Read the toolbar's height and keep everything below it; the area above shows the window glass.
        GeometryReader { geometry in
            VStack(spacing: 0) {
                // Plain stacks with our own drag handles: the system's HSplitView draws its dividers through the toolbar.
                HStack(spacing: 0) {
                    if showSidebar {
                        FlowNavigatorView().frame(width: sidebarWidth)
                        PaneDivider(width: $sidebarWidth, range: 220...320, showsLine: false)
                    }
                    SourcesPane()
                        .frame(width: sourcesWidth)
                        // Fills up under the toolbar too, so only the sidebar shows the window glass there.
                        .background(Theme.surface)
                    PaneDivider(width: $sourcesWidth, range: 280...460)
                    VerticalPaneSplit(height: $consoleHeight, range: 160...420, minTop: 380, showsBottom: model.consoleVisible) {
                        WorkspaceView()
                    } bottom: {
                        ConsolePanel()
                    }
                    .background(Theme.surface)
                }
                StatusBar()
            }
            .padding(.top, geometry.safeAreaInsets.top)
            .ignoresSafeArea(.container, edges: .top)
        }
        .modifier(WindowGlassContainers())
        .navigationTitle(model.project?.name ?? "FPGA Bridge")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { showSidebar.toggle() } label: { Label("Flow Navigator", systemImage: "sidebar.leading") }
                    .help(showSidebar ? "Hide the Flow Navigator" : "Show the Flow Navigator")
            }
            MainToolbar(model: model)
        }
    }

    private var subtitle: String {
        guard let project = model.project else { return "" }
        let board = project.board.flatMap { BoardCatalog.lookup($0)?.displayName }
        return [board, project.part].compactMap { $0 }.joined(separator: " · ")
    }
}

struct MainToolbar: ToolbarContent {
    @ObservedObject var model: AppModel

    var body: some ToolbarContent {
        if #available(macOS 26.0, *) {
            // The activity banner draws its own glass capsule, so hide the toolbar's shared glass behind it.
            ToolbarItem(placement: .principal) {
                ActivityView(model: model)
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .principal) {
                ActivityView(model: model)
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button("Run Synthesis") { model.run(.synthesis) }
                Button("Run Implementation") { model.run(.implementation) }
                Button("Generate Bitstream") { model.run(.bitstream) }
                Divider()
                Button("Reset Runs") { model.resetRuns() }
            } label: {
                Label("Run", systemImage: "play.fill")
            } primaryAction: {
                model.run(.bitstream)
            }
            .help("Generate Bitstream. Runs synthesis and implementation first if they are out-of-date.")
            .disabled(model.isRunning)

            Button { model.stop() } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .help(model.backend.canStop ? "Stop the running step" : "Stopping a live build from the app isn't supported yet")
            .disabled(!model.canStop)

            Button { model.consoleVisible.toggle() } label: {
                Label("Console", systemImage: "rectangle.bottomthird.inset.filled")
            }
            .help(model.consoleVisible ? "Hide the console" : "Show the console")

            ConnectionPill(model: model)
        }
    }
}

/// The Xcode-style activity area in the middle of the toolbar.
struct ActivityView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if model.isRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: symbol).foregroundStyle(color)
                }
            }
            .frame(width: 16)
            Text(model.lastMessage)
                .lineLimit(1)
            Spacer(minLength: 8)
            if model.isRunning, let start = model.stepStarted {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(formatDuration(context.date.timeIntervalSince(start)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            } else if let summary = model.timing, model.lastOutcome == .complete {
                Text("WNS \(formatSigned(summary.wns)) ns")
                    .monospacedDigit()
                    .foregroundStyle(summary.constraintsMet ? Color.secondary : Accent.error)
            }
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .frame(width: 440, height: 30)
        .glassSurface(Capsule())
    }

    private var symbol: String {
        switch model.lastOutcome {
        case .complete: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .cancelled: "stop.circle.fill"
        default: "circle.dashed"
        }
    }

    private var color: Color {
        switch model.lastOutcome {
        case .complete: Accent.success
        case .failed: Accent.error
        default: .secondary
        }
    }
}

struct ConnectionPill: View {
    @ObservedObject var model: AppModel
    @State private var showDetails = false

    var body: some View {
        Button { showDetails.toggle() } label: {
            HStack(spacing: 6) {
                Circle().fill(model.connection.color).frame(width: 8, height: 8)
                Text(model.connection.label)
            }
            .padding(.horizontal, 4)
        }
        .help(model.connection.detail)
        .popover(isPresented: $showDetails, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Label("Build Machine", systemImage: "desktopcomputer").font(.headline)
                Text(model.connection.detail)
                    .fixedSize(horizontal: false, vertical: true)
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                    InfoRow(label: "Host", value: model.backend.hostName)
                    InfoRow(label: "Vivado", value: model.backend.vivadoPath ?? "—", monospaced: true)
                }
                HStack {
                    Spacer()
                    Button("Check Again") { Task { await model.start() } }
                }
            }
            .padding(16)
            .frame(width: 340)
        }
    }
}

struct StatusBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Text(model.lastMessage)
            Spacer()
            if let project = model.project {
                Text(project.part).monospaced()
                Divider().frame(height: 12)
                Text("Vivado \(project.vivadoVersion ?? model.backend.vivadoPath.flatMap(Project.version(in:)) ?? "—")")
                Divider().frame(height: 12)
            }
            HStack(spacing: 5) {
                Circle().fill(model.connection.color).frame(width: 6, height: 6)
                Text(model.connection.label)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 24)
        .barBackground()
        .overlay(alignment: .top) { Divider() }
    }
}

/// Makes the window itself Liquid Glass, as on the home screen, with no toolbar background of its own (macOS 15+).
/// Only the sidebar and the toolbar area show it; older systems keep the defaults.
private struct WindowGlassContainers: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .containerBackground(for: .window) { GlassFill(solid: Theme.sidebar) }
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            content
        }
    }
}

/// Two panes stacked with a draggable divider, the bottom one a fixed height you can change. Plain SwiftUI: the
/// system's VSplitView hosts its panes in an AppKit split view, which can keep a stale frame after the window moves.
struct VerticalPaneSplit<Top: View, Bottom: View>: View {
    @Binding var height: CGFloat
    let range: ClosedRange<CGFloat>
    var minTop: CGFloat = 0
    var showsBottom = true
    @ViewBuilder let top: () -> Top
    @ViewBuilder let bottom: () -> Bottom
    @State private var startHeight: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let limit = max(range.lowerBound, min(range.upperBound, geometry.size.height - minTop - 1))
            let bottomHeight = min(max(height, range.lowerBound), limit)
            VStack(spacing: 0) {
                top().frame(maxWidth: .infinity, maxHeight: .infinity)
                if showsBottom {
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor))
                        .frame(height: 1)
                        .overlay {
                            Color.clear
                                .frame(height: 9)
                                .contentShape(Rectangle())
                                .onHover { inside in
                                    if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                                }
                                .gesture(
                                    DragGesture(minimumDistance: 1, coordinateSpace: .global)
                                        .onChanged { drag in
                                            let base = startHeight ?? height
                                            startHeight = base
                                            height = min(max(base - drag.translation.height, range.lowerBound), limit)
                                        }
                                        .onEnded { _ in startHeight = nil }
                                )
                        }
                    bottom().frame(height: bottomHeight)
                }
            }
        }
    }
}

/// A thin line between two panes that can be dragged to resize the pane on its left. Without the line, the two panes'
/// own colors mark the edge, which is cleaner where one is the gray sidebar and the other is black.
private struct PaneDivider: View {
    @Binding var width: CGFloat
    let range: ClosedRange<CGFloat>
    var showsLine = true
    @State private var startWidth: CGFloat?

    var body: some View {
        Rectangle()
            .fill(showsLine ? Color(nsColor: .separatorColor) : Theme.surface)
            .frame(width: 1)
            // Fills the same black up under the toolbar, so no sliver of window glass shows between the panes.
            .background(Theme.surface)
            .overlay {
                // A wider invisible strip makes the line easy to grab.
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { drag in
                                let base = startWidth ?? width
                                startWidth = base
                                width = min(max(base + drag.translation.width, range.lowerBound), range.upperBound)
                            }
                            .onEnded { _ in startWidth = nil }
                    )
            }
    }
}
