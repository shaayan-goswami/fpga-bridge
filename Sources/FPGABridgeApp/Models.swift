import FPGABridgeCore
import SwiftUI

// MARK: Flow Navigator

/// The sections of Vivado's Flow Navigator, in Vivado's order.
enum FlowSection: String, CaseIterable, Identifiable {
    case projectManager = "Project Manager"
    case ipIntegrator = "IP Integrator"
    case simulation = "Simulation"
    case rtlAnalysis = "RTL Analysis"
    case synthesis = "Synthesis"
    case implementation = "Implementation"
    case programAndDebug = "Program and Debug"

    var id: String { rawValue }
    var items: [FlowItem] { FlowItem.allCases.filter { $0.section == self } }

    /// The design a section's "Open ... Design" opens. Vivado shows the section in bold while it is open.
    var designStage: DesignStage? {
        switch self {
        case .rtlAnalysis: .rtl
        case .synthesis: .synth
        case .implementation: .impl
        default: nil
        }
    }
}

enum FlowItem: String, CaseIterable, Identifiable {
    case settings, addSources, languageTemplates, ipCatalog
    case createBlockDesign, openBlockDesign, generateBlockDesign
    case runSimulation
    case runLinter, openElaboratedDesign
    case runSynthesis, openSynthesizedDesign
    case runImplementation, openImplementedDesign
    case generateBitstream, openHardwareManager

    var id: String { rawValue }

    var title: String {
        switch self {
        case .settings: "Settings"
        case .addSources: "Add Sources"
        case .languageTemplates: "Language Templates"
        case .ipCatalog: "IP Catalog"
        case .createBlockDesign: "Create Block Design"
        case .openBlockDesign: "Open Block Design"
        case .generateBlockDesign: "Generate Block Design"
        case .runSimulation: "Run Simulation"
        case .runLinter: "Run Linter"
        case .openElaboratedDesign: "Open Elaborated Design"
        case .runSynthesis: "Run Synthesis"
        case .openSynthesizedDesign: "Open Synthesized Design"
        case .runImplementation: "Run Implementation"
        case .openImplementedDesign: "Open Implemented Design"
        case .generateBitstream: "Generate Bitstream"
        case .openHardwareManager: "Open Hardware Manager"
        }
    }

    var symbol: String {
        switch self {
        case .settings: "gearshape"
        case .addSources: "plus.rectangle.on.folder"
        case .languageTemplates: "doc.text"
        case .ipCatalog: "puzzlepiece.extension"
        case .createBlockDesign: "square.grid.3x1.below.line.grid.1x2"
        case .openBlockDesign, .generateBlockDesign: "square.grid.3x1.below.line.grid.1x2"
        case .runSimulation: "waveform.path.ecg"
        case .runLinter: "play.fill"
        case .openElaboratedDesign: "square.stack.3d.up"
        case .runSynthesis: "play.fill"
        case .openSynthesizedDesign: "rectangle.on.rectangle"
        case .runImplementation: "play.fill"
        case .openImplementedDesign: "rectangle.on.rectangle"
        case .generateBitstream: "memorychip"
        case .openHardwareManager: "cable.connector.horizontal"
        }
    }

    var section: FlowSection {
        switch self {
        case .settings, .addSources, .languageTemplates, .ipCatalog: .projectManager
        case .createBlockDesign, .openBlockDesign, .generateBlockDesign: .ipIntegrator
        case .runSimulation: .simulation
        case .runLinter, .openElaboratedDesign: .rtlAnalysis
        case .runSynthesis, .openSynthesizedDesign: .synthesis
        case .runImplementation, .openImplementedDesign: .implementation
        case .generateBitstream, .openHardwareManager: .programAndDebug
        }
    }

    /// What the item says when it can't be used yet.
    var unavailableReason: String? {
        switch self {
        case .createBlockDesign, .openBlockDesign, .generateBlockDesign:
            "Block designs need Vivado's IP Integrator canvas, which isn't in this app yet"
        default: nil
        }
    }

    var isAvailable: Bool { unavailableReason == nil }

    /// The design view this item opens, if it is one.
    var designStage: DesignStage? {
        switch self {
        case .openElaboratedDesign: .rtl
        case .openSynthesizedDesign: .synth
        case .openImplementedDesign: .impl
        default: nil
        }
    }

    var runKind: RunKind? {
        switch self {
        case .runSynthesis: .synthesis
        case .runImplementation: .implementation
        case .generateBitstream: .bitstream
        default: nil
        }
    }
}

