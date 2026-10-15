import FPGABridgeCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if model.hasProject {
                MainWindowView()
            } else {
                QuickStartView()
            }
        }
        .sheet(isPresented: $model.showNewProject) {
            NewProjectWizard().environmentObject(model)
        }
        .sheet(isPresented: $model.showSettings) {
            ProjectSettingsView().environmentObject(model)
        }
        .sheet(isPresented: $model.showAddSources) {
            AddSourcesSheet().environmentObject(model)
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
    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView(columnVisibility: $columns) {
                FlowNavigatorView()
                    .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 320)
            } content: {
                SourcesPane()
                    .navigationSplitViewColumnWidth(min: 280, ideal: 330, max: 460)
            } detail: {
                VSplitView {
                    WorkspaceView()
                        .frame(minHeight: 380)
                        .layoutPriority(1)
                    if model.consoleVisible {
                        ConsolePanel()
                            .frame(minHeight: 160, idealHeight: 240, maxHeight: 420)
                    }
                }
            }
            .navigationTitle(model.project?.name ?? "FPGA Bridge")
            .navigationSubtitle(subtitle)
            .toolbar { MainToolbar(model: model) }
            // Below the split view rather than an inset, so it spans every column.
            StatusBar()
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
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
