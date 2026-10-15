# Vivado parity plan

Goal: someone who knows Vivado can use FPGA Bridge with no learning curve. Same layout, same menus, same dialogs,
same flow behavior. Only the look changes, to the macOS design language.

Vivado's GUI is proprietary, so this is built from AMD's documentation (UG893 *Using the Vivado IDE*,
UG895 *System-Level Design Entry*, UG904 *Implementation*, UG906 *Design Analysis*, UG908 *Programming and
Debugging*, UG910 *Getting Started*) and Vivado's documented Tcl commands, not from Vivado's code.

## How each feature is delivered

| Mark | Meaning |
| --- | --- |
| **Mac** | Built natively in the app; no Vivado needed. |
| **Remote** | Vivado computes it on the build machine (batch Tcl); the app shows the result natively. |
| **Local tool** | A Mac tool does Vivado's job (openFPGALoader for programming, Verilator/Icarus for simulation). |
| **Not possible** | Can't work on a Mac; the row says why and what we offer instead. |

Status values: **Done**, **Prototype** (works, not complete), **Todo**.

---

## 1. Start-up

| Vivado feature | How | Status |
| --- | --- | --- |
| Getting Started page: Quick Start (Create Project, Open Project, Open Example Project) | Mac | Done |
| Recent Projects list | Mac | Done |
| Tasks (Manage IP, Open Hardware Manager, Vivado Store) | Mac / Local tool | Prototype (Hardware Manager disabled until P4) |
| Learning Center (Documentation, Quick Take Videos, Release Notes) | Mac (links to our docs and AMD's) | Prototype |
| Example projects list (Open Example Project wizard with templates) | Mac | Prototype (one example) |

## 2. Menus

### File

| Item | How | Status |
| --- | --- | --- |
| Project ▸ New… (New Project wizard) | Mac | Done |
| Project ▸ Open…, Open Recent, Close | Mac | Done (Close confirmation Todo) |
| Project ▸ Save As… | Mac | Todo |
| Project ▸ Archive… (zip with options: include run results, include config settings) | Mac | Todo |
| Project ▸ Write Tcl… (script that recreates the project) | Mac | Todo |
| Checkpoint ▸ Open / Write | Remote | Todo |
| Text Editor ▸ Save File (⌘S) and Save All; close with a "save changes?" prompt | Mac | Done |
| Text Editor ▸ New File, Open File, Save File As | Mac | Todo |
| Add Sources… (⌥⌘A) | Mac | Done |
| Import ▸ Import Constraints | Mac | Todo |
| Export ▸ Export Bitstream File, Export Constraints, Export Hardware (.xsa), Export Simulation | Mac / Remote | Todo |
| Exit (with confirmation) | Mac | Todo |

### Edit

| Item | How | Status |
| --- | --- | --- |
| Undo / Redo / Cut / Copy / Paste / Select All, in the editor | Mac | Done |
| Find… (objects), Find in Files…, Replace in Files… | Mac | Todo |

### Flow

| Item | How | Status |
| --- | --- | --- |
| Settings… | Mac | Prototype (General page only) |
| Run Synthesis / Run Implementation / Generate Bitstream | Remote | Prototype (rules done; live runs still one script, see P1) |
| Launch Runs dialog (number of jobs, launch directory, generate scripts only) | Mac → Remote | Todo |
| Reset Runs dialog (with "delete generated files") | Mac | Prototype (no dialog yet) |
| Create Design Runs… (extra synth/impl runs with other strategies) | Mac → Remote | Todo |
| Run Simulation ▸ Behavioral / Post-Synthesis / Post-Implementation | Local tool | Todo (behavioral only; post-synth needs a netlist export, Remote) |
| Open Elaborated / Synthesized / Implemented Design | Remote | Todo (opens Netlist, Schematic, I/O views fed by Vivado) |
| Open Hardware Manager | Local tool | Todo |
| Create Block Design… | Not possible (see §6) | — |

### Tools

| Item | How | Status |
| --- | --- | --- |
| Settings… (Project settings and Tool settings) | Mac | Prototype |
| Language Templates | Mac (our own templates, same tree layout) | Todo |
| IP Catalog / Customize IP / Generate Output Products | Remote | Todo |
| Run Tcl Script… | Remote | Todo |
| Timing ▸ Constraints Wizard, Edit Timing Constraints | Mac editor, Remote for design data | Todo |
| Property Editor | Remote | Todo |
| Generate Memory Configuration File (.mcs/.bin for flash) | Remote | Todo |
| Create and Package New IP | Remote | Todo |
| Custom Commands | Mac | Todo |

### Reports

| Item | How | Status |
| --- | --- | --- |
| Report Timing Summary (dialog with options) | Remote | Prototype (report shown; dialog Todo) |
| Timing ▸ Report Timing (paths table), Report Clock Networks, Report Clock Interaction, Report CDC, Report Pulse Width | Remote | Todo |
| Report Utilization (with hierarchy) | Remote | Prototype (flat summary) |
| Report Power | Remote | Todo |
| Report DRC, Report Methodology, Report Noise | Remote | Todo |
| Report I/O, Report Control Sets, Report QoR Suggestions, Report Design Analysis | Remote | Todo |
| Report Instance Hierarchy | Remote | Todo |

### Window, Layout, View, Help

| Item | How | Status |
| --- | --- | --- |
| Window ▸ show/hide each pane (Project Summary, Sources, Properties, Netlist, Tcl Console, Messages, Log, Reports, Design Runs, Package, Device, I/O Ports, Timing, Find Results, Waveform) | Mac | Prototype (console toggle only) |
| Layout ▸ Default, I/O Planning, Floorplanning, Debug; Save Layout As; Remove Layout; Reset Layout | Mac | Todo |
| View ▸ Zoom In/Out/Fit, Flow Navigator, Toolbar | Mac | Prototype (sidebar toggle) |
| Help ▸ Documentation and Tutorials, Tcl Command Help, About | Mac | Todo |
| Quick Access search box (find any command by name) | Mac | Todo |

## 3. Windows and panes

| Pane | How | Status |
| --- | --- | --- |
| Flow Navigator (all sections, run status icons, collapse sections) | Mac | Done (collapse Todo) |
| Sources ▸ Hierarchy (module tree, top marker) | Mac | Done |
| Sources ▸ Libraries, Compile Order (reorder, manual compile order) | Mac | Prototype (read-only) |
| Sources ▸ IP Sources | Remote | Todo |
| Sources toolbar: search, collapse/expand all, add, properties | Mac | Prototype (add only) |
| Sources context menu: Set as Top, Remove File, Disable File, Open File, Replace File, Copy File Into Project, Hierarchy Update, Refresh Hierarchy | Mac | Todo |
| Source File Properties | Mac | Done |
| Project Summary dashboard (Overview, Settings, Board, Synthesis, Implementation, DRC, Timing, Utilization, Power, Methodology, Design Runs) | Mac + Remote data | Prototype |
| Text editor: editing, save, undo, line numbers, syntax colors, find (⌘F), comment toggle (⌘/), auto-indent, Tab and Shift-Tab | Mac | Done |
| Text editor: go to line, replace in files, bracket matching, linting markers from Messages | Mac | Todo |
| Tcl Console (history with ↑/↓, command echo of GUI actions, clear) | Mac → Remote | Prototype (history Todo) |
| Messages (grouped by run and ID, severity filters, search, suppress, jump to source line) | Mac | Prototype (grouping and filters) |
| Log (per run, live) | Mac | Done |
| Reports (per run, open in viewer) | Mac | Done |
| Design Runs table (columns, context menu: Launch, Reset, Delete, Make Active, Change Run Settings, Open Run Directory) | Mac → Remote | Prototype (table only) |
| Run Properties | Mac | Todo |
| Netlist (cells, nets, hierarchy of the opened design) | Remote | Todo |
| Properties (any selected object) | Remote | Todo |
| Schematic | Remote data + Mac renderer | Todo (stretch, see P8) |
| I/O Ports table and Package view (pin assignment) | Remote data + Mac | Todo |
| Timing results window (paths table, path report, highlight) | Remote | Todo |
| Device view / floorplanning | Not possible | — |

## 4. Dialogs and popups

| Dialog | How | Status |
| --- | --- | --- |
| New Project wizard (all pages, Back/Next/Finish, "Do not specify sources", Parts/Boards with filters) | Mac | Done |
| Add Sources wizard (constraints / design / simulation; Add Files, Add Directories, Create File) | Mac | Prototype (Add Directories Todo) |
| Create Source File (file type, name, location) | Mac | Done |
| Define Module (port table: name, direction, bus, MSB, LSB) after creating a file | Mac | Done |
| Settings ▸ Project: General, Simulation, Elaboration, Synthesis (strategy + options table), Implementation (strategy + per-step options), Bitstream (options such as -bin_file), IP | Mac → Remote | Prototype (General) |
| Settings ▸ Tool: Project, IP Defaults, Source File, Display, Help, Text Editor (font, colors, tabs), 3rd Party Simulators, Colors, Selection Rules, Shortcuts, Strategies, Window Behavior | Mac | Todo |
| Launch Runs (jobs, launch directory, scripts only) | Mac | Todo |
| "Synthesis Completed" (Run Implementation / Open Synthesized Design / View Reports / Don't show again) | Mac | Todo |
| "Implementation Completed" (Generate Bitstream / Open Implemented Design / View Reports) | Mac | Todo |
| "Bitstream Generation Completed" (Open Implemented Design / View Reports / Open Hardware Manager / Generate Memory Configuration File) | Mac | Todo |
| "Synthesis is Out-of-date" prompt when launching implementation | Mac | Todo (currently re-runs silently) |
| Run failure popup with link to Messages / Log | Mac | Todo |
| Reset Runs confirmation (delete generated files) | Mac | Todo |
| Close Project / Exit confirmations | Mac | Todo |
| Save Project As, Archive Project, Write Tcl | Mac | Todo |
| Report Timing Summary / Report Timing / Report Utilization / Report Power option dialogs | Mac → Remote | Todo |
| Constraints Wizard, Timing Constraints editor (Create Clock, Input/Output Delay, False Path, Multicycle) | Mac + Remote | Todo |
| IP Catalog, Customize IP, Generate Output Products | Remote | Todo |
| Program Device (bitstream file, Program) | Local tool | Todo |
| Add Configuration Memory Device / Program Configuration Memory | Local tool | Todo |
| Suppress Message / Manage Suppressions | Mac | Todo |
| Language Templates window | Mac | Todo |
| Tcl Command Help | Mac | Todo |
| About | Mac | Todo |

## 5. Flow behavior

| Behavior | How | Status |
| --- | --- | --- |
| Separate synth_1 and impl_1 runs with checkpoints (implementation reuses the synthesized design) | Remote | Todo **(P1, core change)** |
| Run Implementation runs synthesis first if missing or out-of-date | Mac | Done |
| Generate Bitstream runs whatever is needed | Mac | Done |
| Out-of-date tracking when sources, constraints or settings change | Mac | Prototype (on add/settings; on file edit Todo) |
| Strategies (Vivado Synthesis Defaults, Flow_PerfOptimized_high, Performance_Explore, …) | Remote | Todo |
| Incremental implementation | Remote | Todo |
| GUI actions echoed as Tcl in the console | Mac | Done |
| Live log while running, stop a running step | Mac / Remote | Prototype (stop in demo only) |

## 6. Things a Mac can't do, and what we do instead

| Vivado feature | Why not | Instead |
| --- | --- | --- |
| Hardware Manager debug cores (ILA, VIO, JTAG-to-AXI) | Needs Xilinx `hw_server`, which has no macOS build | Program and flash the board with openFPGALoader; debug cores stay a Windows task |
| Device view and floorplanning | Needs Vivado's device database and renderer in the GUI | Pin planning via the I/O Ports table (Remote data); placement reports |
| IP Integrator block design editor | A full graphical editor backed by Vivado's IP engine | Open and validate block designs remotely, edit their Tcl; a visual editor is a stretch goal |
| Vivado Simulator (XSim) waveform window | XSim runs only where Vivado runs | Behavioral simulation with Verilator/Icarus and a native waveform viewer |
| Vitis, HLS, licensing dialogs | Separate products | Out of scope |

---

## Build order

Each phase is usable on its own and is tested before the next one starts.

1. **P1: Flow parity.** Separate synth_1/impl_1/bitstream runs with checkpoints (core + live backend); Launch Runs
   dialog; Synthesis/Implementation/Bitstream Completed popups; out-of-date prompt; Reset Runs dialog; Design Runs
   context menu and Run Properties; Synthesis/Implementation/Bitstream settings pages with strategies and options.
2. **P2: Projects and editing.** Real text editor (edit, save, undo, find/replace, go to line, syntax colors);
   Create Source File and Define Module dialogs; Sources context menus (Set as Top, Remove, Disable); Compile Order
   editing; Find in Files; Language Templates; File menu (Save As, Archive, Write Tcl, Close/Exit confirmations);
   Edit menu; Text Editor settings.
3. **P3: Reports and analysis.** Reports menu with option dialogs; timing paths window; hierarchical utilization;
   DRC, methodology, power, clock reports; Messages search, grouping by ID, suppression, jump to source line.
4. **P4: Program and debug.** Hardware Manager with openFPGALoader: detect boards, Program Device, configuration
   memory (.mcs/.bin from Vivado, flashed locally).
5. **P5: Simulation.** Run Simulation ▸ Behavioral with Verilator/Icarus; simulation settings; native waveform viewer.
6. **P6: Design views.** Open Elaborated/Synthesized/Implemented Design: Netlist, Properties, I/O Ports and package
   pins, Constraints Wizard and timing constraints editor; IP Catalog, Customize IP, output products.
7. **P7: Workspace polish.** Window/Layout/View/Help menus, saved layouts, Quick Access search, Tool settings
   (Display, Colors, Shortcuts, Strategies), Tcl history, Tcl Command Help, About.
8. **P8: Stretch.** Schematic viewer from an exported netlist; a block design viewer.

## Testing constraint

Everything marked **Remote** generates Vivado Tcl. Until a real build machine is available, that Tcl is only checked
by the fake-remote tests and the CI `cmd.exe` job, not by Vivado itself. The first session on the Windows machine
should run each Remote feature once, in the order above.
