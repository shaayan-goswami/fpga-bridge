import AppKit
import FPGABridgeCore
import SwiftUI

@main
struct FPGABridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.make()

    var body: some Scene {
        // One window, like Vivado.
        Window("FPGA Bridge", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1100, minHeight: 700)
                .modifier(AppearanceRoot())
                .task {
                    AppDelegate.model = model
                    await model.start()
                }
        }
        .defaultSize(width: 1440, height: 900)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands { AppCommands(model: model) }

        Settings {
            AppSettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set once the window appears, so quitting can check for unsaved edits.
    static weak var model: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard let model = AppDelegate.model, model.hasUnsavedChanges else { return .terminateNow }
            let count = model.drafts.count
            let alert = NSAlert()
            alert.messageText = count == 1 ? "Do you want to save the changes to 1 file?" : "Do you want to save the changes to \(count) files?"
            alert.informativeText = "Your changes will be lost if you don't save them."
            alert.addButton(withTitle: "Save All")
            alert.addButton(withTitle: "Don't Save")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn: return model.saveAll() ? .terminateNow : .terminateCancel
            case .alertSecondButtonReturn: return .terminateNow
            default: return .terminateCancel
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Snapshot.isRequested {
            // Render off-screen without taking focus, so capturing doesn't get in the way of whoever is at the Mac.
            NSApp.setActivationPolicy(.accessory)
        } else {
            // Needed when launched with `swift run` rather than from an .app bundle.
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        // The .app gets its icon from Assets.car; under `swift run` set it here, in the system's icon style.
        AppIcon.updateDockIcon()
        _ = IconStyleObserver.shared
        Snapshot.scheduleIfRequested()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Menus follow Vivado's: File > Project > New/Open/Close, a Flow menu with the run commands, and Reports.
struct AppCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Menu("Project") {
                Button("New…") { model.showNewProject = true }
                    .keyboardShortcut("n")
                Button("Open…") { model.openProjectWithPanel() }
                    .keyboardShortcut("o")
                Menu("Open Recent") {
                    ForEach(model.recentProjects, id: \.self) { url in
                        Button(url.lastPathComponent) { model.openProject(at: url) }
                    }
                }
                .disabled(model.recentProjects.isEmpty)
                Button("Open Example…") { model.openExampleProject() }
                Divider()
                Button("Close") { model.closeProject() }
                    .disabled(!model.hasProject)
            }
            Divider()
            Button("Save File") { model.saveCurrentFile() }
                .keyboardShortcut("s")
                .disabled(!selectedFileIsDirty)
            Button("Save All Files") { model.saveAll() }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(!model.hasUnsavedChanges)
            Divider()
            Button("Add Sources…") { model.showAddSources = true }
                .keyboardShortcut("a", modifiers: [.command, .option])
                .disabled(!model.hasProject)
        }

        CommandGroup(after: .textEditing) {
            Button("Toggle Comment") {
                NSApp.sendAction(#selector(CodeTextView.toggleComment(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("/")
        }

        CommandMenu("Flow") {
            Button("Settings…") { model.showSettings = true }
                .disabled(!model.hasProject)
            Divider()
            Button("Run Synthesis") { model.run(.synthesis) }
                .disabled(!model.hasProject || model.isRunning)
            Button("Run Implementation") { model.run(.implementation) }
                .disabled(!model.hasProject || model.isRunning)
            Button("Generate Bitstream") { model.run(.bitstream) }
                .keyboardShortcut("b")
                .disabled(!model.hasProject || model.isRunning)
            Divider()
            Button("Stop") { model.stop() }
                .keyboardShortcut(".")
                .disabled(!model.canStop)
            Button("Reset Runs") { model.resetRuns() }
                .disabled(!model.hasProject || model.isRunning)
            Divider()
            Button("Open Hardware Manager") {}
                .disabled(true)
        }

        CommandMenu("Reports") {
            Button("Report Timing Summary") { openReport(BuildSummary.timingReport) }
                .disabled(report(BuildSummary.timingReport) == nil)
            Button("Report Utilization") { openReport(BuildSummary.utilizationReport) }
                .disabled(report(BuildSummary.utilizationReport) == nil)
        }

        CommandGroup(after: .toolbar) {
            Button(model.consoleVisible ? "Hide Console" : "Show Console") { model.consoleVisible.toggle() }
                .keyboardShortcut("j")
                .disabled(!model.hasProject)
        }
    }

    private var selectedFileIsDirty: Bool {
        if case .file(let path) = model.selectedTab { return model.isDirty(path) }
        return false
    }

    private func report(_ name: String) -> ReportEntry? {
        model.reports.first { $0.run == .implementation && $0.fileName == name }
    }

    private func openReport(_ name: String) {
        if let entry = report(name) { model.openReport(entry.id) }
    }
}
