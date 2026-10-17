import FPGABridgeCore
import Foundation
import SwiftUI

/// The board plugged into this Mac. Separate from `Backend`: programming happens locally, never on the build machine.
protocol HardwareBackend: AnyObject, Sendable {
    var isDemo: Bool { get }
    func detect(board: Board?) async throws -> [Programmer.Device]
    /// Programs the board and returns the exit status. Output arrives through `log` in chunks.
    func program(bitstream: String, board: Board?, persist: Bool, log: @escaping @Sendable (String) -> Void) async -> Int32
}

/// openFPGALoader on this Mac.
final class LiveHardware: HardwareBackend, Sendable {
    let isDemo = false

    func detect(board: Board?) async throws -> [Programmer.Device] {
        try await Task.detached { try Programmer.require().detect(board: board) }.value
    }

    func program(bitstream: String, board: Board?, persist: Bool, log: @escaping @Sendable (String) -> Void) async -> Int32 {
        await Task.detached {
            do {
                guard FileManager.default.fileExists(atPath: bitstream) else { throw ProgrammerError.noBitstream(bitstream) }
                return try Programmer.require().program(bitstream: bitstream, board: board, target: persist ? .flash : .sram, output: log)
            } catch {
                log("ERROR: \(error.userMessage)\n")
                return 1
            }
        }.value
    }
}

/// A pretend Basys 3, so Demo Mode (and the tests) can show the Hardware Manager without a board.
final class DemoHardware: HardwareBackend, Sendable {
    let isDemo = true
    let speed: Double

    init(speed: Double = 1) { self.speed = speed }

    func detect(board: Board?) async throws -> [Programmer.Device] {
        if speed > 0 { try? await Task.sleep(nanoseconds: UInt64(0.6 * speed * 1_000_000_000)) }
        return [Programmer.Device(idcode: "0x362d093", family: "artix a7 35t", model: "xc7a35")]
    }

    func program(bitstream: String, board: Board?, persist: Bool, log: @escaping @Sendable (String) -> Void) async -> Int32 {
        let steps = ["Open file DONE\n", "Parse file DONE\n", persist ? "Erase flash\n" : "load program\n",
                     "Load \(persist ? "flash" : "SRAM"): [==================================================] 100.00%\n", "Done\n"]
        for step in steps {
            if speed > 0 { try? await Task.sleep(nanoseconds: UInt64(0.35 * speed * 1_000_000_000)) }
            if Task.isCancelled { return 130 }
            log(step)
        }
        return 0
    }
}

/// A chip on the cable, named the way Vivado names hardware devices ("xc7a35t_0").
struct HardwareDevice: Identifiable, Equatable {
    let index: Int
    let device: Programmer.Device

    var name: String { "\(device.partName)_\(index)" }
    var id: String { name }
}

enum ProgramStatus: Equatable {
    case unknown
    case programming
    case programmed(Date, persistent: Bool)
    case failed
}

enum ProgramKind: String, Identifiable {
    /// Load the FPGA directly. Lost at power-off.
    case device
    /// Write the board's flash. Kept across power cycles.
    case memory

    var id: String { rawValue }
    var persistent: Bool { self == .memory }
    var title: String { self == .device ? "Program Device" : "Program Configuration Memory Device" }
}

/// Vivado's Hardware Manager: opens a target, lists the devices on it, programs them.
@MainActor
final class HardwareManager: ObservableObject {
    enum Target: Equatable {
        case closed
        case opening
        case open
        case failed(String)
    }

    let backend: HardwareBackend

    @Published private(set) var target = Target.closed
    @Published private(set) var devices: [HardwareDevice] = []
    @Published private(set) var status: [String: ProgramStatus] = [:]
    @Published var selectedID: String?
    @Published var sheet: ProgramKind?
    @Published private(set) var isProgramming = false

    /// Everything the manager has said, for the log under the Hardware Manager.
    @Published private(set) var lines: [ConsoleLine] = []

