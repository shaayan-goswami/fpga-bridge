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

The app mirrors Vivado's IDE feature for feature. The full inventory, how each feature is delivered and the build
order (P1–P8) live in [docs/vivado-parity.md](docs/vivado-parity.md); this section only tracks the phases.

- [x] Prototype: Quick Start, New Project wizard, Add Sources, Project Settings (General), Flow Navigator, Sources
      hierarchy and properties, Project Summary, source viewer, reports, console panel, demo backend
- [x] Vivado-style project creation in the core (`<name>.srcs/sources_1|constrs_1|sim_1`, Create File, top detection)
- [ ] P1 Flow parity (separate runs with checkpoints, Launch Runs, completion popups, run settings and strategies)
- [ ] P2 Projects and editing (real editor, Define Module, Sources context menus, File and Edit menus)
- [ ] P3 Reports and analysis
- [ ] P4 Program and debug (Hardware Manager via openFPGALoader)
- [ ] P5 Simulation (Verilator/Icarus, waveform viewer)
- [ ] P6 Design views (Netlist, I/O Ports, constraints editors, IP Catalog)
- [ ] P7 Workspace polish (Window/Layout/View/Help, layouts, Quick Access, tool settings)
- [ ] P8 Stretch (schematic, block design viewer)

## Code quality

Found by the review in [docs/code-review.md](docs/code-review.md). Fix the likely bugs first.

- [ ] Cancelling a run can leave two runs going (AppModel `cancelRun`/`execute`); add a test that cancels and starts a second run
- [ ] Cancelling only the bitstream step should not mark `impl_1` as cancelled
- [ ] Reject reserved words as module, port and architecture names (Verilog, SystemVerilog, VHDL)
- [ ] Validate the Vivado path when `init` saves it (quotes, `&`, `%`); reject symlinks that leave the project folder
- [ ] Show an error instead of an empty source tree when sources can't be resolved or the project file can't be re-read
- [ ] Move the 12 `FPGA_BRIDGE_*` debug and screenshot hooks into one file under `#if DEBUG`
- [ ] Move to Swift 6 language mode: 41 strict-concurrency warnings, mostly the log closure and backend crossing tasks; replace the main-queue hop with an `AsyncStream`
- [ ] Split the run engine out of `AppModel`; make accent colors observable so `.id(accents)` can go
- [ ] Verify the `AppleIconAppearanceTheme` values against System Settings
- [ ] De-flake the cancel test (no `Thread.sleep`, no real `SIGINT` to the test process)

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
