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
| **Local tool** | A Mac tool does Vivado's job (openFPGALoader for programming, Icarus Verilog for simulation). |
| **Not possible** | Can't work on a Mac; the row says why and what we offer instead. |

Status values: **Done**, **Prototype** (works, not complete), **Todo**.

---

## 1. Start-up

| Vivado feature | How | Status |
| --- | --- | --- |
| Getting Started page: Quick Start (Create Project, Open Project, Open Example Project) | Mac | Done |
| Recent Projects list | Mac | Done |
| Tasks (Manage IP, Open Hardware Manager, Vivado Store) | Mac / Local tool | Prototype (Hardware Manager works; the others are disabled) |
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
| Project ▸ Write Tcl… (script that recreates the project) | Mac | Done: writes the build script FPGA Bridge runs, and a Vivado project-mode script that recreates the project (checked on Vivado 2025.2: the project opens and builds to a bitstream) |
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
| Find… (objects), Find in Files…, Replace in Files… | Mac | Find in Files and Replace in Files done (results in a Find Results tab, replace previews each change and works on unsaved edits, Undo Replace); Find (objects) Todo |

### Flow

| Item | How | Status |
| --- | --- | --- |
| Settings… | Mac | Done for Project Settings (General, Simulation, Elaboration, Synthesis, Implementation, Bitstream: real options that change the build script and the simulator, checked on Vivado 2025.2). Tool settings Todo |
| Run Synthesis / Run Implementation / Generate Bitstream | Remote | Prototype (rules done; live runs still one script, see P1) |
| Launch Runs dialog (number of jobs, launch directory, generate scripts only) | Mac → Remote | Todo |
| Reset Runs dialog (with "delete generated files") | Mac | Prototype (no dialog yet) |
| Create Design Runs… (extra synth/impl runs with other strategies) | Mac → Remote | Todo |
| Run Simulation ▸ Behavioral (Simulation tab: banner, log, Stop, Run Again, Open Waveform; Flow menu item) | Local tool | Done (Verilog and SystemVerilog, verified with Icarus Verilog 13) |
| Waveform window (signal names with values at the cursor, time ruler, zoom/pan/fit, cursor, previous/next edge, radix per bus, add/remove signals from the design tree) | Mac | Done (VCD from Icarus Verilog) |
| Waveform: markers and measurements, saved waveform configurations (.wcfg), analog/real signals, grouping and dividers | Mac | Markers (add, drag, rename, time between), dividers and a saved layout per testbench (FPGA Bridge's own JSON, not `.wcfg`) done; analog/real signals Todo |
| Run Simulation ▸ Post-Synthesis / Post-Implementation | Local tool | Todo (needs a netlist export, Remote) |
| Open Elaborated / Synthesized / Implemented Design | Remote data + Mac | Prototype: every build saves the netlist, connections, pin directions, source lines and all properties on the Mac, so an opened design works with the build machine asleep. Netlist window, Cell/Net/Port/Pin Properties, Schematic, I/O Ports, utilization by module and the stage's reports. The elaborated design opens on a schematic of the top, as Vivado's does. Timing window with path highlighting (see below). Package view (all three designs) and Device view (synthesized and implemented) from cached part data |
| Open Hardware Manager (target banner, Auto Connect, device tree and properties, Program Device, Program Configuration Memory Device) | Local tool | Done (verified on a real Basys 3) |
| Hardware Manager: Open New Target, Open Recent Target, debug probes file | Local tool | Todo (disabled) |
| Open Block Design (diagram, Block Design Properties, Address Editor) | Mac (reads Vivado's `.bd` and `.xci`) | Done for viewing: a project's block designs are listed under Design Sources with their IP; the diagram draws IP blocks with their interfaces, external ports and connections, hierarchies open in place; the Address Editor lists the address map. Checked on Vivado 2025.2 MicroBlaze and hand-wired designs. Not yet: Address Map page, Signals/Design tabs, expanding an interface into its signals |
| Create Block Design… / Generate Block Design / Validate Design / editing (Add IP, connect) | Remote (Vivado as the engine) | Todo, wave 2: greyed "Coming soon". Building a project that contains a block design needs the build script to generate it and its wrapper |

### Tools

| Item | How | Status |
| --- | --- | --- |
| Settings… (Project settings and Tool settings) | Mac | Prototype |
| Language Templates (language > group > template tree, search, preview, Insert Template, Copy) | Mac (our own templates, same tree layout) | Done (about 50 templates in Verilog, SystemVerilog, VHDL and XDC) |
| IP Catalog / Customize IP / Generate Output Products | Remote | Prototype (browse the real catalog with categories and search, Customize IP as a generic settings editor, instantiation templates in Verilog and VHDL, IP Sources tab; the build recreates, generates and synthesizes each IP; verified on Vivado 2025.2). Not done: allowed-value dropdowns (Vivado doesn't expose them to Tcl), IP caching between builds, Generate Output Products options, simulation models of IP |
| Run Tcl Script… | Remote | Todo |
| Timing ▸ Constraints Wizard, Edit Timing Constraints | Mac editor, Remote for design data | Todo |
| Property Editor | Remote | Todo |
| Generate Memory Configuration File (.mcs/.bin for flash) | Remote | Todo |
| Create and Package New IP | Remote | Todo |
| Custom Commands | Mac | Todo |

### Reports

| Item | How | Status |
| --- | --- | --- |
| Report Timing Summary (dialog with options) | Remote | Prototype (opens the Timing window with the build's summary and worst paths; the text report stays in the Reports menu; the options dialog is Todo) |
| Timing ▸ Report Timing (paths table), Report Clock Networks, Report Clock Interaction, Report CDC, Report Pulse Width | Remote | Prototype (Report Timing, Clocks and Clock Utilization are written by the build and shown as text; the paths table, Clock Interaction, CDC and Pulse Width are Todo) |
| Report Utilization (with hierarchy) | Remote | Done in two forms: Vivado's own report as text, and utilization by module from the netlist (cell counts, which can differ from Vivado's site counts) |
| Report Power | Remote | Prototype (written by the build, shown as text) |
| Report DRC, Report Methodology, Report Noise | Remote | Prototype (DRC and Methodology written by the build, shown as text; Noise Todo) |
| Report I/O, Report Control Sets, Report QoR Suggestions, Report Design Analysis | Remote | Todo |
| Report Instance Hierarchy | Remote | Todo |

### Window, Layout, View, Help

| Item | How | Status |
| --- | --- | --- |
| Window ▸ show/hide each pane (Project Summary, Sources, Properties, Netlist, Tcl Console, Messages, Log, Reports, Design Runs, Package, Device, I/O Ports, Timing, Find Results, Waveform) | Mac | Prototype (console toggle, View ▸ Show Timing, Window ▸ Package and Device) |
| Layout ▸ Default, I/O Planning, Floorplanning, Debug; Save Layout As; Remove Layout; Reset Layout | Mac | Todo |
| View ▸ Zoom In/Out/Fit, Flow Navigator, Toolbar | Mac | Prototype (sidebar toggle) |
| Help ▸ Documentation and Tutorials, Tcl Command Help, About | Mac | Todo |
| Quick Access search box (find any command by name) | Mac | Todo |

## 3. Windows and panes

| Pane | How | Status |
| --- | --- | --- |
| Flow Navigator (all sections, run status icons, collapse sections) | Mac | Done as in Vivado 2025.2: every section including IP Integrator (Open Block Design live when the project has one; Create and Generate greyed), Run Linter, each open design's commands (reports, Schematic; Constraints Wizard, Edit Timing Constraints, Set Up Debug and Open Dataflow Design greyed with the reason), Open Hardware Manager's Open Target / Program Device / Add Configuration Memory Device, bold section and renamed item for the open design, collapsible sections and items |
| Run Linter (RTL Analysis) | Remote | Done: `synth_design -lint` on the build machine (its own job folder, the build's lock), the Linter window with Vivado's rule summary and each message linked to its line; `fpga-bridge lint` on the command line |
| Sources ▸ Hierarchy (module tree, top marker) | Mac | Done |
| Sources ▸ Libraries, Compile Order (reorder, manual compile order) | Mac | Prototype (read-only) |
| Sources ▸ IP Sources | Remote | Todo |
| Sources toolbar: search, collapse/expand all, add, properties | Mac | Prototype (add only) |
| Sources context menu: Set as Top, Remove File, Disable File, Open File, Replace File, Copy File Into Project, Hierarchy Update, Refresh Hierarchy | Mac | Done (plus Move to Design/Simulation Sources, Show in Finder, Copy Path). Remove File keeps the file on disk unless "Also delete the project local file/directory from disk" is ticked, as in Vivado. Set Used In and Hierarchy Update are greyed |
| Source File Properties | Mac | Done |
| Project Summary dashboard (Overview, Settings, Board, Synthesis, Implementation, DRC, Timing, Utilization, Power, Methodology, Design Runs) | Mac + Remote data | Done for the Overview as in Vivado 2025.2 (Settings; Synthesis; Implementation with Route Status; DRC Violations; Timing Setup/Hold/Pulse Width; Utilization Post-Synthesis/Post-Implementation as Graph or Table; Power Summary/On-Chip with thermal margin). Dashboard: fixed timing, utilization and power gadgets; Add Gadget is Todo |
| Text editor: editing, save, undo, line numbers, syntax colors, find (⌘F), comment toggle (⌘/), auto-indent, Tab and Shift-Tab | Mac | Done |
| Text editor: go to line, replace in files, bracket matching, linting markers from Messages | Mac | Todo |
| Tcl Console (history with ↑/↓, command echo of GUI actions, clear) | Mac → Remote | Prototype (history Todo) |
| Messages (grouped by run and ID, severity filters, search, suppress, jump to source line) | Mac | Prototype (grouping and filters) |
| Log (per run, live) | Mac | Done |
| Reports (per run, open in viewer) | Mac | Done |
| Design Runs table (columns, context menu: Launch, Reset, Delete, Make Active, Change Run Settings, Open Run Directory) | Mac → Remote | Prototype: every Vivado column (WNS…QoR Suggestions, LUT…DSP, Start, Elapsed, Run Strategy), percentage toggle, search, synth_1 with impl_1 under it, toolbar (Reset Runs, Launch Runs; step-by-step items greyed), context menu Launch/Reset/Open Run/Generate Bitstream. Runs restored from the last build show complete, or out-of-date if a source changed. Delete, Make Active and extra runs are Todo |
| Run Properties | Mac | Todo |
| Netlist (cells, nets, hierarchy of the opened design) | Remote data + Mac | Done: Nets and Leaf Cells folders per module, buses grouped, Vivado's icons, shared selection that opens the tree to what is selected elsewhere, Go To Source, Schematic (F4) |
| Properties (any selected object) | Remote | Todo |
| Schematic | Remote data + Mac renderer | Prototype: layered left-to-right layout with Vivado's RTL symbols (gates, mux, register with clock triangle, buffers, port pentagons), RTL registers and buses bundled (`count_reg[7:0]`) while synthesized flip-flops are drawn one each, loops broken at register outputs so next-state logic sits in front of its register, output buffers by the output ports, feedback looped back under the cells, long wires kept straight, constants as tie labels, modules opened in place, dotted stubs for logic not shown; zoom, pan, select (shared), Previous/Next, Schematic of selection (F4), Go To Source. Not done: Expand Cone, Select Area, schematic display settings (fanout, slack, equations), pages for huge levels |
| I/O Ports table and Package view (pin assignment) | Remote data + Mac | Done: the Package view (bank colors, pin kinds, placed ports, problems ringed) and an editable I/O Ports table; dragging a port to a pin or editing its pin or standard writes `PACKAGE_PIN`/`IOSTANDARD` into the XDC (only those settings; comments and line endings kept), with Vivado's rule checks (bank standard and VCCO, VREF, differential pairs, direction, clock-capable pins, unplaced ports). Part data comes from a one-off Vivado job, cached on the Mac. Not yet: choosing the target constraints file, swapping two ports by dropping, the bottom view, auto-placing a bus |
| Timing results window (paths table, path report, highlight) | Remote data + Mac | Done for the build's query (the 100 worst setup and hold paths per stage, saved at build time and shown offline): Design Timing Summary, path groups (Intra-Clock, Inter-Clock, Other), the paths table with Vivado's columns, Path Properties (summary, source clock, data path and destination clock tables, Vivado's report text), selecting a path highlights it in the Netlist and Schematic, Schematic (F4) of a path. Pulse Width per pin, User Ignored Paths and Unconstrained Paths are greyed with the reason |
| Device view / floorplanning | Remote data + Mac | Prototype: the Device view draws the die from cached part data with clock regions, and the implemented design's cells on their `LOC` sites, cross-selecting with the netlist. Not yet: routing, pblocks and floorplanning, moving cells |

## 4. Dialogs and popups

| Dialog | How | Status |
| --- | --- | --- |
| New Project wizard (all pages, Back/Next/Finish, "Do not specify sources", Parts/Boards with filters) | Mac | Done |
| Add Sources wizard (constraints / design / simulation; Add Files, Add Directories, Create File) | Mac | Prototype (Add Directories Todo) |
| Create Source File (file type, name, location) | Mac | Done |
| Define Module (port table: name, direction, bus, MSB, LSB) after creating a file | Mac | Done |
| Settings ▸ Project: General, Simulation, Elaboration, Synthesis (strategy + options table), Implementation (strategy + per-step options), Bitstream (options such as -bin_file), IP | Mac → Remote | Done (the IP page is the IP Sources list) |
| Settings ▸ Tool: Project, IP Defaults, Source File, Display, Help, Text Editor (font, colors, tabs), 3rd Party Simulators, Colors, Selection Rules, Shortcuts, Strategies, Window Behavior | Mac | Todo |
| Launch Runs (jobs, launch directory, scripts only) | Mac | Todo |
| "Synthesis Completed" (Run Implementation / Open Synthesized Design / View Reports / Don't show again) | Mac | Todo |
| "Implementation Completed" (Generate Bitstream / Open Implemented Design / View Reports) | Mac | Todo |
| "Bitstream Generation Completed" (Open Implemented Design / View Reports / Open Hardware Manager / Generate Memory Configuration File) | Mac | Todo |
| "Synthesis is Out-of-date" prompt when launching implementation | Mac | Todo (currently re-runs silently) |
| Run failure popup with link to Messages / Log | Mac | Todo |
| Reset Runs confirmation (delete generated files) | Mac | Todo |
| Close Project / Exit confirmations | Mac | Todo |
| Save Project As, Archive Project, Write Tcl | Mac | Done |
| Report Timing Summary / Report Timing / Report Utilization / Report Power option dialogs | Mac → Remote | Todo |
| Constraints Wizard, Timing Constraints editor (Create Clock, Input/Output Delay, False Path, Multicycle) | Mac + Remote | Todo |
| IP Catalog, Customize IP, Generate Output Products | Remote | Prototype (see above) |
| Program Device (bitstream file, Program) | Local tool | Todo |
| Add Configuration Memory Device / Program Configuration Memory | Local tool | Todo |
| Suppress Message / Manage Suppressions | Mac | Todo |
| Language Templates window | Mac | Done |
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
| IP Integrator block design editor | A full graphical editor backed by Vivado's IP engine | The viewer is done (diagram, properties, Address Editor). Editing: changes on the Mac's canvas, Vivado validates and saves the `.bd` in a job on the build machine (wave 2) |
| Vivado Simulator (XSim) waveform window | XSim runs only where Vivado runs | Behavioral simulation with Icarus Verilog; the native waveform viewer is done, with markers and saved layouts |
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
5. **P5: Simulation.** Run Simulation ▸ Behavioral with Icarus is done; simulation settings and a native waveform viewer are to do.
6. **P6: Design views.** Open Elaborated/Synthesized/Implemented Design: Netlist, Properties, I/O Ports and package
   pins, Constraints Wizard and timing constraints editor; IP Catalog, Customize IP, output products.
7. **P7: Workspace polish.** Window/Layout/View/Help menus, saved layouts, Quick Access search, Tool settings
   (Display, Colors, Shortcuts, Strategies), Tcl history, Tcl Command Help, About.
8. **P8: Stretch.** Schematic viewer from an exported netlist (done); a block design viewer (done), then editing.

## Testing constraint

Everything marked **Remote** generates Vivado Tcl. Until a real build machine is available, that Tcl is only checked
by the fake-remote tests and the CI `cmd.exe` job, not by Vivado itself. The first session on the Windows machine
should run each Remote feature once, in the order above.
