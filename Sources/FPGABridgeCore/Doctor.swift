import Foundation

public struct Check: Equatable {
    public enum Level: Equatable { case ok, warn, fail }
    public let name: String
    public let level: Level
    public let detail: String
}

/// Runs the first-run health checks. Each check stops the chain when later ones can't be meaningful.
public enum Doctor {
    public static func run(config: BridgeConfig) -> [Check] {
        var checks: [Check] = []

        switch checkTailscale(host: config.host) {
        case let (check, proceed):
            checks.append(check)
            if !proceed { return checks }
        }

        let remote = Remote(config: config)
        let ssh = checkSSH(remote)
        checks.append(ssh)
        guard ssh.level == .ok else { return checks }

        checks.append(checkVivado(remote))
        return checks
    }

    static func checkTailscale(host: String) -> (Check, Bool) {
        do {
            let status = try Tailscale.status()
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
                : (Check(name: "Tailscale", level: .fail, detail: "\(host) is offline on your tailnet. Is the Windows machine awake?"), false)
        } catch {
            return (Check(name: "Tailscale", level: .fail, detail: "\(error)"), false)
        }
    }

    static func checkSSH(_ remote: Remote) -> Check {
        do {
            let r = try remote.exec("echo ok")
            if r.succeeded && r.stdout.contains("ok") {
                return Check(name: "SSH", level: .ok, detail: "Logged in as \(remote.target)")
            }
            return Check(name: "SSH", level: .fail, detail: sshHint(r.stderr))
        } catch {
            return Check(name: "SSH", level: .fail, detail: "\(error)")
        }
    }

    static func checkVivado(_ remote: Remote) -> Check {
        let path = remote.config.vivadoPath
        do {
            let r = try remote.exec("if exist \"\(path)\" (echo found) else (echo missing)")
            if r.stdout.contains("found") {
                return Check(name: "Vivado", level: .ok, detail: path)
            }
            return Check(name: "Vivado", level: .fail,
                         detail: "\(path) not found on Windows. Re-run windows\\setup.ps1 and `fpga-bridge init`.")
        } catch {
            return Check(name: "Vivado", level: .fail, detail: "\(error)")
        }
    }

    static func sshHint(_ stderr: String) -> String {
        let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("Permission denied") {
            return "Key rejected. Pass your public key to windows\\setup.ps1 -PublicKey, or ssh-copy-id. (\(text))"
        }
        if text.contains("refused") || text.contains("timed out") {
            return "Can't reach sshd on the Windows machine. Run windows\\setup.ps1 as Administrator. (\(text))"
        }
        return text.isEmpty ? "SSH failed" : text
    }
}
