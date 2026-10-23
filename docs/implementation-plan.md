# Implementation plan: the features not built yet

This covers everything in the README's **Not built yet** list. For each feature: what Vivado does (the target, since
the app mirrors Vivado), what exists today, the design, the steps in order, how to test it, and the risks. Written
19 October 2026, against `main` at 0.2.0.

Every feature keeps the rules the app already follows:

- **Mirror Vivado** (names, dialogs, behavior), with the Mac's look. Anything not built yet stays greyed out with a
  reason ([docs/vivado-parity.md](vivado-parity.md) is the inventory).
- **Offline first.** Whatever a build produces is saved on the Mac; the PC is needed only for builds and one-off jobs.
- **Works without a PC or a board.** Editing and simulation never depend on them; Vivado steps say why they can't run.
- **Check every Vivado command and option on real Vivado** before shipping it, as was done for the directives.
- **Never bundle Vivado** or anything from its install.

## Summary

| # | Feature | Size | Needs | Depends on |
| --- | --- | --- | --- | --- |
| 1 | [Projects and editing](#1-projects-and-editing): Save As, Archive, Write Tcl, Find and Replace in Files, Sources context menus | M | Mac only | — |
| 2 | [Waveform markers and saved layouts](#2-waveform-markers-and-saved-layouts) | S | Mac only | — |
| 3 | [Separate runs with checkpoints, Launch Runs, strategies, Stop](#3-separate-runs-with-checkpoints-launch-runs-strategies-stop) | L | PC to verify | — |
| 4 | [Report option dialogs](#4-report-option-dialogs) | M | PC | 3 |
| 5 | [Signed and notarized releases, Homebrew](#5-signed-and-notarized-releases-homebrew) | S–M | Apple Developer account | — |
| 6 | [VHDL and post-synthesis simulation](#6-vhdl-and-post-synthesis-simulation) | M | Mac; PC once per build | 3 (for the netlist) |
| 7 | [Device view, pin planning, constraints wizards](#7-device-view-pin-planning-constraints-wizards) | L | PC once per part | — |
| 8 | [Zynq boards and other FPGA vendors](#8-zynq-boards-and-other-fpga-vendors) | L | A Zynq board to test | 3 |

S = one session, M = two or three, L = a week or more of sessions.

**Recommended order:** 1 and 2 first (no PC needed, quick to show), then 3 and 4 together, then 5 as soon as the
Apple Developer account exists (it can slot in anywhere), then 6, 7, 8. One release per finished group:
0.3.0 after 1–2, 0.4.0 after 3–4, and so on.

**Decisions needed from you** (marked **Decision** below): the Apple Developer account (5), whether to support other
FPGA vendors at all (8), and how far Zynq support goes (8).

---

## 1. Projects and editing

### Vivado

- **File > Project > Save As:** copies the whole project to a new name and folder, then opens the copy.
- **File > Project > Archive:** a zip of the project, optionally with run results.
- **File > Project > Write Tcl:** a script (`write_project_tcl`) that recreates the project.
- **Edit > Find in Files / Replace in Files:** search the project's sources, results in a panel, click to open at the line.
- **Sources window context menu:** Open File, Replace File, Remove File from Project, Enable/Disable File, Move to
  Design/Simulation Sources, Set as Top, Set Used In, Copy File Into Project, Hierarchy Update, Refresh Hierarchy,
  Source Node Properties.

### Today

The Project menu has New, Open, Open Recent, Open Example and Close (`AppCommands` in `FPGABridgeApp.swift`). The
Sources pane (`Views/SourcesPane.swift`) has no context menu. `fpga-bridge script` already prints the build script.
Project files are created by `ProjectCreator` (`<name>.srcs/sources_1`, `constrs_1`, `sim_1`, as Vivado lays them out).

### Design and steps

1. **Core: project operations** in a new `ProjectOperations.swift` in `FPGABridgeCore`, each one pure file work with
   tests: `saveAs(to:name:includeResults:)` (copies the folder, renames `<name>.srcs`/`.sim` and the name in
   `fpga-bridge.json`), `archive(to:includeResults:)` (zip with `ditto -c -k --norsrc`), `remove(file:)`,
   `setEnabled(file:_:)`, `move(file:to: SourceSet)`, `setTop(_:)`, `replace(file:with:)`, `copyIntoProject(_:)`.
   Enabled/disabled needs a new optional `disabled: [String]` in the project file, honored by `resolveSources`.
2. **Save As dialog and Archive dialog** (Vivado's options: name, location, include run results).
3. **Write Tcl:** two outputs from one dialog. (a) The build script FPGA Bridge runs (exists). (b) A **project-mode
   script** (`create_project`, `add_files`, `set_property top`, the settings as run properties), so the project opens
   in Vivado's GUI on the PC. Verify (b) by sourcing it in Vivado on the PC and building the result.
4. **Find in Files / Replace in Files:** a core search over the resolved sources (text, case, whole word, regex; file
   types) returning file, line, column and the line's text. Results in a new console tab, **Find Results**, like
   Vivado's; clicking opens the file at the match (the editor already supports revealing a range). Replace works on
   the app's drafts, so unsaved edits are respected and each file's change can be undone; a preview lists every change
   before applying.
5. **Sources context menu** with Vivado's items above, plus **Show in Finder** and **Copy Path** (Mac additions).
   Items that need something not built stay greyed with a reason.
6. Menus: File > Project gains Save As, Archive, Write Tcl; Edit gains Find in Files and Replace in Files (⇧⌘F).

### Tests

Core tests for every operation (on temp projects, including CR LF files and names with spaces); app tests that each
menu item changes the project and marks runs out of date where Vivado would (moving a file into design sources does,
into simulation sources doesn't). Real check: Write Tcl's project-mode script opened in Vivado 2025.2.

### Risks

Save As of a project with absolute paths outside the folder (the project file only allows relative ones, so low).
Replace in Files across hundreds of files: make it cancelable.

---

## 2. Waveform markers and saved layouts

### Vivado

Markers (Add Marker at the cursor, drag them, the time between the cursor and a marker shown in the timeline), and
waveform configuration files (`.wcfg`) that save the signal list, order, radixes, groups and zoom, and reopen with the
next simulation.

### Today

`WaveformModel.swift` and `Views/WaveformView.swift`: zoom, pan, cursor, bus radix, signal picker. No markers, and the
signal list resets each run.

### Design and steps

1. **Markers** in the model: add at the cursor (toolbar button and `M`), drag, delete, rename. The ruler shows each
   marker; the status line shows the time from the cursor to the nearest marker, and between two selected markers.
2. **Layouts:** the signal list, order, radixes, dividers and zoom saved as JSON next to the waveform
   (`<project>.sim/sim_1/behav/<testbench>.wcfg.json`; Vivado's `.wcfg` is undocumented XML, so not that format).
   Restored automatically when the same testbench runs again; signals that no longer exist are dropped with a note.
   Save Waveform Configuration As / Open in the waveform toolbar.

### Tests

Model tests: markers at exact times, deltas, a layout saved and restored, a layout naming signals that disappeared.

---

## 3. Separate runs with checkpoints, Launch Runs, strategies, Stop

### Vivado

`synth_1` and `impl_1` are separate runs. Each saves a checkpoint (`.dcp`), so changing a constraint reruns only
implementation, and Generate Bitstream after implementation runs only `write_bitstream`. **Launch Runs** asks for the
number of jobs. Runs have **strategies** (named sets of options, e.g. `Flow_PerfOptimized_high`). A run can be
stopped. When a run finishes, a dialog offers the next step (Open Synthesized Design, Run Implementation, View
Reports).

### Today

The app already plans steps like Vivado (`RunPlanner.swift`: what reruns when something is out of date), but the
build machine runs one script that does everything (`Project.buildScript`), so every step is a full build. The job
folder on the PC is deleted before each build (`Remote.prepCommand`), and the fetch replaces `build/` entirely.
Stopping works from the command line (Ctrl-C kills the remote Vivado by a per-run marker, `cancelRemoteJob`), but not
from the app (`LiveBackend.canStop = false`). Implementation strategies exist as named sets of directives
(`ProjectSettings.Implementation.strategies`); synthesis has none.

### Design

- **Three scripts instead of one**, each in its own run folder on the PC that survives between builds:
  - `synth_1`: read the sources, `synth_design`, `write_checkpoint -force out/post_synth.dcp`, the synthesis reports
    and design data.
  - `impl_1`: `open_checkpoint ../synth_1/out/post_synth.dcp`, opt, place, route, `write_checkpoint -force
    out/post_route.dcp`, reports and design data.
  - `write_bitstream`: `open_checkpoint ../impl_1/out/post_route.dcp`, the bitstream properties, `write_bitstream`.
- **Checkpoints stay on the PC** (they can be hundreds of MB); reports, design data and the bitstream come back as now.
  Each run's manifest (from 0.2.0) is kept on the Mac per run, so the app knows exactly which sources a checkpoint was
  built from.
- **Before a later step uses a checkpoint**, check it exists on the PC and that its manifest matches (another Mac may
  have built a different version, or the PC was cleaned). If not, rerun the earlier step automatically and say why.
- **Fetching** merges into `build/` instead of replacing it: a synthesis run replaces the synthesis files and removes
  the implementation results (now stale); an implementation run replaces only its own.
- **Stop** from the app: `Remote` returns a job handle with `cancel()` (the same kill-by-marker the CLI uses);
  `LiveBackend.canStop = true`; the run shows as cancelled, and the lock is released.
- **Launch Runs dialog:** number of jobs (`set_param general.maxThreads`), and which runs.
- **Strategies:** add Vivado's synthesis strategies as named option sets, like the implementation ones. Check each
  strategy's options on real Vivado, the way the 27 directives were checked.
- **Completion dialog** after each run, with Vivado's choices.

### Steps

1. Core: split `buildScript` into `synthScript`, `implScript`, `bitstreamScript`; per-run remote folders; the
   cleanup command removes only the run being redone. Keep `fpga-bridge build` doing all three in one connection so
   the command line stays as fast as today.
2. Core: `Remote.run(step:)` with the checkpoint check, the merging fetch, and per-run manifests.
3. Fake remote tests: each step alone, implementation after a constraint change (synthesis not rerun), a missing
   checkpoint (synthesis rerun), cancel mid-implementation.
4. App: `LiveBackend` runs one step at a time; Stop; Launch Runs dialog; completion dialog; Design Runs shows each
   run's real status and time.
5. Strategies for synthesis, verified on the PC.
6. Real check on the PC: full build, then a constraint change (implementation only, and faster), then Stop during
   routing, then Generate Bitstream alone.

### Risks

Checkpoint size and disk use on the PC: keep only the latest per run. A run killed mid-`write_checkpoint` leaves a
broken file: write to a temporary name and rename.

---

## 4. Report option dialogs

### Vivado

Reports > Report Timing Summary, Report Timing, Report Utilization, Report Power, Report DRC, Report Methodology,
Report Clock Interaction, Report Noise, and others, each with an options dialog (e.g. Report Timing: from, to,
through, number of paths, delay type). Results open as named report tabs (`timing_1`).

### Today

Each report runs once at build time with Vivado's defaults (`DesignDump.reports`) and is shown from `build/`, also
offline. The Reports menu and Flow Navigator open those files.

### Design

- A report with chosen options is a **one-off job on the PC**: `open_checkpoint` of the run's checkpoint (from 3),
  the report command with the options, `-file`, then fetch that one file. A few seconds plus Vivado's start-up.
- Results are saved in `build/reports/` with their options, so they open offline later, like everything else.
- The dialogs mirror Vivado's, starting with Report Timing Summary, Report Timing, Report Utilization and Report
  Power; the rest follow the same pattern. Each option is checked against real Vivado before it ships.
- With the PC offline or no checkpoint yet, the dialogs say why and offer the build-time reports.

### Steps

1. Core: a report request (command plus options) that builds a validated Tcl line; a `Remote.report(...)` one-off job.
2. App: the four dialogs, report tabs with Vivado's names, the saved-results list in the Reports menu.
3. Tests: Tcl generation for every option, the fake remote job, the offline message.
4. Real check: each dialog's options on the demo design, compared with the same report run in Vivado's GUI.

---

## 5. Signed and notarized releases, Homebrew

### Why

Today a new user has to run `xattr -dr com.apple.quarantine` before the app opens. A notarized app opens with a
double-click. Homebrew also needs it: it disabled the GHDL cask on 1 September 2026 for failing Gatekeeper, so an
unsigned FPGA Bridge cask wouldn't be accepted either.

### Decision

**An Apple Developer Program membership** ($99 a year, in your name) is required. Everything else can be automated.

### Steps

1. **You:** join the Apple Developer Program; create a **Developer ID Application** certificate; create an App Store
   Connect API key for notarization.
2. `scripts/make-app.sh`: sign the command-line tool, then the app, with the Developer ID, the hardened runtime
   (`--options runtime`) and a secure timestamp. The app can't be sandboxed (it runs `ssh`, `scp`, openFPGALoader and
   Icarus), which is fine outside the App Store.
3. Notarize with `xcrun notarytool submit --wait`, staple with `xcrun stapler staple`, then zip.
4. **Release workflow** in GitHub Actions on each `v*` tag: import the certificate from repository secrets into a
   temporary keychain, build, sign, notarize, and attach the zip to the release, so releases no longer need dragging
   files by hand.
5. **Homebrew tap** (`shaayan-goswami/homebrew-tap`) with a cask that installs the app, links the `fpga-bridge`
   command (`binary` stanza), and depends on `openfpgaloader` and `icarus-verilog`. Setup becomes
   `brew install --cask shaayan-goswami/tap/fpga-bridge`, replacing steps 1.1 to 1.5 of the guide.
6. Optional: a universal build (`--arch arm64 --arch x86_64`) for Intel Macs; in-app updates with Sparkle.
7. Update the guide and README (no `xattr` step), and check a fresh download on another Mac.

---

## 6. VHDL and post-synthesis simulation

### Vivado

Run Simulation > Run Behavioral Simulation (Verilog and VHDL, mixed) and Run Post-Synthesis Functional Simulation
(the synthesized netlist with Xilinx's primitive models).

### Today

Icarus Verilog runs Verilog and SystemVerilog testbenches (`Simulator.swift`); a VHDL project gets "VHDL isn't
supported" (`SimulatorError.vhdlUnsupported`).

### Design: VHDL

- **GHDL is out:** its Homebrew cask was disabled on 1 September 2026 (it fails Gatekeeper). **NVC** is the
  alternative: a VHDL-2008/2019 simulator, bottled for Apple silicon in Homebrew (`brew install nvc`, version 1.23).
  It runs as a separate program, so its GPL license doesn't affect FPGA Bridge.
- The simulator is picked by the testbench's language; `doctor` and the guide gain an NVC line.
- NVC writes FST waveforms. Check whether it can write VCD; if not, add an FST reader to the waveform viewer (the
  format is documented; GTKWave's reader is MIT-licensed as a reference).
- **Mixed Verilog and VHDL** isn't covered by either simulator in a supported way: detect it and say so.

### Design: post-synthesis

- Synthesis also writes the functional netlist: `write_verilog -mode funcsim -force out/<top>_funcsim.v` (checked on
  real Vivado first).
- Xilinx publishes its primitive models (UNISIM) on GitHub under Apache 2.0 (`Xilinx/XilinxUnisimLibrary`). The app
  downloads them once (pinned to a commit, checked against a hash) into Application Support, never bundles them.
- Icarus compiles the netlist with `glbl.v` and the needed primitives (`-y` on the UNISIM folder) plus the testbench.
- **Check which 7-series primitives Icarus accepts** (FDRE, LUT1–6, CARRY4, IBUF, OBUF, BUFG, MUXF7/8, SRL16E,
  RAMB18/36). Anything it rejects is reported by name instead of a compile error wall.
- Post-implementation timing simulation (SDF) is left out: Icarus's SDF support is too limited.

### Steps

1. NVC: `Simulator` gains a backend per simulator; the waveform path for FST (reader or conversion).
2. Post-synthesis: the netlist written at build time; the UNISIM download; the Run Post-Synthesis Functional
   Simulation command in the Flow Navigator and Run Simulation menu.
3. Tests: a VHDL counter and testbench under NVC; the demo design's funcsim netlist under Icarus with the same
   testbench as the behavioral run, comparing the outputs.

---

## 7. Device view, pin planning, constraints wizards

### Vivado

The **Package** view (the FPGA's pins, banks and their I/O standards), the **Device** view (the die: tiles, clock
regions, where each cell is placed), **I/O Planning** (assigning ports to pins by dragging, with rule checks), and the
**Timing Constraints** and **Constraints** wizards (clocks, generated clocks, I/O delays, false paths), all writing
XDC.

### Today

The I/O Ports table shows each port's pin and standard (from the build's design data). No package or device drawing;
the constraints editors are greyed out.

### Design

- **Part data is per part, not per design:** a one-off job on the PC dumps a part's package pins (name, bank, function,
  differential pair, I/O type) and banks (supported voltages), and a summary of the die (tiles by type and grid
  position, clock regions). Cached on the Mac like the IP catalog, so it works offline afterwards. Check the size for
  the biggest supported part.
- **Package view** (first, read-only): the pin grid drawn from the pin names, banks colored, the design's ports
  overlaid, linked to the I/O Ports table and the shared selection (as the schematic is).
- **Pin planning:** drag a port onto a pin, or edit the table; the app checks bank voltage compatibility and
  differential pairs, then writes `PACKAGE_PIN` and `IOSTANDARD` into the project's XDC, editing only those lines.
- **Device view:** the die from the cached tiles, with placed cells from the implemented design's `LOC`/`BEL`
  properties (already in the design data); routing later.
- **Timing Constraints wizard:** clocks found in the synthesized design (from the build's clock reports), forms for
  clock periods, generated clocks, input and output delays, false paths and multicycle paths, written as XDC.

### Steps (each a separate release)

1. Part data job and cache; the package view, read-only. **Done** (xc7a35t: 446 KB in 53 s; xc7a100t: 818 KB in 79 s).
2. Pin planning with rule checks and XDC writing. **Done.**
3. The Timing Constraints wizard.
4. The device view with placement. **Done**; routing and floorplanning next.

Tests: the XDC writer keeps every unrelated line; rule checks on known bad assignments; the Basys 3's package view
compared with Vivado's.

---

## 8. Zynq boards and other FPGA vendors

### Zynq (Zybo Z7, Arty Z7, PYNQ-Z2)

- **Step 1, logic only:** a design that uses only the FPGA fabric builds and programs like any other (openFPGALoader
  can program a Zynq's FPGA over JTAG). Needs the parts (`xc7z010clg400-1`, `xc7z020clg400-1`) in the board catalog
  and their constraints templates. Small.
- **Step 2, the processor:** clocks, resets and AXI from the ARM side need a block design with the processing system.
  A generated one from a template (Tcl `create_bd_design`, `processing_system7` with the board preset, a wrapper) is
  practical; Vivado's IP Integrator canvas is a large separate feature. Running software on the ARM needs Vitis, which
  is out of scope.
- **Decision:** stop at step 1, or go on to step 2. Either way, a Zynq board is needed to test.

### Other vendors

- Lattice (iCE40, ECP5) could use the open-source tools (Yosys, nextpnr), which run on the Mac itself, with no build
  machine. Intel/Altera would need Quartus on the PC, a second remote flow.
- **Decision:** this changes what FPGA Bridge is ("Vivado from a Mac"). Recommendation: not now; revisit if users ask.

---

## Block designs (IP Integrator)

**Viewing is done (wave 1):** a project's `.bd` files are read on the Mac (JSON; each IP's pins come from its `.xci`), drawn with the schematic engine, with Block Design Properties and the Address Editor. Builds ignore block designs for now and say so in the Tcl Console.

**Wave 2, building (with the Flow track):** upload each block design's folder (`.bd` and `ip/`); in the build script, before synthesis: `read_bd`, `generate_target all`, `make_wrapper -files [get_files x.bd] -top`, then read the wrapper (`.gen/sources_1/bd/<name>/hdl/<name>_wrapper.v`); allow `top` to be `<name>_wrapper`; include `.bd`/`.xci` in the build manifest so editing a block design marks runs out of date; export the `.xsa` for Vitis.

**Wave 2, editing:** Create Block Design, Add IP (from the IP Catalog; pins from a cached Vivado query), connect, Make External, Customize Block; Run Connection Automation, Assign Addresses and Validate Design run as one Vivado job that replays the edits and returns the saved `.bd`. Still to check on Vivado: excluded address segments, 64-bit address spaces, Zynq `processing_system7`, slave-mode external interface ports.

## When each is done

For every feature: the tests above pass, the real-hardware check is done where one is listed, the greyed-out entries
it replaces are live, `docs/vivado-parity.md` and the README's lists are updated, and `docs/feedback.md` records any
feedback it answers.
