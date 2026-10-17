# Feedback

Feedback from people trying or reviewing FPGA Bridge, what it found, and what is being done about it. Newest first.
Legend: `[x]` done, `[ ]` todo.

## 17 October 2026: build provenance and stale bitstreams

Source: a LinkedIn comment from a senior software engineer.

> Keeping the tested setup separate from the untested boards is useful. For remote builds, I'd also keep the source
> revision, Vivado version and target board alongside the returned bitstream, and show them before flashing. Does
> the app flag an artifact as stale if the source changes while a build is running?

**What the app does today**

- A build copies a snapshot of the sources and constraints to the build machine when it starts, so the bitstream
  always matches exactly what was sent.
- Saving a design source, a constraint or the project settings after a build marks synthesis and implementation
  out of date, as Vivado does. Reopening a project compares file times against the build folder for the same reason.
- Each build records the Vivado version, the part and the top module next to its reports (`build/*_info.tsv`).

**Gaps it found**

- **An edit saved while a build is running isn't flagged.** Saving only marks runs that are already complete as out
  of date (`markOutOfDate` in `AppModel.swift`), and a finished build then clears the flag (`apply`). So the result
  shows as up to date although a source changed after it was sent. Reopening the project doesn't catch it either:
  the fetched build files are newer than the edit.
- **The bitstream doesn't say what it was built from.** The source revision and the board aren't recorded with it.
- **Nothing is shown before programming:** Program Device doesn't say which build, sources or Vivado version the
  bitstream came from.

**Done in 0.2.0**

- [x] Each build fingerprints the files it sends (SHA-256 of the copies uploaded, plus the project file) and saves a
  manifest next to the bitstream: `build/build-manifest.json`, with the fingerprints, the git commit (and whether
  there were uncommitted changes), the Vivado version, the board and part, the top module, the build machine, and when
  it was built.
- [x] When a build finishes, the app compares the files on disk with what was sent. Anything saved during the build
  keeps synthesis and implementation out of date, and the log names the files. Reopening a project uses the same
  check (content, not file dates); a build from before 0.2.0 has no manifest and is still judged by dates.
- [x] Program Device and Program Configuration Memory Device show what the bitstream was built from, and warn when a
  file changed since, when the bitstream is for a different FPGA than the one connected, or when the project's top
  or part changed. `fpga-bridge flash` prints the same before programming, and `fpga-bridge build` prints the
  sources' fingerprint and warns about files changed during the build.
- [x] Tests: an edit during a build, a build nobody touched, reopening with the same content, the manifest's
  fingerprints and change detection, git state, and the fake build machines writing the manifest.

Found on the way: looking for the git repository walked up the folders forever when the project wasn't in one (the
parent of `/` is `/..`). Caught by the tests before release.