/// What Vivado lists under an open design in the Flow Navigator (Open Synthesized Design ▸ Report DRC, and so on).
enum DesignCommand: String, CaseIterable, Identifiable {
    case constraintsWizard, editTimingConstraints, setUpDebug, openDataflowDesign
    case reportTimingSummary, reportClockNetworks, reportClockInteraction, reportMethodology, reportDRC, reportNoise
    case reportUtilization, reportPower, schematic

    var id: String { rawValue }

    /// The items, in Vivado 2025.2's order for each design.
    static func commands(for stage: DesignStage) -> [DesignCommand] {
        switch stage {
        case .rtl: [.reportMethodology, .reportDRC, .reportNoise, .schematic]
        case .synth: [.constraintsWizard, .editTimingConstraints, .setUpDebug, .openDataflowDesign, .reportTimingSummary,
                      .reportClockNetworks, .reportClockInteraction, .reportMethodology, .reportDRC, .reportNoise,
                      .reportUtilization, .reportPower, .schematic]
        case .impl: [.constraintsWizard, .openDataflowDesign, .editTimingConstraints, .reportTimingSummary, .reportClockNetworks,
                     .reportClockInteraction, .reportMethodology, .reportDRC, .reportNoise, .reportUtilization, .reportPower, .schematic]
        }
    }

    var title: String {
        switch self {
        case .constraintsWizard: "Constraints Wizard"
        case .editTimingConstraints: "Edit Timing Constraints"
        case .setUpDebug: "Set Up Debug"
        case .openDataflowDesign: "Open Dataflow Design"
        case .schematic: "Schematic"
        default: report?.title ?? rawValue
        }
    }

    /// Vivado gives only some of these an icon.
    var symbol: String? {
        switch self {
        case .setUpDebug: "ladybug"
        case .reportTimingSummary: "timer"
        case .reportMethodology: "checklist"
        case .reportPower: "powerplug"
        case .schematic: "point.3.connected.trianglepath.dotted"
        default: nil
        }
    }

    var report: DesignReportKind? {
        switch self {
        case .reportTimingSummary: .timingSummary
        case .reportClockNetworks: .clockNetworks
        case .reportClockInteraction: .clockInteraction
        case .reportMethodology: .methodology
        case .reportDRC: .drc
        case .reportNoise: .noise
        case .reportUtilization: .utilization
        case .reportPower: .power
        default: nil
        }
    }

    /// Why an item can't be used yet, or nil.
    var unavailableReason: String? {
        switch self {
        case .constraintsWizard, .editTimingConstraints: "The constraints editors aren't in this app yet. Edit the .xdc file directly."
        case .setUpDebug: "Debug cores (ILA) need Vivado's hardware server talking to the board, which this app doesn't do yet"
        case .openDataflowDesign: "The dataflow view isn't in this app yet"
        default: nil
        }
    }
}

/// What Vivado lists under Open Hardware Manager.
enum HardwareCommand: String, CaseIterable, Identifiable {
    case openTarget, programDevice, addConfigurationMemoryDevice

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openTarget: "Open Target"
        case .programDevice: "Program Device"
        case .addConfigurationMemoryDevice: "Add Configuration Memory Device"
        }
    }
}

// MARK: Runs

enum RunStatus { case notStarted, running, complete, failed, cancelled }

struct RunState {
    var status: RunStatus = .notStarted
    /// A source or setting changed after the run finished. Vivado shows these as "Out-of-date".
    var outOfDate = false
    var started: Date?
    var elapsed: TimeInterval = 0

    var isUpToDate: Bool { status == .complete && !outOfDate }

