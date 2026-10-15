import FPGABridgeCore
import SwiftUI

// MARK: Flow Navigator

/// The sections of Vivado's Flow Navigator, in Vivado's order. IP Integrator is left out: block designs need
/// Vivado's graphical editor, which can't run on the Mac.
enum FlowSection: String, CaseIterable, Identifiable {
    case projectManager = "Project Manager"
    case simulation = "Simulation"
    case rtlAnalysis = "RTL Analysis"
    case synthesis = "Synthesis"
    case implementation = "Implementation"
    case programAndDebug = "Program and Debug"

    var id: String { rawValue }
    var items: [FlowItem] { FlowItem.allCases.filter { $0.section == self } }
}

enum FlowItem: String, CaseIterable, Identifiable {
    case settings, addSources, languageTemplates, ipCatalog
    case runSimulation
    case openElaboratedDesign
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
        case .runSimulation: "Run Simulation"
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
        case .runSimulation: "waveform.path.ecg"
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
        case .runSimulation: .simulation
        case .openElaboratedDesign: .rtlAnalysis
        case .runSynthesis, .openSynthesizedDesign: .synthesis
        case .runImplementation, .openImplementedDesign: .implementation
        case .generateBitstream, .openHardwareManager: .programAndDebug
        }
    }

    /// What the item says when it can't be used yet.
    var unavailableReason: String? {
        switch self {
        case .languageTemplates, .ipCatalog: "Not available in this prototype"
        case .runSimulation: "Simulation with Verilator is planned"
        case .openElaboratedDesign, .openSynthesizedDesign, .openImplementedDesign:
            "Vivado's schematic and netlist viewers can't run on the Mac. Use the reports instead."
        case .openHardwareManager: "Programming from the Mac with openFPGALoader is planned"
        default: nil
        }
    }

    var isAvailable: Bool { unavailableReason == nil }

    var runKind: RunKind? {
        switch self {
        case .runSynthesis: .synthesis
        case .runImplementation: .implementation
        case .generateBitstream: .bitstream
        default: nil
        }
    }
}

// MARK: Runs

/// What can be launched. Like Vivado, a bitstream is the last step of the implementation run.
enum RunKind: Hashable, CaseIterable {
    case synthesis, implementation, bitstream

    /// The Vivado run the step belongs to.
    var run: RunKind { self == .bitstream ? .implementation : self }
    var runName: String { run == .synthesis ? "synth_1" : "impl_1" }
    var title: String {
        switch self {
        case .synthesis: "Synthesis"
        case .implementation: "Implementation"
        case .bitstream: "Bitstream"
        }
    }
}

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
        if outOfDate && status == .complete { return .orange }
        switch status {
        case .notStarted, .cancelled: return .secondary
        case .running: return .secondary
        case .complete: return .green
        case .failed: return .red
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

    var title: String {
        switch fileName {
        case BuildSummary.timingReport: "Timing Summary Report"
        case BuildSummary.utilizationReport, "synth_utilization.rpt": "Utilization Report"
        default: fileName
        }
    }
}

// MARK: Workspace

enum WorkspaceTab: Hashable, Identifiable {
    case summary
    case file(String)
    case report(String)

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
        case .connected: .green
        case .offline: .red
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
