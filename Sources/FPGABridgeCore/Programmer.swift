import Foundation

/// Programs the board plugged into this Mac, using openFPGALoader. The bitstream is built on the build machine and
/// fetched into `build/`; nothing here talks to the remote.
public struct Programmer: Sendable {
    public static let executableName = "openFPGALoader"

    /// Where Homebrew puts it, for when the app was launched without a shell's PATH.
    public static let defaultSearchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]

    public enum Target: Equatable, Sendable {
        /// Load into the FPGA's configuration memory. Fast, and lost at power-off.
        case sram
        /// Write the board's flash, so the design loads again at power-on.
        case flash
    }

    public let executable: String

    public init(executable: String) { self.executable = executable }

    /// The installed openFPGALoader, or nil. Looks on `PATH` first, then the usual Homebrew locations.
    public static func locate(
        path: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
        searchPaths: [String] = defaultSearchPaths
    ) -> Programmer? {
        let directories = path.split(separator: ":").map(String.init) + searchPaths
        for directory in directories {
            let candidate = (directory as NSString).appendingPathComponent(executableName)
            if FileManager.default.isExecutableFile(atPath: candidate) { return Programmer(executable: candidate) }
        }
        return nil
    }

    public static func require() throws -> Programmer {
        guard let programmer = locate() else { throw ProgrammerError.notInstalled }
        return programmer
    }

    /// First line of `openFPGALoader --Version`, e.g. "openFPGALoader v1.0.0".
    public func version() -> String? {
        guard let result = try? Shell.run(executable, ["--Version"]), result.succeeded else { return nil }
        return result.stdout.split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// How to reach the board: its own name when known, else the Digilent cable. Left to itself openFPGALoader assumes
    /// a generic FTDI cable and finds nothing on a Digilent board, while still exiting 0.
    static func connection(for board: Board?) -> [String] {
        if let name = board?.loaderName { return ["-b", name] }
        return ["-c", "digilent"]
    }

    /// Arguments that program `bitstream` onto `board`.
    public static func arguments(bitstream: String, board: Board?, target: Target) -> [String] {
        var args = connection(for: board)
        if target == .flash { args.append("-f") }
        args.append(bitstream)
        return args
    }

    /// A chip found on the JTAG chain.
    public struct Device: Equatable, Sendable {
        public let idcode: String
        public let family: String
        public let model: String

        public init(idcode: String, family: String, model: String) {
            self.idcode = idcode
            self.family = family
            self.model = model
        }

        /// The part as Vivado names a hardware device: "xc7a35t" for model "xc7a35" in family "artix a7 35t".
        /// openFPGALoader leaves the trailing "t" (transceivers) off the model but keeps it in the family.
        public var partName: String {
            guard !model.isEmpty else { return family }
            let lastWord = family.split(separator: " ").last.map(String.init) ?? ""
            let hasT = lastWord.range(of: #"^\d+t$"#, options: .regularExpression) != nil
            return model.lowercased() + (hasT && !model.lowercased().hasSuffix("t") ? "t" : "")
        }
    }

    /// What `--detect` saw. openFPGALoader exits 0 even when nothing answered, so the output is what says.
    public func detect(board: Board? = nil) throws -> [Device] {
        let result = try Shell.run(executable, Programmer.connection(for: board) + ["--detect"], timeout: 30)
        guard result.succeeded else {
            throw ProgrammerError.loaderFailed((result.stdout + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return Programmer.devices(in: result.stdout)
    }

    /// Parses the "index 0: idcode 0x... family ... model ..." blocks of `--detect`.
    static func devices(in output: String) -> [Device] {
        var devices: [Device] = []
        var idcode: String?, family = "", model = ""
        func flush() {
            if let idcode { devices.append(Device(idcode: idcode, family: family, model: model)) }
            idcode = nil; family = ""; model = ""
        }
        for line in output.split(separator: "\n") {
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let key = words.first else { continue }
            let rest = words.dropFirst().joined(separator: " ")
            switch key {
            case "index": flush()
            case "idcode": idcode = rest
            case "family": family = rest
            case "model": model = rest
            default: break
            }
        }
        flush()
        return devices
    }

    /// Catalog boards that carry this chip, matched on the part's family prefix (xc7a35 matches xc7a35tcpg236-1).
    public static func boards(matching device: Device) -> [Board] {
        guard !device.model.isEmpty else { return [] }
        return BoardCatalog.all.filter { $0.part.lowercased().hasPrefix(device.model.lowercased()) }
    }

    /// Programs the board with output going to the terminal, or to `output` for a UI. Returns the exit status.
    public func program(
        bitstream: String, board: Board?, target: Target,
        output: (@Sendable (String) -> Void)? = nil
    ) throws -> Int32 {
        try Shell.stream(executable, Programmer.arguments(bitstream: bitstream, board: board, target: target), output: output)
    }

    /// `build/<top>.bit` under `root`, or an error that says to build first.
    public static func bitstreamPath(for project: Project, root: URL) throws -> String {
        let path = root.appendingPathComponent(Remote.localOutputDir).appendingPathComponent("\(project.top).bit").path
        guard FileManager.default.fileExists(atPath: path) else { throw ProgrammerError.noBitstream(path) }
        return path
    }

    /// Doctor line for this Mac's side of the flow.
    public static func check(locate: () -> Programmer? = { Programmer.locate() }) -> Check {
        guard let programmer = locate() else {
            return Check(name: "openFPGALoader", level: .fail,
                         detail: "Not installed. Run: brew install openfpgaloader")
        }
        return Check(name: "openFPGALoader", level: .ok, detail: programmer.version() ?? programmer.executable)
    }
}

public enum ProgrammerError: DescribedError {
    case notInstalled
    case noBitstream(String)
    case loaderFailed(String)

    public var description: String {
        switch self {
        case .notInstalled:
            return "openFPGALoader isn't installed. Install it with: brew install openfpgaloader"
        case .noBitstream(let path):
            return "No bitstream at \(path). Run `fpga-bridge build` first, or pass the .bit file."
        case .loaderFailed(let text):
            return "openFPGALoader failed:\n\(text)"
        }
    }
}
