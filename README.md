# fpga-bridge

Build FPGA designs from a Mac, even though Vivado doesn't run on macOS.

fpga-bridge lets you write, simulate, and flash on your Mac while a remote Windows or Linux machine with Vivado does the heavy build in the background.

> **Status:** early development. The `fpga-bridge` CLI and the Mac app (a prototype that mirrors Vivado's layout) are built and tested against a fake remote. The CLI has been run end to end once on real hardware (Windows machine with Vivado 2025.2, Basys 3-class Artix-7 35T board): build, fetch, report and flash. The app has not been run against it yet. See [BACKLOG.md](BACKLOG.md) and [docs/vivado-parity.md](docs/vivado-parity.md) for what is done. Features marked with an unchecked box are not built yet.

## Why

AMD's Vivado officially supports only Windows and a few Linux distributions. Mac users are stuck with workarounds like virtual machines, Docker with Rosetta, or cloud desktops. These tend to be slow, fragile, and can break after a macOS update.

fpga-bridge takes a different approach: leave Vivado on a machine it officially supports, and make talking to that machine feel native on a Mac.

## How It Works

```
 Mac (you work here)                    Build machine (Windows/Linux)
 -------------------                    -----------------------------
 1. Write Verilog/SV
 2. Run local simulation (Verilator)
 3. Hit build  ----- files over SSH ---->  4. Vivado runs in batch mode
                                           5. Bitstream + reports created
 6. Results + live log  <---- SSH -------
 7. Flash board over USB (openFPGALoader)
```

Vivado never runs on the Mac. Only the commands and results travel between machines.

## Planned Features

- [ ] One-command remote builds (copy, build, fetch results)
- [ ] Live build log streamed back to the Mac
- [ ] Parsed timing and resource utilization summary
- [ ] Local simulation with Verilator and waveform viewing in Surfer
- [ ] Board programming from the Mac with openFPGALoader
- [ ] Native Mac app (editor, project view, build button)

## Requirements

**On your Mac**
- macOS 14 or later, and the Swift toolchain (Xcode) to build from source
- Verilator and Surfer (simulation and waveforms)
- openFPGALoader (check that your board is on its supported list)
- Tailscale (optional, for reaching the build machine from outside your home network)

**On the build machine**
- Vivado, installed by you (the free Standard edition covers many boards)
- OpenSSH Server enabled
- Stays powered on and awake while you build

**Hardware**
- An FPGA board supported by both Vivado and openFPGALoader, plus a USB cable

## Quick Start

Not available yet. This section will cover:

1. Setting up SSH access to the build machine
2. Pointing fpga-bridge at your Vivado install
3. Running your first remote build

## Remote Access Tips

- Install Tailscale on both machines and sign in with the same account. Your Mac can then reach the build machine from anywhere with no router changes.
- Turn off sleep on the build machine, and stop Windows from restarting for updates mid-build.
- Pin one Vivado version on the build machine so builds stay consistent.

## Roadmap

1. **CLI prototype:** a Tcl build script plus a Swift CLI that copies files over SSH, runs the Vivado build, and pulls results back
2. **Basic Mac app:** editor, build button, live log, parsed timing and utilization summary
3. **Simulation and flashing:** one-click Verilator runs and board programming
4. **Polish:** easier first-run setup, support for more boards, user testing

## Known Limitations

- Requires a separate machine that can run Vivado
- If the build machine is off or offline, builds can't run
- Some boards may need extra USB drivers or settings on macOS
- Different Vivado versions behave differently, so one version per build machine is recommended

## Legal

fpga-bridge does not include, bundle, or redistribute Vivado. You must install Vivado yourself and comply with AMD's license terms. Vivado and Xilinx are trademarks of AMD. Apple, Mac, and macOS are trademarks of Apple Inc. This project is independent and is not affiliated with or endorsed by AMD or Apple.

## Contributing

Ideas and pull requests are welcome. Open an issue first for larger changes so we can talk through the approach.

## License

MIT (add a `LICENSE` file before publishing).