    var label: String {
        if outOfDate && status == .complete { return "Out-of-date" }
        switch status {
        case .notStarted: return "Not started"
        case .running: return "Running"
        case .complete: return "Complete"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    var symbol: String {
        if outOfDate && status == .complete { return "exclamationmark.circle.fill" }
        switch status {
        case .notStarted: return "circle"
        case .running: return "circle.dotted"
        case .complete: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .cancelled: return "stop.circle.fill"
        }
    }

    var color: Color {
        if outOfDate && status == .complete { return Accent.warning }
        switch status {
        case .notStarted, .cancelled: return .secondary
        case .running: return Accent.active
        case .complete: return Accent.success
        case .failed: return Accent.error
        }
    }
}

struct ReportFile {
    var run: RunKind
    var name: String
    var text: String
}

struct ReportEntry: Identifiable {
    var run: RunKind
    var fileName: String
    var text: String

    var id: String { "\(run.runName)/\(fileName)" }

    var title: String { DesignReportKind.title(ofFile: fileName) }
}

// MARK: Workspace

enum WorkspaceTab: Hashable, Identifiable {
    case summary
    case file(String)
    case report(String)
    case design(DesignStage)
    /// The Schematic window of an open design.
    case schematic(DesignStage)
    /// The Linter window: what Run Linter found.
    case linter
    case ipCatalog
    case hardware
    case templates
    case simulation
    case waveform

    var id: Self { self }
    var isCloseable: Bool { self != .summary }
}

// MARK: Sources

struct SourceNode: Identifiable, Hashable {
    let id: String
    var title: String
    var detail: String?
    var symbol: String
    /// Project-relative path when the node is a file.
    var path: String?
    var isTop = false
    var children: [SourceNode]?
}

// MARK: Unsaved changes

/// Asks what to do with edited files before something that would lose them (closing a tab, switching projects,
/// quitting). `proceed` runs once the user has saved or discarded.
struct UnsavedPrompt: Identifiable {
    let id = UUID()
    let files: [String]
    let proceed: () -> Void

    var title: String {
        files.count == 1
            ? "Do you want to save the changes you made to \((files[0] as NSString).lastPathComponent)?"
            : "Do you want to save the changes to \(files.count) files?"
    }
}

enum UnsavedChoice { case save, discard, cancel }

// MARK: Console

struct ConsoleLine: Identifiable {
    enum Kind { case command, output, info, warning, error }

    let id = UUID()
    let text: String
    let kind: Kind

    static func classify(_ text: String) -> Kind {
        if text.hasPrefix("ERROR:") || text.hasPrefix("CRITICAL WARNING:") { return .error }
        if text.hasPrefix("WARNING:") { return .warning }
        if text.hasPrefix("INFO:") { return .info }
        if text.hasPrefix("Command:") || text.hasPrefix("$ ") || text.hasPrefix("source ") || text.hasPrefix("launch_runs")
            || text.hasPrefix("wait_on_run") { return .command }
        return .output
    }
}

enum ConsoleTab: String, CaseIterable, Identifiable {
    case tclConsole = "Tcl Console"
    case messages = "Messages"
    case log = "Log"
    case reports = "Reports"
    case designRuns = "Design Runs"

    var id: String { rawValue }
}

/// Splits streamed text chunks into whole lines.
struct LineBuffer {
    private var pending = ""

    mutating func append(_ chunk: String) -> [String] {
        pending += chunk
        var lines = pending.components(separatedBy: "\n")
        pending = lines.removeLast()
        return lines.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\r")) }
    }

    mutating func flush() -> [String] {
        defer { pending = "" }
        return pending.isEmpty ? [] : [pending]
    }
}

// MARK: Connection

enum ConnectionState: Equatable {
    case checking
    case connected(String)
    case offline(String)
    case demo

    var label: String {
        switch self {
        case .checking: "Checking…"
        case .connected(let host): host
        case .offline: "Offline"
        case .demo: "Demo Mode"
        }
    }

    var color: Color {
        switch self {
        case .checking: .secondary
        case .connected: Accent.success
        case .offline: Accent.error
        case .demo: .secondary
        }
    }

    var detail: String {
        switch self {
        case .checking: "Checking the connection to the build machine…"
        case .connected(let host): "Connected to \(host) over Tailscale and SSH."
        case .offline(let reason): reason
        case .demo: "No build machine is configured, so runs are simulated. Run `fpga-bridge init` to connect a real one."
        }
    }
}

// MARK: Helpers

func formatDuration(_ seconds: TimeInterval) -> String {
    let total = Int(seconds.rounded())
    return total >= 60 ? "\(total / 60)m \(total % 60)s" : "\(total)s"
}

func formatSigned(_ value: Double?) -> String {
    value.map { String(format: "%+.3f", $0) } ?? "—"
}

/// "12" for whole numbers, "2.5" for half tiles.
func formatCount(_ value: Double) -> String {
    value == value.rounded() ? String(Int(value)) : String(value)
}

/// Product family from a Vivado part number, as Vivado's Project Summary shows it.
func family(ofPart part: String) -> String {
    let p = part.lowercased()
    if p.hasPrefix("xc7a") { return "Artix-7" }
    if p.hasPrefix("xc7s") { return "Spartan-7" }
    if p.hasPrefix("xc7k") { return "Kintex-7" }
    if p.hasPrefix("xc7z") { return "Zynq-7000" }
    if p.hasPrefix("xc7v") { return "Virtex-7" }
    if p.hasPrefix("xcku") { return "Kintex UltraScale" }
    if p.hasPrefix("xcvu") { return "Virtex UltraScale" }
    if p.hasPrefix("xczu") { return "Zynq UltraScale+" }
    return "—"
}
