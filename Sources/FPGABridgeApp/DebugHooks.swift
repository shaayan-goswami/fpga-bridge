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
///   FPGA_BRIDGE_SETTINGS_PAGE=name open Project Settings on this page (General, Simulation, ...)
///   FPGA_BRIDGE_SELECT=kind:name   in a design scenario, select this object (cell:u_tick, net:clk, port:led[0])
///   FPGA_BRIDGE_EXPAND=a,b         in a schematic scenario, open these module instances in place
///   FPGA_BRIDGE_SCHEMATIC_ONLY=a,b  in a schematic scenario, draw only these cells (as F4 on a selection does)
///   FPGA_BRIDGE_SCHEMATIC_VIEW=z,x,y in a schematic scenario, zoom to z (1 = 100%) centred at x,y (0...1 of the drawing)
///   FPGA_BRIDGE_BD_PAGE=name       in the blockdesign scenario, show this page (Diagram, Address Editor)
///   FPGA_BRIDGE_BD_SELECT=kind:name in the blockdesign scenario, select this (cell:axi_uartlite_0, port:UART_0)
///   (FPGA_BRIDGE_EXPAND also opens these hierarchies in the blockdesign scenario.)
///   FPGA_BRIDGE_TIMING_PATH=n     in a design scenario, open the Timing window on path n (0 = Design Timing Summary)
///   FPGA_BRIDGE_FAKE_UPDATE=0.3.0  show the update notice for this version (no network; the app pretends to be 0.2.1)
///   FPGA_BRIDGE_SNAPSHOT=file.png  save a PNG of the window and quit (plus _DELAY, _WINDOW_SIZE, _APPEARANCE)
enum DebugHooks {
    #if DEBUG
    private static let env = ProcessInfo.processInfo.environment

