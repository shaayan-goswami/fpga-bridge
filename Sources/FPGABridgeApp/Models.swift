import FPGABridgeCore
import SwiftUI

// MARK: Flow Navigator

enum FlowSection: String, CaseIterable, Identifiable {
    case projectManager = "Project Manager"
    case simulation = "Simulation"
    case synthesis = "Synthesis"
    case implementation = "Implementation"
    case programAndDebug = "Program and Debug"

    var id: String { rawValue }
    var items: [FlowItem] { FlowItem.allCases.filter { $0.section == self } }
}

/// Mirrors Vivado's Flow Navigator. IP Integrator and RTL Analysis are left out: they need Vivado's graphical
/// viewers, which can't run on the Mac.
enum FlowItem: String, CaseIterable, Identifiable, Hashable {
    case projectSummary, settings, addSources
    case runSimulation
    case runSynthesis
    case runImplementation
    case generateBitstream, hardwareManager

    var id: String { rawValue }

    var title: String {
        switch self {
        case .projectSummary: "Project Summary"
        case .settings: "Settings"
        case .addSources: "Add Sources"
        case .runSimulation: "Run Simulation"
        case .runSynthesis: "Run Synthesis"
        case .runImplementation: "Run Implementation"
        case .generateBitstream: "Generate Bitstream"
        case .hardwareManager: "Open Hardware Manager"
        }
    }

    var symbol: String {
        switch self {
        case .projectSummary: "square.grid.2x2"
        case .settings: "gearshape"
        case .addSources: "plus.rectangle.on.folder"
        case .runSimulation: "waveform.path.ecg"
        case .runSynthesis: "cpu"
        case .runImplementation: "arrow.triangle.branch"
        case .generateBitstream: "memorychip"
        case .hardwareManager: "cable.connector.horizontal"
        }
    }

    var section: FlowSection {
        switch self {
        case .projectSummary, .settings, .addSources: .projectManager
        case .runSimulation: .simulation
        case .runSynthesis: .synthesis
        case .runImplementation: .implementation
        case .generateBitstream, .hardwareManager: .programAndDebug
        }
    }

    /// Items that aren't built yet are shown but can't be selected.
    var isAvailable: Bool {
        switch self {
        case .addSources, .runSimulation, .hardwareManager: false
        default: true
        }
    }

    var stage: FlowStage? {
        switch self {
        case .runSynthesis: .synthesis
        case .runImplementation: .implementation
        case .generateBitstream: .bitstream
        default: nil
        }
    }
}

/// The stages a build moves through. The build runs them as one script, so they advance together.
enum FlowStage: CaseIterable {
    case synthesis, implementation, bitstream
}

enum StageStatus { case pending, running, done, failed }

// MARK: Workspace

enum WorkspaceTab: Hashable, Identifiable {
    case summary, settings, bitstream
    case file(String)
    case report(String)
    case placeholder(FlowItem)

    var id: Self { self }

    var title: String {
        switch self {
        case .summary: "Project Summary"
        case .settings: "Settings"
        case .bitstream: "Bitstream"
        case .file(let path): (path as NSString).lastPathComponent
        case .report(let name): name
        case .placeholder(let item): item.title
        }
    }

    var symbol: String {
        switch self {
        case .summary: "square.grid.2x2"
        case .settings: "gearshape"
        case .bitstream: "memorychip"
        case .file: "doc.text"
        case .report: "doc.plaintext"
        case .placeholder(let item): item.symbol
        }
    }

    var isCloseable: Bool { self != .summary }
}

// MARK: Sources

enum SourceGroup: String, CaseIterable, Identifiable {
    case design = "Design Sources"
    case constraints = "Constraints"
    case simulation = "Simulation Sources"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .design: "chevron.left.forwardslash.chevron.right"
        case .constraints: "pin"
        case .simulation: "waveform"
        }
    }
}

struct SourceFile: Identifiable, Hashable {
    let path: String
    let group: SourceGroup
    var isTop = false

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }

    var kind: String {
        switch (path as NSString).pathExtension.lowercased() {
        case "v", "vh": "Verilog"
        case "sv", "svh": "SystemVerilog"
        case "vhd", "vhdl": "VHDL"
        case "xdc": "XDC constraints"
        default: "Text"
        }
    }
}

struct ProjectInfo {
    var name: String
    var board: String
    var part: String
    var top: String
    var vivadoPin: String?
    var buildMachine: String
    var location: String
    var sources: [SourceFile]
    var contents: [String: String]
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
        if text.hasPrefix("Command:") || text.hasPrefix("$ ") || text.hasPrefix("source ") { return .command }
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

// MARK: Runs and connection

enum RunStatus {
    case running, succeeded, failed, cancelled

    var label: String {
        switch self {
        case .running: "Running"
        case .succeeded: "Complete"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }

    var symbol: String {
        switch self {
        case .running: "circle.dotted"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .cancelled: "stop.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .running: .blue
        case .succeeded: .green
        case .failed: .red
        case .cancelled: .secondary
        }
    }
}

struct DesignRun: Identifiable {
    let id = UUID()
    var name: String
    var status: RunStatus
    var started: Date
    var elapsed: TimeInterval = 0
    var summary: BuildSummary?
}

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
        case .demo: .orange
        }
    }

    var detail: String {
        switch self {
        case .checking: "Checking the connection to the build machine"
        case .connected(let host): "Connected to \(host) over Tailscale and SSH"
        case .offline(let reason): reason
        case .demo: "No build machine is configured, so this is a simulated project and build. Run `fpga-bridge init` to connect a real one."
        }
    }
}

func formatDuration(_ seconds: TimeInterval) -> String {
    let total = Int(seconds.rounded())
    return total >= 60 ? "\(total / 60)m \(total % 60)s" : "\(total)s"
}
