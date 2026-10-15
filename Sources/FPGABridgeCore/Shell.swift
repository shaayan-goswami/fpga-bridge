import Foundation

public struct CommandResult {
    public let status: Int32
    public let stdout: String
    public let stderr: String

    public var succeeded: Bool { status == 0 }
}

public enum ShellError: DescribedError {
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
    ///
    /// With `onInterrupt`, Ctrl-C (SIGINT) and SIGTERM are caught instead of killing this process: the child is
    /// terminated, `onInterrupt` runs after it has exited (so cleanup can talk to the same remote), and the result
    /// is `Shell.interruptedStatus`.
    ///
    /// With `output`, the child's stdout and stderr go to that callback in chunks (not necessarily whole lines)
    /// instead of the terminal, and stdin is closed. This is how a UI shows a live log.
    public static func stream(
        _ executable: String, _ arguments: [String],
        onInterrupt: (() -> Void)? = nil, output: ((String) -> Void)? = nil
    ) throws -> Int32 {
        let process = makeProcess(executable, arguments)
        let capture = output.map { OutputCapture(process: process, handler: $0) }
        guard let onInterrupt else {
            do { try process.run() } catch { throw ShellError.launchFailed(executable, error) }
            capture?.started()
            process.waitUntilExit()
            capture?.finish()
            return process.terminationStatus
        }

        let signals = [SIGINT, SIGTERM]
        let flag = InterruptFlag()
        let previous = signals.map { signal($0, SIG_IGN) }
        let sources = signals.map { sig -> DispatchSourceSignal in
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler { flag.set(); process.terminate() }
            source.resume()
            return source
        }
        defer {
            sources.forEach { $0.cancel() }
            for (sig, old) in zip(signals, previous) { signal(sig, old) }
        }

        do { try process.run() } catch { throw ShellError.launchFailed(executable, error) }
        capture?.started()
        process.waitUntilExit()
        capture?.finish()
        if flag.isSet {
            onInterrupt()
            return interruptedStatus
        }
        return process.terminationStatus
    }

    /// Reads a child's combined stdout/stderr on a background queue until the pipe closes.
    private final class OutputCapture {
        private let pipe = Pipe()
        private let group = DispatchGroup()
        private let handler: (String) -> Void

        init(process: Process, handler: @escaping (String) -> Void) {
            self.handler = handler
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
        }

        /// Call right after `process.run()`: closes our copy of the write end so reading sees EOF when the child exits.
        func started() {
            try? pipe.fileHandleForWriting.close()
            let handle = pipe.fileHandleForReading
            group.enter()
            DispatchQueue.global().async { [handler, group] in
                while true {
                    let data = handle.availableData
                    if data.isEmpty { break }
                    handler(String(decoding: data, as: UTF8.self))
                }
                group.leave()
            }
        }

        func finish() { group.wait() }
    }

    /// Conventional exit status for "terminated by Ctrl-C" (128 + SIGINT).
    public static let interruptedStatus: Int32 = 130

    private final class InterruptFlag {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set() { lock.lock(); value = true; lock.unlock() }
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
