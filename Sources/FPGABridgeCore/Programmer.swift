import Foundation

/// Programs the board plugged into this Mac, using openFPGALoader. The bitstream is built on the Windows machine and
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

    /// Arguments that program `bitstream` onto `board`. Without a known board, openFPGALoader finds the cable on its own.
    public static func arguments(bitstream: String, board: Board?, target: Target) -> [String] {
        var args: [String] = []
        if let name = board?.loaderName { args += ["-b", name] }
        if target == .flash { args.append("-f") }
        args.append(bitstream)
        return args
    }

    /// Lists what openFPGALoader can see on USB (`--detect`). A zero exit with output means a device answered.
    public func detect(board: Board? = nil) throws -> CommandResult {
        var args: [String] = []
        if let name = board?.loaderName { args += ["-b", name] }
        args.append("--detect")
        return try Shell.run(executable, args, timeout: 30)
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

    public var description: String {
        switch self {
        case .notInstalled:
            return "openFPGALoader isn't installed. Install it with: brew install openfpgaloader"
        case .noBitstream(let path):
            return "No bitstream at \(path). Run `fpga-bridge build` first, or pass the .bit file."
        }
    }
}
