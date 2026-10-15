# Setup and usage (current CLI)

**1. On the Windows machine**, install [Tailscale](https://tailscale.com/download) and sign in, then run from an elevated PowerShell:

```powershell
.\windows\setup.ps1 -PublicKey "<contents of ~/.ssh/id_ed25519.pub from your Mac>"
```

It enables OpenSSH, authorizes your Mac's key, checks Tailscale, finds the newest Vivado, and prints the Mac command below.
(Not yet tested on a real Windows machine.)

**2. On the Mac** (Tailscale installed and signed in to the same tailnet):

```sh
swift build -c release
.build/release/fpga-bridge init --host <name> --user <you> --vivado "<path to vivado.bat>"
.build/release/fpga-bridge doctor
```

## Commands

```sh
fpga-bridge doctor                      # Tailscale, SSH and Vivado checks
fpga-bridge tcl build.tcl               # run a local Tcl script in Vivado batch mode
fpga-bridge tcl -c 'puts [version]'     # or inline Tcl
```

## Layout

- `Sources/FPGABridgeCore`: config, Tailscale status, SSH/Vivado runner, health checks. Reusable by a future SwiftUI app.
- `Sources/fpga-bridge`: the command-line front end.
- `windows/setup.ps1`: Windows first-run setup.
