import Foundation

public struct Check: Equatable, Sendable {
    public enum Level: Equatable, Sendable { case ok, warn, fail }
    public let name: String
    public let level: Level
    public let detail: String
}

/// Runs the first-run health checks. Each check stops the chain when later ones can't be meaningful.
public enum Doctor {
    /// `tailscale` is injectable so tests don't depend on the machine's real Tailscale state.
    public static func run(
        config: BridgeConfig,
        tailscale: () throws -> TailscaleStatus = { try Tailscale.status() }
    ) -> [Check] {
        var checks: [Check] = []

        let (tailscaleCheck, proceed) = checkTailscale(host: config.host, status: tailscale)
        checks.append(tailscaleCheck)
        if !proceed { return checks }

        let remote = Remote(config: config)
        let ssh = checkSSH(remote)
        checks.append(ssh)
        guard ssh.level == .ok else { return checks }

        checks.append(checkVivado(remote))
        return checks
    }

    static func checkTailscale(host: String, status provider: () throws -> TailscaleStatus) -> (Check, Bool) {
        do {
            let status = try provider()
            guard status.isRunning else {
                return (Check(name: "Tailscale", level: .fail,
                              detail: "State is \(status.backendState). Open Tailscale and sign in."), false)
            }
            guard let peer = status.peer(matching: host) else {
                // The host may be a non-Tailscale address (same LAN); SSH check decides.
                return (Check(name: "Tailscale", level: .warn,
                              detail: "Connected, but \(host) isn't a tailnet device. Fine on the home LAN, won't work away from it."), true)
            }
            return peer.online
                ? (Check(name: "Tailscale", level: .ok, detail: "Connected, \(host) is online"), true)
                : (Check(name: "Tailscale", level: .fail, detail: "\(host) is offline on your tailnet. Is the build machine awake?"), false)
        } catch TailscaleError.notInstalled where !host.lowercased().hasSuffix(".ts.net") {
            // Not needed while the build machine is on the same network; SSH decides whether it is reachable.
            return (Check(name: "Tailscale", level: .warn,
                          detail: "Not installed. Fine while both machines are on the same network; you need it to build from anywhere else."), true)
        } catch {
            return (Check(name: "Tailscale", level: .fail, detail: "\(error.userMessage)"), false)
        }
    }

    static func checkSSH(_ remote: Remote) -> Check {
        do {
            let r = try remote.exec("echo ok")
            if r.succeeded && r.stdout.contains("ok") {
                return Check(name: "SSH", level: .ok, detail: "Logged in as \(remote.target)")
            }
            return Check(name: "SSH", level: .fail, detail: sshHint(r.stderr, os: remote.config.buildOS))
        } catch {
            return Check(name: "SSH", level: .fail, detail: "\(error.userMessage)")
        }
    }

    static func checkVivado(_ remote: Remote) -> Check {
        let path = remote.config.vivadoPath
        do {
            let os = remote.config.buildOS
            let r = try remote.exec(remote.commands.vivadoExists(path))
            if r.stdout.contains("found") {
                // The install path only suggests a version; ask Vivado itself.
                guard let version = try remote.vivadoVersion() else {
                    return Check(name: "Vivado", level: .warn, detail: "\(path) is there, but `vivado -version` didn't say which version it is.")
                }
                return Check(name: "Vivado", level: .ok, detail: "\(path) (Vivado \(version))")
            }
            let script = os == .windows ? "windows\\setup.ps1" : "linux/setup.sh"
            return Check(name: "Vivado", level: .fail,
                         detail: "\(path) not found on \(os.displayName). Re-run \(script) and `fpga-bridge init`.")
        } catch {
            return Check(name: "Vivado", level: .fail, detail: "\(error.userMessage)")
        }
    }

    static func sshHint(_ stderr: String, os: BuildOS = .windows) -> String {
        let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let windows = os == .windows
        if text.contains("Permission denied") {
            return windows
                ? "Key rejected. Pass your public key to windows\\setup.ps1 -PublicKey, or ssh-copy-id. (\(text))"
                : "Key rejected. Pass your public key to linux/setup.sh --public-key, or run ssh-copy-id. (\(text))"
        }
        if text.contains("refused") || text.contains("timed out") {
            return windows
                ? "Can't reach sshd on the Windows machine. Run windows\\setup.ps1 as Administrator. (\(text))"
                : "Can't reach sshd on the Linux machine. Run linux/setup.sh --install-ssh, or start the ssh service. (\(text))"
        }
        return text.isEmpty ? "SSH failed" : text
    }
}
