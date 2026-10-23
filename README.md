# fpga-bridge

Build FPGA designs from a Mac, even though Vivado doesn't run on macOS.

**[Getting started: install and set up FPGA Bridge on your Mac →](docs/getting-started.md)**
&nbsp;·&nbsp; [Download the app](https://github.com/shaayan-goswami/fpga-bridge/releases/latest)
&nbsp;·&nbsp; [Help test other boards](docs/getting-started.md#help-test-other-boards)

fpga-bridge lets you write, simulate, and flash on your Mac while a remote Windows or Linux machine with Vivado does the heavy build in the background. It comes as a native Mac app (**FPGA Bridge**) that mirrors Vivado's layout and dialogs, so it feels familiar if you already know Vivado, and a command-line tool (`fpga-bridge`) inside it.

![The schematic of an elaborated design, drawn with Vivado's symbols](docs/images/schematic.png)

| Simulation and waveforms | Programming the board |
| --- | --- |
| ![The waveform viewer after a simulation](docs/images/waveform.png) | ![The Hardware Manager after programming a Basys 3](docs/images/hardware-manager.png) |

> **Tested boards: only the Digilent Basys 3 so far.** The whole path works on real hardware: a design written on a Mac, built by Vivado 2025.2 on a Windows machine over Tailscale and SSH, fetched back, simulated, and flashed to a Basys 3. Seven more Digilent boards are set up but untested. **If you have one, please [try it and report back](docs/getting-started.md#help-test-other-boards).** A Linux build machine is supported and tested against a real shell, but not yet with Vivado on real hardware. See [BACKLOG.md](BACKLOG.md) and [docs/vivado-parity.md](docs/vivado-parity.md) for what is done and what is not.

## Why

AMD's Vivado officially supports only Windows and a few Linux distributions. Mac users are stuck with workarounds like virtual machines, Docker with Rosetta, or cloud desktops. These tend to be slow, fragile, and can break after a macOS update.

fpga-bridge takes a different approach: leave Vivado on a machine it officially supports, and make talking to that machine feel native on a Mac.

## How It Works

```
 Mac (you work here)                    Build machine (Windows or Linux)
 -------------------                    --------------------------------
 1. Write Verilog/SV/VHDL
 2. Simulate locally (Icarus Verilog)
    and view the waveform
 3. Hit build  ----- files over SSH ---->  4. Vivado runs in batch mode
                                           5. Bitstream + reports created
 6. Results + live log  <---- SSH -------
 7. Flash board over USB (openFPGALoader)
```

Vivado never runs on the Mac. Only the commands and results travel between machines. The board is plugged into the Mac, so you can take it anywhere; the build machine only needs to be reachable (Tailscale makes that work from outside your home network).

## What works today

**Command line**
- [x] `fpga-bridge init` and `doctor`: save the build machine's details and check Tailscale, SSH, Vivado, the flasher, the simulator and a waveform viewer end to end
- [x] `fpga-bridge new`: create a project for one of 8 Digilent boards, or any Vivado part
- [x] `fpga-bridge build`: copy the project, run Vivado in batch mode (synthesis, implementation, bitstream), stream the log, fetch the results, print a timing and utilization summary
- [x] `fpga-bridge sim`: compile and run the testbench on the Mac with Icarus Verilog and leave a waveform
- [x] `fpga-bridge flash` and `boards`: detect the board and program it with openFPGALoader
- [x] `fpga-bridge report`, `tcl` (run any Tcl on the build machine) and `unlock`
- [x] Windows or Linux build machine, with a setup script for each (`windows/setup.ps1`, `linux/setup.sh`)
- [x] Any Vivado version: nothing is pinned, and a project can record the version it expects to get a warning on a mismatch
- [x] Robust remote handling: one build at a time with a lock, Ctrl-C cancels the remote Vivado too, keepalives, clear messages when the connection drops

**Mac app**
- [x] Vivado's layout: Flow Navigator, Sources, Project Summary, tabbed workspace, Tcl Console, Messages, Log, Reports and Design Runs, with out-of-date run tracking
- [x] New Project wizard (board picker or part), Add Sources, Define Module, project settings
- [x] A real source editor: syntax colors, line numbers, find, undo, auto-indent, toggle comment, unsaved-changes prompts
- [x] **Hardware Manager**: Auto Connect, device properties, Program Device and Program Configuration Memory Device
- [x] **Language Templates**: about 50 Verilog, SystemVerilog, VHDL and XDC templates with search, preview and Insert Template
- [x] **Run Simulation** with a log, Stop, and a **native waveform viewer** (zoom, pan, cursor, bus radix, signal picker)
- [x] **Elaborated, Synthesized and Implemented Design**: the netlist hierarchy with cells, the I/O ports with pins and standards, utilization by module, and the reports of each stage (timing, clocks, power, DRC, methodology, I/O, route status), written by the build and restored when you reopen a project. They open with the build machine asleep: everything is saved on the Mac at build time
- [x] **Netlist window, Properties and Schematic**: browse cells, nets and pins, see every Vivado property, and draw any level as a schematic (Vivado's symbols, modules opened in place, Schematic of selection with F4, Go To Source)
- [x] **Run Linter**: Vivado's RTL linter, with each finding linked to its source line
- [x] **Timing window**: the design's timing summary and its worst setup and hold paths, saved at build time; selecting a path highlights it in the schematic. `fpga-bridge report` lists the worst failing paths
- [x] **Package and Device views, I/O planning**: the chip's pins and banks with your ports on them, drag a port to a pin (written into your XDC, with Vivado's rule checks), and the die with where each cell was placed. `fpga-bridge part` fetches a chip's data once; it is cached on the Mac
- [x] **Block designs (viewing)**: open a block design made in Vivado's IP Integrator and see its diagram, each block's settings and the Address Editor, offline
- [x] **IP Catalog**: browse Vivado's real catalog, customize an IP's settings, get its instantiation template, and have the build create, generate and synthesize it
- [x] **Project Settings**: real Elaboration, Simulation, Synthesis, Implementation and Bitstream pages (macros, include folders, generics, directives, strategies, `.bin` output, compression, simulation options)
- [x] Frosted glass sidebar like Finder's (Liquid Glass available in Settings), light and dark mode
- [x] Works without a build machine or a board: write Verilog, simulate and view waveforms on the Mac; only Vivado's steps need the build machine

**Not built yet** (greyed out or missing; see the backlog for the full list)
- [ ] Separate synthesis and implementation runs with checkpoints, Launch Runs, run strategies, and stopping a live build from the app
- [ ] The report option dialogs (each report is run once, with Vivado's defaults, at build time)
- [ ] Routing in the Device view, floorplanning (pblocks), and the constraints wizards. IP settings have no dropdowns of allowed values, because Vivado doesn't expose them to Tcl.
- [ ] Save As, Archive, Write Tcl, Find and Replace in Files, Sources context menus
- [ ] VHDL and post-synthesis simulation, waveform markers and saved layouts
- [ ] Creating, editing, validating and generating block designs, and building projects that contain one
- [ ] Zynq boards and other FPGA vendors
- [ ] Signed and notarized releases, Homebrew install

## Requirements

**On your Mac**
- A Mac with Apple silicon (M1 or later) and macOS 14 or later. Building from source also needs Xcode.
- [Homebrew](https://brew.sh), then: `brew install openfpgaloader icarus-verilog surfer`
  - openFPGALoader flashes the board (check that your board is on its supported list)
  - Icarus Verilog runs simulations; Surfer is an optional external waveform viewer (the app has its own)
- Tailscale (optional, for reaching the build machine from outside your home network)

**On the build machine**
- Windows or Linux with Vivado, installed by you (the free edition covers many boards). Any Vivado version works.
- An SSH server (the setup script enables it on Windows; on Linux it can install one with `--install-ssh`)
- On Linux, Vivado must start from a login shell (`ssh <host> vivado -version` should work), because fpga-bridge runs it through `bash -lc`
- Stays powered on and awake while you build

**Hardware**
- An FPGA board supported by both Vivado and openFPGALoader, plus a USB data cable. The 8 boards in [docs/boards.md](docs/boards.md) are set up; for another AMD/Xilinx part, pass `--part`.

## Install

Follow **[Getting started](docs/getting-started.md)**. It covers each step with links: downloading the app,
installing Homebrew, Icarus Verilog and openFPGALoader, installing Vivado and Tailscale on the Windows PC, running
the setup script, connecting the two, and building and programming your first design.

Writing Verilog and running simulations needs only the Mac. The Windows PC is needed only to build bitstreams.

### Commands

| Command | What it does |
| --- | --- |
| `init` | Save the build machine's host, user, Vivado path (and SSH key). `--os windows\|linux` if it can't be worked out from the path |
| `doctor` | Check Tailscale, SSH, Vivado, openFPGALoader, Icarus Verilog and a waveform viewer |
| `ip` | `list`, `config`, `add`, `remove`, `show`: browse Vivado's IP catalog and add IP to the project |
| `script` | Print the Vivado Tcl that `build` would run, with the project's settings |
| `new` | Create `fpga-bridge.json`. `--board <id>` (see `--list-boards`) or `--part <part>`, `--top`, `--sources`, `--constraints` |
| `build` | Copy, run Vivado, fetch results into `build/`, print timing and utilization |
| `report` | Show the timing and utilization summary of the last build |
| `sim` | Simulate the testbench locally. `--top`, `--timeout`, `--open` (open the waveform in Surfer) |
| `flash` | Program the board. `--persist` writes its flash instead; `--board` overrides the project's board |
| `boards` | Show what is plugged in; `--list` shows the supported boards |
| `tcl` | Run a Tcl script in Vivado batch mode on the build machine |
| `unlock` | Release the build lock after a crashed build |

More detail: [docs/setup.md](docs/setup.md), [docs/boards.md](docs/boards.md).

The command-line tool is inside the app; [Getting started](docs/getting-started.md#13-make-the-fpga-bridge-command-available) shows how to make `fpga-bridge` available in Terminal.

## Remote Access Tips

- Install Tailscale on both machines and sign in with the same account. Your Mac can then reach the build machine from anywhere with no router changes. On a shared network (a dorm or apartment building) devices often can't see each other directly, and Tailscale is what makes the connection work.
- Turn off sleep on the build machine, and stop Windows from restarting for updates mid-build.
- Pin one Vivado version on the build machine so builds stay consistent. A project can record its version (`--vivado-version`) and builds warn on a mismatch.

## Troubleshooting

- **"Component store has been corrupted" while setting up OpenSSH:** run `DISM /Online /Cleanup-Image /RestoreHealth` and `sfc /scannow` as Administrator, restart, and run the setup script again. Or install OpenSSH with `winget install Microsoft.OpenSSH.Beta`; the script accepts it.
- **SSH times out though the machine is reachable:** the Windows firewall rule must apply to every network type (a home network is often "Public"). The setup script creates it that way.
- **The app says Offline but `doctor` passes:** update to the latest build. Tailscale's command-line tool needs the `TERM` variable that a Finder-launched app doesn't have; the app now sets it.
- **"No application set to open sim.vcd":** nothing on the Mac opens waveforms. The app's Waveform tab works without anything installed; for an external viewer run `brew install surfer`.
- **Linux: "Vivado is there but didn't start from a login shell":** fpga-bridge runs Vivado through `bash -lc`, so its license and environment settings must load from your login files (`~/.profile` or `~/.bash_profile`), not only `~/.bashrc`.
- **A different board:** see [docs/boards.md](docs/boards.md). For a board that is not listed, use `--part`, and `flash` will use the Digilent cable setting.

## Roadmap

1. **CLI prototype:** done. A Tcl build script plus a Swift CLI that copies files over SSH, runs the Vivado build, and pulls results back
2. **Basic Mac app:** done as a prototype. The Run buttons need to be checked against a real build machine
3. **Simulation and flashing:** done. Icarus Verilog runs with a built-in waveform viewer, and board programming through openFPGALoader
4. **Flow parity:** separate synthesis and implementation runs, Launch Runs, run strategies, reports, project and editor polish
5. **Polish:** signed releases, easier first-run setup, support for more boards, user testing

## Known Limitations

- Requires a separate machine that can run Vivado
- If the build machine is off or offline, builds can't run
- Verified on real hardware only with a Basys 3, a Windows build machine and Vivado 2025.2. Other Digilent boards and a Linux build machine are supported but untested on real hardware.
- Every build runs as one script, so synthesis, implementation and bitstream can't yet be run separately, and a live build can't be stopped from the app (the CLI's Ctrl-C works)
- Simulation covers Verilog and SystemVerilog only
- Some boards may need extra USB drivers or settings on macOS
- Different Vivado versions behave differently, so one version per build machine is recommended

## Development

To build from source instead of downloading the app (needs Xcode, macOS 14 or later):

```sh
git clone https://github.com/shaayan-goswami/fpga-bridge.git && cd fpga-bridge
scripts/make-app.sh            # builds dist/FPGA Bridge.app, with the fpga-bridge tool inside
```

Other commands:

```sh
swift build                    # debug build of everything
swift test                     # the automated tests (a scratch path outside ~/Desktop avoids code-signing xattr problems: --scratch-path)
scripts/make-app.sh            # release build and dist/FPGA Bridge.app
```

The code is a Swift package: `FPGABridgeCore` (the library), `fpga-bridge` (the CLI) and `FPGABridgeApp` (the SwiftUI app). Tests use fake `ssh`, `scp` and `openFPGALoader` programs, and run the real Icarus Verilog when it is installed. Continuous integration runs on every push, including a job that runs the Windows command lines through a real `cmd.exe`.

## Legal

fpga-bridge does not include, bundle, or redistribute Vivado. You must install Vivado yourself and comply with AMD's license terms. Vivado and Xilinx are trademarks of AMD. Apple, Mac, and macOS are trademarks of Apple Inc. This project is independent and is not affiliated with or endorsed by AMD or Apple.

## Feedback

Bug reports, board test results and ideas are welcome as [issues](https://github.com/shaayan-goswami/fpga-bridge/issues/new). Code contributions aren't accepted. [docs/feedback.md](docs/feedback.md) lists the feedback received so far and what is being done about it.

## License

MIT. See [LICENSE](LICENSE).
