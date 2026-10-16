import FPGABridgeCore
import Foundation

/// Where the IP Catalog gets its data: the build machine's Vivado, or sample data in Demo Mode and the tests.
protocol IPBackend: AnyObject, Sendable {
    var isDemo: Bool { get }
    func catalog(part: String, refresh: Bool) async throws -> IPCatalog
    func properties(of ip: IPDefinition, part: String) async throws -> [IPProperty]
    /// Generates the instantiation templates for `ip` as configured. Vivado checks the settings here, so this is also
    /// how a bad value is found before anything is saved.
    func template(for ip: ProjectIP, part: String) async throws -> IPScriptOutput
}

final class LiveIPBackend: IPBackend, Sendable {
    let isDemo = false
    private let service: IPService

    init(config: BridgeConfig) { service = IPService(remote: Remote(config: config)) }

    func catalog(part: String, refresh: Bool) async throws -> IPCatalog {
        let service = service
        return try await Task.detached { try service.catalog(part: part, refresh: refresh) }.value
    }

    func properties(of ip: IPDefinition, part: String) async throws -> [IPProperty] {
        let service = service
        return try await Task.detached { try service.properties(of: ip, part: part) }.value
    }

    func template(for ip: ProjectIP, part: String) async throws -> IPScriptOutput {
        let service = service
        return try await Task.detached { try service.template(for: ip, part: part) }.value
    }
}

/// A handful of IP with plausible settings, so the catalog can be explored without a build machine. Nothing here is
/// real Vivado data, and the app says so.
final class DemoIPBackend: IPBackend, Sendable {
    let isDemo = true
    let speed: Double

    init(speed: Double = 1) { self.speed = speed }

    private func pause(_ seconds: Double) async {
        if speed > 0 { try? await Task.sleep(nanoseconds: UInt64(seconds * speed * 1_000_000_000)) }
    }

    static let definitions: [IPDefinition] = [
        IPDefinition(vlnv: "xilinx.com:ip:c_counter_binary:12.0", name: "c_counter_binary", displayName: "Binary Counter",
                     taxonomy: "/DSP_and_Math/General", description: "A binary counter with optional load, clear and threshold output.",
                     requiresLicense: false, supported: true),
        IPDefinition(vlnv: "xilinx.com:ip:clk_wiz:6.0", name: "clk_wiz", displayName: "Clocking Wizard",
                     taxonomy: "/FPGA_Features_and_Design/Clocking", description: "Generates clocks of other frequencies from an input clock.",
                     requiresLicense: false, supported: true),
        IPDefinition(vlnv: "xilinx.com:ip:fifo_generator:13.2", name: "fifo_generator", displayName: "FIFO Generator",
                     taxonomy: "/Memories_and_Storage_Elements/FIFOs", description: "A first-in first-out queue in block RAM, distributed RAM or built-in FIFO.",
                     requiresLicense: false, supported: true),
        IPDefinition(vlnv: "xilinx.com:ip:blk_mem_gen:8.4", name: "blk_mem_gen", displayName: "Block Memory Generator",
                     taxonomy: "/Memories_and_Storage_Elements/RAMs_and_ROMs_and_BRAMs", description: "A RAM or ROM built from block RAM, with an optional initial contents file.",
                     requiresLicense: false, supported: true),
        IPDefinition(vlnv: "xilinx.com:ip:ila:6.2", name: "ila", displayName: "ILA (Integrated Logic Analyzer)",
                     taxonomy: "/Debug_and_Verification/Debug", description: "Captures signals inside the running FPGA for viewing in the Hardware Manager.",
                     requiresLicense: false, supported: true),
        IPDefinition(vlnv: "xilinx.com:ip:axis_noc:1.0", name: "axis_noc", displayName: "AXI4-Stream NoC",
                     taxonomy: "/Interfaces_and_Interconnect/AXI_Infrastructure", description: "Connects AXI4-Stream devices through the Network On Chip. Versal only.",
                     requiresLicense: false, supported: false),
    ]

    func catalog(part: String, refresh: Bool) async throws -> IPCatalog {
        await pause(0.8)
        return IPCatalog(definitions: Self.definitions, part: part, vivado: "2023.2 (demo data)")
    }

    func properties(of ip: IPDefinition, part: String) async throws -> [IPProperty] {
        await pause(0.6)
        switch ip.name {
        case "c_counter_binary":
            return [("CONFIG.CE", "false"), ("CONFIG.Count_Mode", "UP"), ("CONFIG.Increment_Value", "1"), ("CONFIG.Load", "false"),
                    ("CONFIG.Output_Width", "16"), ("CONFIG.SCLR", "false")].map { IPProperty(name: $0.0, value: $0.1) }
        case "clk_wiz":
            return [("CONFIG.CLKOUT1_REQUESTED_OUT_FREQ", "100.000"), ("CONFIG.PRIM_IN_FREQ", "100.000"), ("CONFIG.USE_LOCKED", "true"),
                    ("CONFIG.USE_RESET", "true")].map { IPProperty(name: $0.0, value: $0.1) }
        default:
            return [("CONFIG.Data_Width", "32"), ("CONFIG.Depth", "512")].map { IPProperty(name: $0.0, value: $0.1) }
        }
    }

    func template(for ip: ProjectIP, part: String) async throws -> IPScriptOutput {
        await pause(0.5)
        let width = ip.config["CONFIG.Output_Width"] ?? "16"
        var out = IPScriptOutput()
        out.verilogTemplate = ["//----------- Begin Cut here for INSTANTIATION Template ---// INST_TAG",
                               "\(ip.name) your_instance_name (", "  .CLK(CLK),  // input wire CLK", "  .Q(Q)      // output wire [\(width) : 0] Q", ");",
                               "// INST_TAG_END ------ End INSTANTIATION Template ---------"]
        out.vhdlTemplate = ["------------- Begin Cut here for INSTANTIATION Template ----- INST_TAG", "your_instance_name : \(ip.name)",
                            "  PORT MAP (", "    CLK => CLK,", "    Q => Q", "  );", "-- INST_TAG_END ------ End INSTANTIATION Template ---------"]
        if ip.config.values.contains("bad") { out.error = "ERROR: [Common 17-69] Command failed: value 'bad' is not valid for this setting" }
        if let error = out.error { throw IPServiceError.vivado(error) }
        return out
    }
}
