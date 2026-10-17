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

**Plan**

- [ ] Record the state of the sources at upload (a hash of every file sent) and compare it with the files on disk
  when the build finishes; if anything changed, mark the runs out of date. Same check on reopening a project.
- [ ] Write a manifest next to the bitstream (`build/<top>.manifest.json`): the hash of the sources, the git commit
  when the project is a git repository (and whether it had uncommitted changes), the Vivado version, the board and
  part, the top module, and when it was built.
- [ ] Show the manifest in the Program Device and Program Configuration Memory Device dialogs, and in
  `fpga-bridge flash`, with a warning when the sources on disk no longer match the build.
- [ ] Tests for each: an edit during a build, a build with no manifest (older builds), a manifest from another
  project or board.
