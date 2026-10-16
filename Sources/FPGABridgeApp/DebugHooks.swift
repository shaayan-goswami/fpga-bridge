import AppKit
import FPGABridgeCore
import SwiftUI

/// Everything that exists only to drive the app from scripts and screenshots. All of it is compiled in debug builds
/// only, so the shipped app reads no environment variables and has no screenshot code.
///
/// Variables (debug builds):
///   FPGA_BRIDGE_DEMO=1             always use the simulated backend, even if a build machine is configured
///   FPGA_BRIDGE_DEMO_SPEED=0.05    scale the simulated delays (0 = instant)
///   FPGA_BRIDGE_NO_PERSIST=1       don't read or write the recent-projects list
///   FPGA_BRIDGE_EXAMPLES_DIR=path  where "Open Example Project" writes the example
///   FPGA_BRIDGE_OPEN=path          open this project at launch
///   FPGA_BRIDGE_SCENARIO=name      start in a prepared state (see applyLaunchScenario)
///   FPGA_BRIDGE_CONSOLE_TAB=name   select a console tab
///   FPGA_BRIDGE_WIZARD_STEP=n      start the New Project wizard on step n
///   FPGA_BRIDGE_SNAPSHOT=file.png  save a PNG of the window and quit (plus _DELAY, _WINDOW_SIZE, _APPEARANCE)
enum DebugHooks {
    #if DEBUG
    private static let env = ProcessInfo.processInfo.environment

    static var forceDemo: Bool { env["FPGA_BRIDGE_DEMO"] != nil }
    static var demoSpeed: Double { Double(env["FPGA_BRIDGE_DEMO_SPEED"] ?? "") ?? 1 }
    static var persistRecents: Bool { env["FPGA_BRIDGE_NO_PERSIST"] == nil }
    static var examplesDirectory: URL? { env["FPGA_BRIDGE_EXAMPLES_DIR"].map { URL(fileURLWithPath: $0) } }
    static var openPath: String? { env["FPGA_BRIDGE_OPEN"] }
    static var scenario: String? { env["FPGA_BRIDGE_SCENARIO"] }
    static var consoleTab: ConsoleTab? { env["FPGA_BRIDGE_CONSOLE_TAB"].flatMap(ConsoleTab.init(rawValue:)) }
    static var wizardStartStep: Int? { env["FPGA_BRIDGE_WIZARD_STEP"].flatMap(Int.init) }
    #else
    static let forceDemo = false
    static let demoSpeed = 1.0
    static let persistRecents = true
    static let examplesDirectory: URL? = nil
    static let openPath: String? = nil
    static let scenario: String? = nil
    static let consoleTab: ConsoleTab? = nil
    static let wizardStartStep: Int? = nil
    #endif
}

#if DEBUG
extension AppModel {
    /// Starts the window in a prepared state, for screenshots and manual testing.
    func applyLaunchScenario() async {
        if let path = DebugHooks.openPath { openProject(at: URL(fileURLWithPath: path)) }
        switch DebugHooks.scenario {
        case "wizard": showNewProject = true
        case "example": openExampleProject()
        case "built":
            openExampleProject()
            run(.bitstream)
        case "hardware", "hardware-closed", "programdevice":
            openExampleProject()
            open(.hardware)
            if DebugHooks.scenario != "hardware-closed" {
                autoConnectHardware()
                while hardware.target != .open { try? await Task.sleep(nanoseconds: 50_000_000) }
            }
            if DebugHooks.scenario == "programdevice" { hardware.sheet = .device }
        case "simulation":
            openExampleProject()
            runSimulation()
            while !(simulation.isRunning || { if case .done = simulation.state { return true } else { return false } }()) {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            while simulation.isRunning { try? await Task.sleep(nanoseconds: 100_000_000) }
        case "templates":
            openExampleProject()
            if let top = sourceTree.first?.children?.first?.path { openFile(top) }
            open(.templates)
            selectedTemplateID = "Verilog/Counters/Binary Up Counter"
        case "settings":
            openExampleProject()
            showSettings = true
        case "addsources", "definemodule":
            openExampleProject()
            showAddSources = true
        case "file":
            openExampleProject()
            if let top = sourceTree.first?.children?.first?.path { openFile(top) }
        case "editsave":
            openExampleProject()
            run(.bitstream)
            while isRunning { try? await Task.sleep(nanoseconds: 100_000_000) }
            if let top = sourceTree.first?.children?.first?.path {
                openFile(top)
                updateDraft(editedText(for: top) + "\n// saved from the editor\n", for: top)
                saveFile(top)
            }
        case "edit":
            openExampleProject()
            if let top = sourceTree.first?.children?.first?.path {
                openFile(top)
                updateDraft(editedText(for: top) + "\n// added in the editor\nassign unused = 1'b0;\n", for: top)
            }
        default: break
        }
        if let tab = DebugHooks.consoleTab {
            while isRunning { try? await Task.sleep(nanoseconds: 100_000_000) }
            consoleTab = tab
        }
    }
}
#else
extension AppModel {
    func applyLaunchScenario() async {}
}
#endif

#if DEBUG
/// Saves a PNG of the window (and any sheet) then quits, when FPGA_BRIDGE_SNAPSHOT is set. Used to check the
/// layout without a person at the screen.
@MainActor
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
            MainActor.assumeIsolated {
                guard let window = mainWindow() else { return }
                let size = env["FPGA_BRIDGE_WINDOW_SIZE"]?.split(separator: "x").compactMap { Double($0) } ?? []
                let frame = size.count == 2 ? NSSize(width: size[0], height: size[1]) : window.frame.size
                // Far outside any screen: the views still render for cacheDisplay, but nothing appears on the desktop.
                window.setFrame(NSRect(x: -20_000, y: -20_000, width: frame.width, height: frame.height), display: true)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated {
                if let window = mainWindow() {
                    capture(window, to: path)
                    if let sheet = window.attachedSheet {
                        capture(sheet, to: path.replacingOccurrences(of: ".png", with: "-sheet.png"))
                        if let inner = sheet.attachedSheet {
                            capture(inner, to: path.replacingOccurrences(of: ".png", with: "-sheet2.png"))
                        }
                    }
                }
                // terminate(_:) can be held up by an open sheet; this process has nothing to save.
                exit(0)
            }
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
#else
enum Snapshot {
    static let isRequested = false
    static func scheduleIfRequested() {}
}
#endif
