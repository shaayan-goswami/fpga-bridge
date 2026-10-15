import Foundation

public struct BridgeConfig: Codable, Equatable {
    /// Tailscale name or IP of the Windows machine.
    public var host: String
    public var user: String
    /// Full Windows path to vivado.bat.
    public var vivadoPath: String
    public var sshKeyPath: String?

    public init(host: String, user: String, vivadoPath: String, sshKeyPath: String? = nil) {
        self.host = host
        self.user = user
        self.vivadoPath = vivadoPath
        self.sshKeyPath = sshKeyPath
    }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/fpga-bridge/config.json")
    }

    public static func load(from url: URL = defaultURL) throws -> BridgeConfig {
        guard let data = try? Data(contentsOf: url) else { throw ConfigError.missing(url.path) }
        return try JSONDecoder().decode(BridgeConfig.self, from: data)
    }

    public func save(to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

public enum ConfigError: Error, CustomStringConvertible {
    case missing(String)

    public var description: String {
        switch self {
        case .missing(let path):
            return "No config at \(path). Run `fpga-bridge init` first (the Windows setup script prints the command)."
        }
    }
}
