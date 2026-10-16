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
- [ ] Confirm the new `windows-cmd-lines` CI job passes on GitHub (runs the lock/prep/unlock/cancel command lines through a real cmd.exe); fix whatever it finds
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
- [x] Cancel a running build cleanly: Ctrl-C kills the remote Vivado process tree (found by a per-run marker on its command line), releases the lock, exits 130
- [x] Dropped SSH connection mid-build: keepalives, and a clear error naming the job directory and `fpga-bridge unlock`
- [ ] Reattach after a lost connection: keep Vivado's log in a file on the build machine and add `fpga-bridge fetch` to collect results from a build that finished without us
- [x] Build lock so two builds don't collide on the same build machine (shows the owner when busy; `fpga-bridge unlock` clears a stale one)
- [ ] Queue instead of failing when busy (`build --wait`), and expire locks left by a crashed build
- [x] Vivado version pin (`new --vivado-version`) with a warning when the build machine's configured install differs (version read from the install path)
- [ ] Check the real version with `vivado -version` instead of trusting the path
- [ ] Linux build machine support (if decided above)

## M2: Flashing

- [x] Detect openFPGALoader; guide install (`brew install openfpgaloader`). Verified with openFPGALoader 1.1.1
- [x] `fpga-bridge flash`: program the last built bitstream (SRAM). Verified on a real board (loaded a blinky design built remotely)
- [ ] `fpga-bridge flash --persist`: written, not yet run on hardware
- [x] `fpga-bridge boards`: show what's plugged in (`--list` for the supported boards)
- [x] Checked each board's `loaderName` against `openFPGALoader --list-boards` (fixed the two Cmod names)
- [ ] macOS USB/driver issues for Digilent (FTDI) boards: document and test, including any Apple driver conflicts
- [x] `doctor` checks that openFPGALoader is installed

## M3: Simulation

- [x] Detect Icarus Verilog; guide install (`brew install icarus-verilog`). Icarus first for its instant start; Verilator is still an option for big designs
- [ ] Detect a waveform viewer (Surfer, GTKWave); today Open Waveform uses whatever handles `.vcd`
- [x] `fpga-bridge sim`: compile and run the testbench locally (Verilog and SystemVerilog; VHDL needs GHDL)
- [x] Emit a VCD waveform to `<project>.sim/sim_1/behav/sim.vcd` (Vivado's layout, so a build never deletes it) (no change to the testbench needed)
- [ ] FST waveforms, VHDL via GHDL, post-synthesis simulation
- [ ] Project file section for testbench sources and top

## M4: Mac app (SwiftUI on `FPGABridgeCore`)

The app mirrors Vivado's IDE feature for feature. The full inventory, how each feature is delivered and the build
order (P1–P8) live in [docs/vivado-parity.md](docs/vivado-parity.md); this section only tracks the phases.

- [x] Prototype: Quick Start, New Project wizard, Add Sources, Project Settings (General), Flow Navigator, Sources
      hierarchy and properties, Project Summary, source viewer, reports, console panel, demo backend
- [x] Vivado-style project creation in the core (`<name>.srcs/sources_1|constrs_1|sim_1`, Create File, top detection)
- [x] Create Source File and Define Module dialogs (module name, I/O port table), with Verilog, SystemVerilog and VHDL
      skeletons written from the definition; wired into the New Project wizard and Add Sources
- [x] Look: Liquid Glass surfaces (material fallback before macOS 26), frosted home window, grey UI with accent colors
      sampled from Vivado, Settings window (appearance, glass style, accents, font sizes), collapsible Flow Navigator
- [x] App icon as an Icon Composer document that follows the system Icon & widget style; `scripts/make-app.sh` builds
      and ad-hoc signs `FPGA Bridge.app`
- [x] Editable source editor: line numbers, syntax colors, undo and redo, find, comment toggle, auto-indent, ⌘S, an
      "edited" dot on the tab, and a "save changes?" prompt when closing a tab, switching projects or quitting; saving a
      design or constraint file marks finished runs out-of-date
- [x] Near-black dark mode (window, sidebars, editor and console surfaces)
- [ ] P1 Flow parity (separate runs with checkpoints, Launch Runs, completion popups, run settings and strategies)
- [ ] P2 Projects and editing (Sources context menus, File and Edit menus, Replace in Files, go to line; the editor and Define Module are done)
- [ ] P3 Reports and analysis
- [x] P4 Program and debug: Hardware Manager screen, Program Device and Program Configuration Memory sheets (debug cores stay on Windows)
- [x] P5 Simulation: Run Simulation tab with log, Stop, and Open Waveform. Still to do: simulation settings, a native waveform viewer
- [ ] P6 Design views (Netlist, I/O Ports, constraints editors, IP Catalog)
- [ ] P7 Workspace polish (Window/Layout/View/Help, layouts, Quick Access, tool settings)
- [ ] P8 Stretch (schematic, block design viewer)

## Code quality

Found by the review in [docs/code-review.md](docs/code-review.md). Fix the likely bugs first.

- [x] Cancelling a run can leave two runs going; tested (cancel, then start a second run)
- [x] Cancelling only the bitstream step no longer marks `impl_1` as cancelled
- [x] Reject reserved words as module, port and architecture names (Verilog, SystemVerilog, VHDL)
- [x] Validate the Vivado path when `init` saves it (quotes, `&`, `%`); reject symlinks that leave the project folder
- [x] Show an error instead of an empty source tree when sources can't be resolved or the project file can't be re-read
- [x] Move the `FPGA_BRIDGE_*` debug and screenshot hooks into one file under `#if DEBUG`
- [x] Zero strict-concurrency warnings, and `StrictConcurrency` is on for every target. Still open: Swift 6 language mode, and replacing the main-queue hop with an `AsyncStream`
- [x] Fullscreen: the window is solid instead of flat-gray glass
- [ ] Split the run engine out of `AppModel`; make accent colors observable so `.id(accents)` can go
- [ ] Verify the `AppleIconAppearanceTheme` values against System Settings
- [x] De-flake the cancel test

## M5: Distribution and polish

- [ ] Signed and notarized release builds (CLI and app)
- [ ] GitHub Releases workflow (tagged builds, `.dmg` / `.zip`)
- [ ] Homebrew tap for the CLI
- [ ] Real Quick Start in the README (replaces "Not available yet")
- [ ] Docs: build machine setup (sleep off, no auto-restart, pinned Vivado), troubleshooting (supported boards are in docs/boards.md)
- [ ] Replace `codesign --deep` in `scripts/make-app.sh` with signing nested code individually
- [ ] Update README: it still says Python 3 is required and that nothing is built
- [ ] Support more boards beyond Digilent
- [ ] User testing with other students (e.g. a hardware club) and fix what annoys them
- [ ] Contributing guide and issue templates

## Risks to keep an eye on

- [ ] Licensing: never bundle Vivado; keep "bring your own build machine" (README Legal section covers it)
- [ ] First-run setup stays painless (top priority; measure with a fresh tester)
- [ ] Vivado version differences breaking generated Tcl
- [ ] Build machine offline or asleep: detect early and say so
