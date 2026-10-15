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

## The Mac app

```sh
scripts/make-app.sh            # builds dist/FPGA Bridge.app (set SCRATCH_PATH if the repo is under ~/Desktop)
open "dist/FPGA Bridge.app"
```

Or run it straight from the build without packaging: `swift run "FPGA Bridge"`.

With no build machine configured (`fpga-bridge init` not run yet) the app starts in **Demo Mode**: runs are
simulated so you can try the whole flow. Use **Open Example Project** on the start page for a ready-made design.

**FPGA Bridge > Settings… (⌘,)** sets light/dark appearance, the Liquid Glass style (Frosted, Clear, Off), editor and
console font sizes, and whether to show accent colors. The app is grey, with small accents in the colors Vivado itself
uses, each meaning one thing: green for done and for run icons, amber for warnings and out-of-date runs, red for
errors and failures, blue for running steps and Tcl commands, teal for design sources, navy for constraints and cyan
for simulation sources. Settings shows the legend; turn accents off for an all-grey app. Project settings (part, top
module, language, Vivado version) are under **Flow > Settings…**, as in Vivado.

The app icon is an Icon Composer document, `Sources/FPGABridgeApp/Resources/AppIcon.icon`, and follows the
system's **Icon & widget style** (Default, Dark, Clear, Tinted), not the window's light or dark mode. Edit it in
Icon Composer (inside Xcode 26+). `scripts/make-app.sh` compiles it with `actool`; `scripts/render-icon.sh` refreshes
the per-style PNGs used inside the app.

## Editing sources

Double-click or select a file in the Sources pane to open it in an editor tab. It has line numbers, syntax colors, undo
and redo, find (⌘F), Toggle Comment (⌘/), auto-indent, and Tab and Shift-Tab to indent and outdent the selected lines.
A dot on the tab marks unsaved edits. Save with ⌘S (Project > Save File, or ⌥⌘S for all files). Saving a design or
constraint file marks synthesis and implementation out-of-date, as in Vivado; saving a testbench doesn't. Closing a
tab, switching projects or quitting asks first if anything is unsaved.

## Commands

```sh
fpga-bridge doctor                      # Tailscale, SSH and Vivado checks
fpga-bridge tcl build.tcl               # run a local Tcl script in Vivado batch mode
fpga-bridge tcl -c 'puts [version]'     # or inline Tcl
fpga-bridge new --list-boards           # supported Digilent boards (see boards.md)
fpga-bridge new --board basys3 --top top --sources src --constraints constraints
fpga-bridge build                       # copy, run Vivado, fetch results into build/, print summary
fpga-bridge report                      # re-print the timing/utilization summary from build/
fpga-bridge unlock                      # release the build lock on the Windows machine (see below)
```

## Build safety

- **One build at a time.** `build` takes a lock on the Windows machine. If someone else's build holds it you get
  `The build machine is busy: alice@laptop building demo since ...` and nothing is copied. If a build was lost (crash,
  dropped connection) and left the lock behind, run `fpga-bridge unlock`.
- **Ctrl-C cancels cleanly.** It stops the local session, kills Vivado on the Windows machine (found by a per-run marker
  on its command line), and releases the lock. Press it once and wait a moment.
- **Dropped connection.** SSH keepalives make a dead connection fail in about a minute, with a message that names the job
  directory on the build machine. Vivado may still be running there; the lock stays held until you `unlock`.
- **Pin the Vivado version.** `fpga-bridge new ... --vivado-version 2023.2` records it in `fpga-bridge.json`, and `build`
  warns if the build machine is set up for a different version. The version is read from the install path
  (`...\Vivado\2023.2\bin\vivado.bat`).

`build` prints something like:

```
Timing     MET   setup WNS +7.612 ns   hold WHS +0.171 ns
Resources  LUT 12/20800 (0.1%)   FF 8/41600 (0.0%)   BRAM 2.5/50 (5.0%)   DSP 3/90 (3.3%)
```

Timing that is not met does not fail the build (the bitstream is still produced); it is shown as `NOT MET`.

## Layout

- `Sources/FPGABridgeCore`: config, Tailscale status, SSH/Vivado runner, health checks. Reusable by a future SwiftUI app.
- `Sources/fpga-bridge`: the command-line front end.
- `windows/setup.ps1`: Windows first-run setup.

## Developing

```sh
swift build
swift test
```

The tests run `build`, `doctor`, `tcl` and the lock/cancel paths against stub `ssh`/`scp` scripts in `Tests/FPGABridgeCoreTests/FakeRemote/`
that act as a Windows machine. They accept only the exact command lines fpga-bridge should send, so if you change a
remote command, update the stub in the same commit.

If `swift test` fails with "resource fork, Finder information, or similar detritus not allowed", the checkout is in a
folder (such as `~/Desktop`) where macOS adds Finder attributes to build products. Build somewhere else instead:

```sh
swift test --scratch-path /tmp/fpga-bridge-build
```

CI runs on every push and pull request. The `windows-setup-smoke` job runs `windows/setup.ps1` for real on a throwaway
Windows runner; start it by hand from the Actions tab.
