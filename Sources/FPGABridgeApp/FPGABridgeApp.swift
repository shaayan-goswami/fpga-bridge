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
                .task { await model.start() }
        }
        .defaultSize(width: 1440, height: 900)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands { AppCommands(model: model) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if Snapshot.isRequested {
            // Render off-screen without taking focus, so capturing doesn't get in the way of whoever is at the Mac.
            NSApp.setActivationPolicy(.accessory)
        } else {
            // Needed when launched with `swift run` rather than from an .app bundle.
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
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
            Button("Add Sources…") { model.showAddSources = true }
                .keyboardShortcut("a", modifiers: [.command, .option])
                .disabled(!model.hasProject)
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

    private func report(_ name: String) -> ReportEntry? {
        model.reports.first { $0.run == .implementation && $0.fileName == name }
    }

    private func openReport(_ name: String) {
        if let entry = report(name) { model.openReport(entry.id) }
    }
}

/// Saves a PNG of the window (and any sheet) then quits, when FPGA_BRIDGE_SNAPSHOT is set. Used to check the
/// layout without a person at the screen.
enum Snapshot {
    static var isRequested: Bool { ProcessInfo.processInfo.environment["FPGA_BRIDGE_SNAPSHOT"] != nil }

    static func scheduleIfRequested() {
        let env = ProcessInfo.processInfo.environment
        if let appearance = env["FPGA_BRIDGE_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        }
        guard let path = env["FPGA_BRIDGE_SNAPSHOT"] else { return }
        let delay = Double(env["FPGA_BRIDGE_SNAPSHOT_DELAY"] ?? "") ?? 3
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard let window = mainWindow() else { return }
            let size = env["FPGA_BRIDGE_WINDOW_SIZE"]?.split(separator: "x").compactMap { Double($0) } ?? []
            let frame = size.count == 2 ? NSSize(width: size[0], height: size[1]) : window.frame.size
            // Far outside any screen: the views still render for cacheDisplay, but nothing appears on the desktop.
            window.setFrame(NSRect(x: -20_000, y: -20_000, width: frame.width, height: frame.height), display: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if let window = mainWindow() {
                capture(window, to: path)
                if let sheet = window.attachedSheet {
                    capture(sheet, to: path.replacingOccurrences(of: ".png", with: "-sheet.png"))
                }
            }
            // terminate(_:) can be held up by an open sheet; this process has nothing to save.
            exit(0)
        }
    }

    private static func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.sheetParent == nil && $0.contentView != nil && !($0 is NSPanel) }
    }

    private static func capture(_ window: NSWindow, to path: String) {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
