import Foundation

public struct TailscaleStatus: Equatable {
    public struct Node: Equatable {
        public var hostName: String
        public var dnsName: String
        public var ips: [String]
        public var online: Bool
    }

    public var backendState: String
    public var peers: [Node]

    public var isRunning: Bool { backendState == "Running" }

    /// Finds a peer by short hostname, MagicDNS name, or Tailscale IP.
    public func peer(matching host: String) -> Node? {
        let h = host.lowercased()
        return peers.first {
            $0.hostName.lowercased() == h
                || $0.dnsName.lowercased() == h
                || $0.dnsName.lowercased().hasPrefix(h + ".")
                || $0.ips.contains(host)
        }
    }

    /// Parses the output of `tailscale status --json`.
    public static func parse(json: Data) throws -> TailscaleStatus {
        struct Raw: Decodable {
            struct Peer: Decodable {
                var HostName: String?
                var DNSName: String?
                var TailscaleIPs: [String]?
                var Online: Bool?
            }
            var BackendState: String
            var Peer: [String: Peer]?
        }
        let raw = try JSONDecoder().decode(Raw.self, from: json)
        let peers = (raw.Peer ?? [:]).values.map {
            Node(
                hostName: $0.HostName ?? "",
                dnsName: ($0.DNSName ?? "").trimmingCharacters(in: CharacterSet(charactersIn: ".")),
                ips: $0.TailscaleIPs ?? [],
                online: $0.Online ?? false
            )
        }
        return TailscaleStatus(backendState: raw.BackendState, peers: peers)
    }
}

public enum Tailscale {
    /// The CLI is only on PATH for Homebrew installs; the App Store/standalone app bundles it.
    public static func cliPath() -> String? {
        let candidates = [
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
            "/opt/homebrew/bin/tailscale",
            "/usr/local/bin/tailscale",
        ]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return found }
        if let r = try? Shell.run("which", ["tailscale"]), r.succeeded {
            let path = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return path.isEmpty ? nil : path
        }
        return nil
    }

    public static func status() throws -> TailscaleStatus {
        guard let cli = cliPath() else { throw TailscaleError.notInstalled }
        let result = try Shell.run(cli, ["status", "--json"])
        // A stopped daemon still prints JSON with a BackendState, so try parsing before failing on exit status.
        if let status = try? TailscaleStatus.parse(json: Data(result.stdout.utf8)) { return status }
        throw TailscaleError.unavailable(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

public enum TailscaleError: Error, CustomStringConvertible {
    case notInstalled
    case unavailable(String)

    public var description: String {
        switch self {
        case .notInstalled: return "Tailscale CLI not found. Install Tailscale and sign in."
        case .unavailable(let detail): return "Could not read Tailscale status: \(detail)"
        }
    }
}