    static var forceDemo: Bool { env["FPGA_BRIDGE_DEMO"] != nil }
    static var demoSpeed: Double { Double(env["FPGA_BRIDGE_DEMO_SPEED"] ?? "") ?? 1 }
    static var persistRecents: Bool { env["FPGA_BRIDGE_NO_PERSIST"] == nil }
    /// Read live, not from the cached `env`, so a test can point each run at its own folder.
    static var examplesDirectory: URL? { getenv("FPGA_BRIDGE_EXAMPLES_DIR").map { URL(fileURLWithPath: String(cString: $0)) } }
    static var openPath: String? { env["FPGA_BRIDGE_OPEN"] }
    static var scenario: String? { env["FPGA_BRIDGE_SCENARIO"] }
    static var consoleTab: ConsoleTab? { env["FPGA_BRIDGE_CONSOLE_TAB"].flatMap(ConsoleTab.init(rawValue:)) }
    static var wizardStartStep: Int? { env["FPGA_BRIDGE_WIZARD_STEP"].flatMap(Int.init) }
    static var settingsPage: String? { env["FPGA_BRIDGE_SETTINGS_PAGE"] }
    static var designSection: String? { env["FPGA_BRIDGE_DESIGN_SECTION"] }
    /// Where part data is read and saved instead of Application Support (ChipViews.swift).
    static var partDataDirectory: URL? { env["FPGA_BRIDGE_PART_DATA_DIR"].map { URL(fileURLWithPath: $0) } }
    static var selectObject: DesignObjectRef? {
        guard let spec = env["FPGA_BRIDGE_SELECT"], let colon = spec.firstIndex(of: ":"),
              let kind = DesignObjectKind(rawValue: String(spec[..<colon])) else { return nil }
        return DesignObjectRef(kind, String(spec[spec.index(after: colon)...]))
    }
    static var schematicView: (zoom: CGFloat, x: CGFloat, y: CGFloat)? {
        let parts = (env["FPGA_BRIDGE_SCHEMATIC_VIEW"] ?? "").split(separator: ",").compactMap { Double($0) }
        return parts.count == 3 ? (CGFloat(parts[0]), CGFloat(parts[1]), CGFloat(parts[2])) : nil
    }
    #else
    static let forceDemo = false
    static let demoSpeed = 1.0
    static let persistRecents = true
    static let examplesDirectory: URL? = nil
    static let openPath: String? = nil
    static let scenario: String? = nil
    static let consoleTab: ConsoleTab? = nil
    static let wizardStartStep: Int? = nil
    static let settingsPage: String? = nil
    static let designSection: String? = nil
    static let partDataDirectory: URL? = nil
    static let selectObject: DesignObjectRef? = nil
    static let schematicView: (zoom: CGFloat, x: CGFloat, y: CGFloat)? = nil
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
        case "ipcatalog", "ipcustomize":
            if DebugHooks.openPath == nil { openExampleProject() }
            openIPCatalog()
        case "design-rtl", "design-synth", "design-impl", "schematic-rtl", "schematic-synth", "schematic-impl":
            // Wait for the previous build's data to load from build/, then open the view.
            let name = DebugHooks.scenario!
            let stage = DesignStage(rawValue: String(name.split(separator: "-").last ?? "")) ?? .synth
            while designs[stage] == nil { try? await Task.sleep(nanoseconds: 100_000_000) }
            open(.design(stage))
            if name.hasPrefix("schematic") {
                var spec = SchematicSpec()
                spec.expanded = Set((ProcessInfo.processInfo.environment["FPGA_BRIDGE_EXPAND"] ?? "").split(separator: ",").map(String.init))
                let only = (ProcessInfo.processInfo.environment["FPGA_BRIDGE_SCHEMATIC_ONLY"] ?? "").split(separator: ",").map(String.init)
                if !only.isEmpty { spec.only = Set(only) }
                schematicSpecs[stage] = spec
                open(.schematic(stage))
            }
            if let ref = DebugHooks.selectObject { select(ref) }
            applyTimingScenario(stage)
        case "package-rtl", "package-synth", "package-impl", "device-synth", "device-impl":
            let name = DebugHooks.scenario!
            let stage = DesignStage(rawValue: String(name.split(separator: "-").last ?? "")) ?? .synth
            if DebugHooks.openPath == nil {
                openExampleProject()
                run(.bitstream)
            }
            while designs[stage] == nil { try? await Task.sleep(nanoseconds: 100_000_000) }
            if name.hasPrefix("package") { openPackage(stage) } else { openDevice(stage) }
            if let ref = DebugHooks.selectObject { select(ref) }
        case "waveform", "waveform-zoom", "waveform-markers":
            if DebugHooks.openPath == nil { openExampleProject() }
            runSimulation()
            while !(simulation.isRunning || { if case .done = simulation.state { return true } else { return false } }()) {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            while simulation.isRunning || waveform.isLoading || waveform.waveform == nil { try? await Task.sleep(nanoseconds: 100_000_000) }
            if let id = waveform.waveform?.signals.firstIndex(where: { $0.name == "clk" }) { waveform.selected = id }
            waveform.setCursor(tick: waveform.endTime * 0.4)
            if DebugHooks.scenario == "waveform-markers" {
                // Two markers 40% apart, both picked, and a divider above the selected signal.
                waveform.setCursor(tick: waveform.endTime * 0.3)
                if let a = waveform.addMarker() { waveform.selectMarker(a.id) }
                waveform.setCursor(tick: waveform.endTime * 0.7)
                if let b = waveform.addMarker() { waveform.selectMarker(b.id) }
                waveform.setCursor(tick: waveform.endTime * 0.55)
                waveform.addDivider(named: "Clocks")
            }
            if DebugHooks.scenario == "waveform-zoom" {
                waveform.zoom(by: 9, anchor: 0.4)
                waveform.setCursor(tick: waveform.viewStart + waveform.span * 0.5)
            }
        case "blockdesign":
            if let path = blockDesignPaths.first { openBlockDesign(path) }
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
        case "saveas", "archive", "writetcl", "find", "replace", "findresults", "disabled":
            // File > Project dialogs, Find/Replace in Files and its results, and a disabled file in Sources.
            openExampleProject()
            switch DebugHooks.scenario {
            case "saveas": tools.sheet = .saveAs
            case "archive": tools.sheet = .archive
            case "writetcl": tools.sheet = .writeTcl
            case "disabled":
                if let file = allProjectFiles.first(where: { $0.path.hasSuffix("debounce.v") })?.path {
                    setFileEnabled(file, false)
                    selectedSourceID = "file:\(file)"
                }
            default:
                tools.options = FileSearch.Options(text: "clk", wholeWord: true)
                tools.replacement = "clock"
                findInFiles(replacing: DebugHooks.scenario == "replace")
                await tools.waitForSearch()
                if DebugHooks.scenario != "findresults" { tools.sheet = .find(replace: DebugHooks.scenario == "replace") }
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