    /// Which window asked for the Program sheet, so only that window shows it ("main" or "standalone").
    var sheetHost = "main"

    func present(_ kind: ProgramKind, host: String) {
        sheetHost = host
        sheet = kind
    }

    private func emit(_ text: String, _ kind: ConsoleLine.Kind) {
        lines.append(ConsoleLine(text: text, kind: kind))
        console(text, kind)
    }

    /// Where messages go (the Tcl console). Set by `AppModel`.
    var console: (String, ConsoleLine.Kind) -> Void = { _, _ in }

    private var buffer = LineBuffer()

    init(backend: HardwareBackend) { self.backend = backend }

    var selected: HardwareDevice? { devices.first { $0.id == selectedID } }

    func status(of device: HardwareDevice) -> ProgramStatus { status[device.id] ?? .unknown }

    /// "Auto Connect": finds whatever is plugged in.
    func openTarget(board: Board?) async {
        guard target != .opening, !isProgramming else { return }
        target = .opening
        emit("open_hw_target", .command)
        do {
            let found = try await backend.detect(board: board)
            devices = found.enumerated().map { HardwareDevice(index: $0.offset, device: $0.element) }
            guard !devices.isEmpty else {
                target = .failed("No board found. Check the USB cable (it must carry data) and that the board's power switch is on.")
                emit("ERROR: no hardware target found", .error)
                return
            }
            target = .open
            selectedID = devices.first?.id
            emit("INFO: found \(devices.count) device\(devices.count == 1 ? "" : "s"): \(devices.map(\.name).joined(separator: ", "))", .info)
        } catch {
            devices = []
            target = .failed(error.userMessage)
            emit("ERROR: \(error.userMessage)", .error)
        }
    }

    func closeTarget() {
        guard !isProgramming else { return }
        emit("close_hw_target", .command)
        target = .closed
        devices = []
        selectedID = nil
        status = [:]
    }

    /// Programs the selected device. Returns whether it worked.
    @discardableResult
    func program(bitstream: String, board: Board?, kind: ProgramKind) async -> Bool {
        guard let device = selected, !isProgramming else { return false }
        isProgramming = true
        status[device.id] = .programming
        buffer = LineBuffer()
        let flashNote = kind.persistent ? " (configuration memory)" : ""
        emit("program_hw_devices [get_hw_devices \(device.name)]\(flashNote)", .command)
        emit("INFO: programming \(device.name) with \((bitstream as NSString).lastPathComponent)", .info)

        // The loader writes from its own thread. Hopping through the main queue keeps chunks in order.
        let status = await backend.program(bitstream: bitstream, board: board, persist: kind.persistent) { chunk in
            DispatchQueue.main.async { MainActor.assumeIsolated { self.ingest(chunk) } }
        }
        // An empty hop behind the queued chunks, so they all land before the result line.
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { done.resume() }
        }
        flush()
        isProgramming = false
        if status == 0 {
            self.status[device.id] = .programmed(Date(), persistent: kind.persistent)
            emit("INFO: programmed \(device.name)", .info)
            return true
        }
        self.status[device.id] = .failed
        emit("ERROR: programming \(device.name) failed (exit status \(status))", .error)
        return false
    }

    /// openFPGALoader redraws its progress bar with carriage returns. Keep the first and last, not every step.
    private func ingest(_ chunk: String) {
        for line in buffer.append(chunk.replacingOccurrences(of: "\r", with: "\n")) { emit(line) }
    }

    private func flush() {
        for line in buffer.flush() { emit(line) }
    }

    private func emit(_ line: String) {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        let isProgress = text.contains("[") && text.contains("%]") || text.range(of: #"\]\s+\d+(\.\d+)?%"#, options: .regularExpression) != nil
        if isProgress && !text.contains("100.00%") { return }
        emit(text, ConsoleLine.classify(text))
    }
}
