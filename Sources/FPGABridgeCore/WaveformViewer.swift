import Foundation

/// A program that shows `.vcd` waveforms. Surfer is the one we recommend (`brew install surfer`); GTKWave works too
/// if it is already installed. Homebrew installs these as commands, not apps, so macOS has no "open with" entry for
/// `.vcd` files and we launch them ourselves.
public struct WaveformViewer: Equatable, Sendable {
    public static let names = ["surfer", "gtkwave"]

    public let executable: String

    public init(executable: String) { self.executable = executable }

    public var name: String { (executable as NSString).lastPathComponent }

    /// The first installed viewer, in the order of `names`. Looks on `PATH`, then the usual Homebrew locations.
    public static func locate(
        path: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
        searchPaths: [String] = Programmer.defaultSearchPaths
    ) -> WaveformViewer? {
        let directories = path.split(separator: ":").map(String.init) + searchPaths
        for name in names {
            for directory in directories {
                let candidate = (directory as NSString).appendingPathComponent(name)
                if FileManager.default.isExecutableFile(atPath: candidate) { return WaveformViewer(executable: candidate) }
            }
        }
        return nil
    }

    /// Starts the viewer on `file` and returns without waiting for it to close.
    public func open(_ file: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [file.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw ShellError.launchFailed(executable, error) }
    }

    /// Doctor line. Only a warning: building, flashing and simulating work without one.
    public static func check(locate: () -> WaveformViewer? = { WaveformViewer.locate() }) -> Check {
        guard let viewer = locate() else {
            return Check(name: "Waveform viewer", level: .warn, detail: "None installed. To view simulation waveforms: brew install surfer")
        }
        return Check(name: "Waveform viewer", level: .ok, detail: viewer.name)
    }
}

public enum WaveformViewerError: DescribedError {
    case notInstalled

    public var description: String {
        "There is no waveform viewer installed, so the waveform can't be opened. Install Surfer with: brew install surfer"
    }
}
