# Supported boards

Use with `fpga-bridge new --board <id> --top <module>`. Spellings are forgiving: `Basys-3`, `basys_3` and `basys3` all work.

| id | Board | Vivado part | Family |
| --- | --- | --- | --- |
| `basys3` | Basys 3 | `xc7a35tcpg236-1` | Artix-7 |
| `arty-a7-35` | Arty A7-35 | `xc7a35ticsg324-1L` | Artix-7 |
| `arty-a7-100` | Arty A7-100 | `xc7a100tcsg324-1` | Artix-7 |
| `nexys-a7-100` | Nexys A7-100T | `xc7a100tcsg324-1` | Artix-7 |
| `cmod-a7-15` | Cmod A7-15T | `xc7a15tcpg236-1` | Artix-7 |
| `cmod-a7-35` | Cmod A7-35T | `xc7a35tcpg236-1` | Artix-7 |
| `arty-s7-25` | Arty S7-25 | `xc7s25csga324-1` | Spartan-7 |
| `arty-s7-50` | Arty S7-50 | `xc7s50csga324-1` | Spartan-7 |

Not included yet:
- **Nexys A7-50T.** Sources disagree on its temperature grade (commercial `C` vs industrial `I`), which changes the Vivado part string, and Digilent lists it as retired.
- **Zynq boards** (Zybo, Arty Z7). They need processor-system handling that the plain bitstream flow does not do.

Part strings were checked against Digilent reference manuals and distributor listings. If your board is not listed, use `--part` with the part printed on the FPGA.
