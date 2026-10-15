import Foundation

public struct CommandResult {
    public let status: Int32
    public let stdout: String
    public let stderr: String

    public var succeeded: Bool { status == 0 }
}

public enum ShellError: Error, CustomStringConvertible {
    case timedOut(String)
    case launchFailed(String, Error)

    public var description: String {
        switch self {
        case .timedOut(let cmd): return "Timed out running: \(cmd)"
        case .launchFailed(let cmd, let err): return "Could not launch \(cmd): \(err.localizedDescription)"
        }
    }
}

public enum Shell {
    /// Runs a command and captures its output. `executable` may be an absolute path or a name looked up on PATH.
    public static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 15) throws -> CommandResult {
        let process = makeProcess(executable, arguments)
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        let group = DispatchGroup()
        var outData = Data()
        var errData = Data()
        group.enter()
        DispatchQueue.global().async { outData = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { errData = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }

        do { try process.run() } catch { throw ShellError.launchFailed(executable, error) }

        let exited = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { process.waitUntilExit(); exited.signal() }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            throw ShellError.timedOut(([executable] + arguments).joined(separator: " "))
        }
        group.wait()

        return CommandResult(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }

    /// Runs a command with stdin/stdout/stderr attached to the terminal and returns its exit status.
    public static func stream(_ executable: String, _ arguments: [String]) throws -> Int32 {
        let process = makeProcess(executable, arguments)
        do { try process.run() } catch { throw ShellError.launchFailed(executable, error) }
        process.waitUntilExit()
        return process.terminationStatus
    }

    private static func makeProcess(_ executable: String, _ arguments: [String]) -> Process {
        let process = Process()
        if executable.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + arguments
        }
        return process
    }
}
