import Foundation

public struct BridgeConfig: Codable, Equatable, Sendable {
    /// Tailscale name or IP of the build machine.
    public var host: String
    public var user: String
    /// Full path to Vivado's launcher on the build machine: `vivado.bat` on Windows, `vivado` on Linux.
    public var vivadoPath: String
    public var sshKeyPath: String?
    /// The build machine's operating system. Left out of older configs, which means "work it out from the path".
    public var os: BuildOS?

    public init(host: String, user: String, vivadoPath: String, sshKeyPath: String? = nil, os: BuildOS? = nil) {
        self.host = host
        self.user = user
        self.vivadoPath = vivadoPath
        self.sshKeyPath = sshKeyPath
        self.os = os
    }

    /// The operating system to talk to: the one set in the config, or the one the Vivado path looks like.
    public var buildOS: BuildOS { os ?? BuildOS.guess(fromVivadoPath: vivadoPath) }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/fpga-bridge/config.json")
    }

    public static func load(from url: URL = defaultURL) throws -> BridgeConfig {
        guard let data = try? Data(contentsOf: url) else { throw ConfigError.missing(url.path) }
        let config = try JSONDecoder().decode(BridgeConfig.self, from: data)
        try config.validate()
        return config
    }

    /// The host and user go into an ssh command line and the Vivado path into a cmd.exe or sh line, so refuse anything
    /// that could be read as an option or as shell syntax. A config file is the user's own, but a typo shouldn't turn into
    /// a different command.
    public func validate() throws {
        func plain(_ value: String, allowed: String) -> Bool {
            !value.isEmpty && !value.hasPrefix("-")
                && value.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || allowed.unicodeScalars.contains($0) }
        }
        guard plain(host, allowed: "._:-") else { throw ConfigError.invalid("host", host) }
        guard plain(user, allowed: "._-") else { throw ConfigError.invalid("user", user) }
        let forbidden = CharacterSet(charactersIn: "\"&|<>^%\n\r`")
        guard !vivadoPath.isEmpty, vivadoPath.rangeOfCharacter(from: forbidden) == nil else {
            throw ConfigError.invalid("Vivado path", vivadoPath)
        }
        // `~` isn't expanded inside quotes, and a relative path depends on where the SSH session starts.
        if buildOS == .linux, !vivadoPath.hasPrefix("/") {
            throw ConfigError.invalid("Vivado path (on Linux it must start with /)", vivadoPath)
        }
        if let key = sshKeyPath, key.isEmpty || key.rangeOfCharacter(from: CharacterSet(charactersIn: "\n\r")) != nil {
            throw ConfigError.invalid("SSH key path", key)
        }
    }

    public func save(to url: URL = defaultURL) throws {
        try validate()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

public enum ConfigError: DescribedError {
    case missing(String)
    case invalid(String, String)

    public var description: String {
        switch self {
        case .missing(let path):
            return "No config at \(path). Run `fpga-bridge init` first (the setup script on the build machine prints the command)."
        case .invalid(let what, let value):
            return "The \(what) '\(value)' isn't allowed: it is empty, starts with '-', or contains characters that could be read as part of a command."
        }
    }
}
