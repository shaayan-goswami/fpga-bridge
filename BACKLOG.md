# Backlog

Legend: `[x]` done, `[ ]` todo. Order within a milestone is roughly the order to do it.

## Decisions made

- Digilent boards first.
- Vivado is driven over SSH as Tcl batch jobs. No GUI session, no XVC/JTAG server: the bitstream comes back to the Mac and is flashed locally.
- Swift package: `FPGABridgeCore` (library) + `fpga-bridge` (CLI). SwiftUI app later sits on the library.
- Tailscale for reaching the build machine away from home.

## Open decisions

- [ ] README says "Python 3" and a Python script for the prototype, but the CLI is Swift. Update the README, or add Python only where needed (e.g. helper scripts).
- [ ] Windows only first, or also support a Linux build machine? (Affects shell quoting, setup script, paths.)
- [ ] Which Vivado version to pin and test against.
- [ ] README Quick Start and License lines are stale (LICENSE already exists, MIT).

## M0: Foundation (done)

- [x] Swift package layout, CLI + core library
- [x] `fpga-bridge init` (saves host, user, Vivado path)
- [x] `fpga-bridge doctor` (Tailscale, SSH, Vivado checks)
- [x] `fpga-bridge tcl` (run a Tcl script or inline Tcl in Vivado batch mode over SSH)
- [x] `windows/setup.ps1` (OpenSSH, authorize key, Tailscale check, find Vivado, print init command)
- [x] Unit tests for Tailscale parsing, config, Vivado command quoting
- [ ] Test `windows/setup.ps1` on a real Windows machine (fresh and already-configured)
- [ ] Test `doctor` and `tcl` end to end against that machine, on home LAN and from outside (phone hotspot)
- [ ] Handle Microsoft-account usernames and domain accounts in the setup script's printed `--user`
- [x] CI: build and test on macOS via GitHub Actions, plus a syntax check of `windows/setup.ps1` (workflow written; not yet seen running on GitHub)
- [x] Fake build machine for tests: stub `ssh`/`scp` that only accept the exact commands we should send; covers `doctor`, `build`, `tcl`
- [ ] Run the manual `windows-setup-smoke` CI job (Actions tab > CI > Run workflow) and fix whatever it finds in `setup.ps1`

## M1: Remote builds (CLI)

The items ticked here are implemented and unit-tested locally (project file, Tcl generation), but the SSH/scp steps have not run against a real build machine yet.

- [x] Project file (`fpga-bridge.json`): name, top module, part, sources, constraints
- [x] `fpga-bridge new`: scaffold a project file
- [x] Board presets for `new` (see docs/boards.md)
- [ ] Add Nexys A7-50T once its part grade is confirmed against the physical board or Digilent's manual
- [ ] Zynq boards (Zybo, Arty Z7): need processor-system handling
- [x] Generate `build.tcl` (non-project mode: read sources/XDC, synth, opt, place, route, reports, bitstream)
- [x] Copy project files to the build machine (clean job dir per project)
- [x] `fpga-bridge build`: run the build, stream the live log to the terminal
- [x] Fetch results back: bitstream, timing and utilization reports, full log
- [ ] Non-zero exit and clear message on synthesis/implementation failure
- [x] Parse timing summary (WNS/TNS/WHS/THS, failing endpoint counts) and utilization (LUT, FF, BRAM, DSP, IO) into a short summary; `fpga-bridge report` re-prints it
- [ ] Replace the hand-written report fixtures with real Vivado output from the first real build
- [ ] Show the worst failing paths (needs `report_timing -max_paths` in `build.tcl`)
- [ ] `build --strict`: exit non-zero when timing is not met
- [ ] Incremental behavior: skip copying unchanged files; optional `--clean`
- [ ] Cancel a running build cleanly (Ctrl-C kills the remote Vivado process)
- [ ] Handle dropped SSH connection mid-build (keepalive, reattach to the log, or fail clearly)
- [ ] Lock/queue so two builds don't collide on the same build machine
- [ ] Vivado version check and warning when it differs from the project's pinned version
- [ ] Linux build machine support (if decided above)

## M2: Flashing

- [ ] Detect openFPGALoader; guide install (`brew install openfpgaloader`)
- [ ] `fpga-bridge flash`: program the last built bitstream (SRAM)
- [ ] Optional flash to board's non-volatile memory
- [ ] `fpga-bridge boards`: list connected USB boards
- [ ] macOS USB/driver issues for Digilent (FTDI) boards: document and test, including any Apple driver conflicts
- [ ] Add `flash` checks to `doctor`

## M3: Simulation

- [ ] Detect Verilator and Surfer; guide install
- [ ] `fpga-bridge sim`: build and run a Verilator testbench locally
- [ ] Emit VCD/FST waveforms and open in Surfer
- [ ] Project file section for testbench sources and top

## M4: Mac app (SwiftUI on `FPGABridgeCore`)

- [ ] Move shared logic out of the CLI so both front ends call the same core API
- [ ] First-run setup screen (wraps `doctor`, shows what to do for each failure)
- [ ] Project view and file browser
- [ ] Source editor (Verilog/SystemVerilog highlighting)
- [ ] Build button with live log
- [ ] Timing and utilization summary view
- [ ] Flash button with board selection
- [ ] Simulation button with waveform launch
- [ ] Connection status indicator (Tailscale, SSH, build machine online)
- [ ] Settings: build machine, Vivado path, board

## M5: Distribution and polish

- [ ] Signed and notarized release builds (CLI and app)
- [ ] GitHub Releases workflow (tagged builds, `.dmg` / `.zip`)
- [ ] Homebrew tap for the CLI
- [ ] Real Quick Start in the README (replaces "Not available yet")
- [ ] Docs: build machine setup (sleep off, no auto-restart, pinned Vivado), troubleshooting, supported boards
- [ ] Support more boards beyond Digilent
- [ ] User testing with other students (e.g. a hardware club) and fix what annoys them
- [ ] Contributing guide and issue templates

## Risks to keep an eye on

- [ ] Licensing: never bundle Vivado; keep "bring your own build machine" (README Legal section covers it)
- [ ] First-run setup stays painless (top priority; measure with a fresh tester)
- [ ] Vivado version differences breaking generated Tcl
- [ ] Build machine offline or asleep: detect early and say so
