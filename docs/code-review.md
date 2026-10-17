# Code review

A pass over the whole repo (about 25,000 lines of Swift, plus scripts and docs) for the mistakes generated code tends
to make: crashes on unexpected input, errors swallowed where the user should hear about them, commands or options
that don't exist, controls that do nothing, dead or copied code, and docs that claim more than the code does. Last
done on 17 October 2026, against Vivado 2025.2 on the Windows build machine.

## How it was checked

- **Crashes:** every force unwrap, `try!`, `fatalError`, forced cast and unchecked index. All remaining ones are safe
  (constant data, or checked on the line before). Every parser of files fetched from the build machine checks its
  field counts first, so a truncated download can't crash the app.
- **Windows text:** every place that splits, counts or searches text by line, since Swift reads CR LF as one
  Character that is not `"\n"`.
- **Swallowed errors:** every `try?`. Most are best-effort cleanup or optional data; one hid a broken config (fixed).
- **Vivado commands and options:** a real build with every Project Settings option switched on, on a design that
  refuses to elaborate unless each macro, include folder and generic actually arrives; then every directive the
  Settings menus offer (4 synthesis, 4 opt, 6 place, 6 phys_opt, 7 route) run through Vivado one by one. All accepted.
- **Controls that do nothing:** empty actions, and view state that is set but never read. The only empty actions are
  Vivado menu items deliberately greyed out with a reason.
- **Dead and copied code:** declarations referenced once, and identical runs of six or more lines across files.
- **Secrets:** no keys, tokens or passwords in the repo or its history; addresses in tests are documentation examples.
- **Docs:** README and this file checked against the code.

## Fixed in this pass

- **Crash on Verilog saved on Windows.** Finding the top module (New Project, Run Simulation) turned a regex match's
  UTF-16 offset into a Character offset; CR LF line endings pushed it past the end of the text. Test:
  `testFilesSavedOnWindowsWork`.
- **Include folders never reached the build machine.** Only sources and constraints were uploaded, so every
  `` `include `` from a Project Settings include folder failed in Vivado. They are uploaded now. Test:
  `testTheIncludeFoldersAreUploaded`.
- **Header files were compiled on their own.** `.vh`/`.svh` files in a source folder were passed to `read_verilog`;
  a typical header (a `localparam` outside a module) is a syntax error on its own. Headers are now only included, as
  Vivado's project mode does, and the folders holding them are searched. Test:
  `testHeadersAreIncludedNotReadAndTheirFoldersAreSearched`.
- **An include folder with a space became two folders.** `-include_dirs {inc more inc}` is a three-item Tcl list;
  each folder is braced now. The old test expected the broken form.
- **A broken build-machine config looked like no config.** A `config.json` with a typo made the app say "no build
  machine is set up". It now says the file can't be used, and why.
- **Line numbers drifted in files saved on Windows,** and Toggle Comment selected one character too many there.
- **The Tcl console said every line ran in Vivado.** The app's own actions are echoed as the Vivado command each
  stands for (as Vivado's GUI does), but they don't run in Vivado. The console's header now says which is which.
- **Dead code** (`HardwareManager.programTask`, `BuildOS.vivadoExecutable`) removed; the status banner copied between
  the Hardware Manager and the Simulation view is one `StatusBanner`.
- **Personal data in fixtures:** the Windows user name in captured Vivado output replaced with `builder`.
- **README** listed the schematic and the stage reports as not built, and left out the Netlist window and Run Linter.

## Still open

- `synth_design -retiming` is deprecated in Vivado 2025.2 in favor of `-global_retiming`. It still works and works in
  older versions, so it stays until the build script knows which Vivado it targets.
- `AppModel` is over 1,000 lines: project lifecycle, the run engine, tabs, the console. The run engine should be its
  own type.
- `ObservableObject` throughout, where the macOS 14 target allows `@Observable`.
- `.id(accents)` in `AppearanceRoot` rebuilds the whole view tree when the accent setting changes, dropping every
  view's state, because `Accent` reads `UserDefaults` directly.
- The library's `Remote.run` prints to stdout when given no log sink; a library should always be given one.
- Some tests change process-wide state (`setenv`, `PATH`), so the suites can't run in parallel; two tests wait with
  `Thread.sleep`.
- Unchecked: the icon-style preference values in `IconStyle.current`, and how Liquid Glass renders (the off-screen
  screenshot tool can't capture it). The app's own Run buttons have been used less against the real build machine
  than the command line has.
