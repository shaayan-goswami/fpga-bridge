# Code review: AI-code smells and likely mistakes

A pass over the whole repo (about 7,700 lines of Swift, plus scripts, CI and docs) for the habits AI-written code
tends to have. Method: a clean build with no warnings, a build with `-strict-concurrency=complete`, repo-wide
searches (`git grep`) for patterns, a search for dead and duplicated code, and reading the largest files.

Items under **Fixed** were changed in the same commit as this file. Everything else is flagged, in rough priority
order, with file and line references taken at the time of writing.

> **Update (cleanup branch):** likely bugs 1-7, the strict-concurrency warnings, the debug hooks, the brittle icon
> bundle lookup, `codesign --deep`, the flaky cancel test, and the stale README are all fixed since this was written,
> each with a test where one makes sense. Still open: `.id(accents)` in `AppearanceRoot`, the `AppModel` split,
> the library's default `print` sink, `ObservableObject` to `@Observable`, and the unverified assumptions below. The
> sections below keep the original findings for the record.

## Fixed

- **Inconsistent spelling.** "colour", "behaviour" and "centre" were mixed with the American spellings used
  elsewhere (about 15 places in code comments, UI text, demo data and docs). Now American throughout.
- **Stale comments that contradicted the code.** `Appearance.swift` still described the app as "monochrome" and said
  color is "only used" for status, after accents were added; three more comments repeated it. Rewritten to say what
  the code does.
- **Emoji status glyphs in `docs/vivado-parity.md`** (on about 100 table rows). Replaced with the words Done, Prototype, Todo.
- **Duplicated code.** The 8-line "reset all run state" block was copied in `openProject` and `resetRuns`; it is now
  `clearRunState(message:)`. Two identical "glass when selected" modifiers (tab bar and console tabs) are now one
  `glassWhenSelected(_:)`.
- **Checked and clean:** no compiler warnings, no force unwraps, no `fatalError`, no TODO/FIXME left in code, no
  declarations that nothing references, no other duplicated blocks of six or more lines.

## Likely bugs

1. **Cancelling a run can leave two runs going.** `AppModel.cancelRun()` (AppModel.swift:333) clears `isRunning`
   immediately, but the old `Task` keeps running until it next checks for cancellation. `execute` (line 340) then
   accepts a new run, so two runs can write to the same state, and the old task's trailing
   `isRunning = false; runTask = nil` can clobber the new run. Opening a project mid-run triggers this. Fix: await the
   task, or give each run an id and ignore results from a stale one.
2. **Cancelling only the bitstream step marks `impl_1` as cancelled** even though implementation had finished
   (`performStep`, the `.cancelled` branch). It should keep Complete and only clear `bitstreamReady`.
3. **HDL templates accept reserved words.** `HDLTemplate.isIdentifier` (HDLTemplate.swift:105) only checks
   characters, so a module, port or architecture named `input`, `end`, `wire` or `entity` generates a file Vivado
   rejects. Needs Verilog, SystemVerilog and VHDL keyword lists.
4. **Quoting in `cmd.exe` lines.** `Remote.buildCommand` (Remote.swift:165) puts `config.vivadoPath` between double
   quotes without escaping. A path containing `"`, `&` or `%` breaks the command or runs something else. The path is
   user-configured, so this is low risk, but it should be validated when `init` saves it.
5. **Symlinks can escape the project folder.** `Project.expand` rejects `..` and absolute paths lexically, but a
   symlink inside the project pointing elsewhere is copied to the build machine.
6. **Errors are swallowed in places where the user would want to know.** `reloadProjectAfterChange` (AppModel.swift:231)
   returns silently if the project file can't be re-read, and `rebuildSourceTree` (line 245) turns a failed source
   resolve into an empty tree with no message. `try?` appears on 47 lines; most are fine (best-effort cleanup), these two aren't.
7. **Demo mode shows steps live mode doesn't do.** The simulated logs print `source synth.tcl` and
   `open_checkpoint synth.dcp` (DemoData.swift:210, 239), but the live backend runs one monolithic script with no
   checkpoints. Anyone judging the real flow from demo mode is misled until staged runs exist (see BACKLOG M1/P1).

## Concurrency (Swift 5 mode hides these)

`Package.swift` uses tools version 5.9, which compiles in the lenient Swift 5 language mode. Building with
`-strict-concurrency=complete` gives **41 warnings** that become errors in Swift 6:

- `FPGABridgeApp.swift`: 16 (AppKit calls from non-main contexts in the snapshot code)
- `Backend.swift`: 7 and `AppModel.swift`: 7. The log closure, the backend and the project are sent across tasks
  without being `Sendable`. The log closure really is called from a background thread, so this is a real data-race
  risk, currently held together by hopping to the main queue.
- `Shell.swift:34-35`: `outData` and `errData` are mutated from concurrent closures, safe only because of the
  `DispatchGroup` wait.
- `Appearance.swift`: `AppIcon.cache`, a global mutable dictionary.
- `DemoData`, `BoardCatalog`, `ProjectCreatorError`: non-`Sendable` statics and payloads.

The workaround for ordering log output (`DispatchQueue.main.async { MainActor.assumeIsolated { ... } }` followed by an
empty `async` hop to "flush", AppModel.swift:387 and :476) is a smell. An `AsyncStream` of log chunks consumed on the
main actor would remove both the race and the hack.

## Design smells

- **`AppModel` is a 550-line god object**: project lifecycle, the run engine, the Tcl console, tabs, recent
  projects, and test scenarios. The run engine should be its own type, which also makes bug 1 easier to fix and test.
- **Debug and screenshot hooks are in production code.** Twelve `FPGA_BRIDGE_*` environment variables are read in
  `AppModel` (lines 60-100, 163), `FPGABridgeApp.swift`, `NewProjectWizard.swift:70` and
  `ProjectSettingsView.swift` (a screenshot scenario inside `AddSourcesSheet`). They belong in one file under
  `#if DEBUG`.
- **`.id(accents)` in `AppearanceRoot` (Appearance.swift:202) rebuilds the entire view tree** when the accent
  setting changes, which throws away every view's `@State` (open sheets, scroll positions, text fields). It exists
  because `Accent` reads `UserDefaults` directly and so isn't observable. Make accents part of the environment.
- **The library prints to stdout** (`Remote.swift:75`, default log). Acceptable for the CLI, but a library should
  take its output sink as a parameter with no default.
- **Brittle resource lookup.** `AppIcon.load` hardcodes SwiftPM's generated bundle name
  `fpga-bridge_FPGABridgeApp.bundle` (Appearance.swift:273), repeated in `scripts/make-app.sh:25-26`. Renaming the
  package silently breaks the icon.
- **`ObservableObject` throughout** where the macOS 14 target allows `@Observable`, which would remove most of the
  `@Published` boilerplate and the unnecessary redraws.
- **`Mono` is an enum holding one constant**, and the Accent legend repeats the meanings already in the doc comments.

## Unverified assumptions

- **Icon style preference values.** `IconStyle.current` (Appearance.swift:215) maps `AppleIconAppearanceTheme`
  strings such as `"RegularDark"`. The key and the names were found in the system shared cache, but I never saw the
  OS write them, so the mapping is unconfirmed. Check by switching Icon & widget style in System Settings and reading
  the key with `defaults read -g AppleIconAppearanceTheme`.
- **Vivado Tcl and command lines have never run on real Vivado or Windows.** The fake-remote tests and the CI
  `cmd.exe` job check our own assumptions. First session on the Windows machine should run every Remote feature once.
- **Liquid Glass rendering** can't be captured by the off-screen screenshot tool, so how it looks is unchecked.

## Test quality

- `FakeRemoteTests` uses `Thread.sleep` (lines 316, 318) and sends a real `SIGINT` to the test process. It passed six
  consecutive runs, but a timing-based signal test is the likeliest to flake on a loaded CI runner.
- Tests mutate process-wide state with `setenv`, so they can't run in parallel.
- `CIWorkflowTests` passes by string-matching YAML. It is intentional, but it will fail on harmless reformatting.
- Nothing tests the SwiftUI layer or `AppModel` (the run rules, out-of-date handling, cancel). Bug 1 would have been
  caught by a test that cancels and immediately starts a second run.

## Packaging and docs

- `codesign --deep` in `scripts/make-app.sh` is discouraged by Apple for new work; sign nested code individually.
- `README.md` still says Python 3 is required and that nothing is built; it describes the plan, not the code.
- `docs/vivado-parity.md` lists rows as Done that have only been checked in demo mode.
