---
name: run-pcileech-hd60pro
description: Build, simulate and drive the MZ0380 (Elgato HD60 Pro) PCILeech FPGA RTL. Use to run, simulate, exercise or test the changed SystemVerilog (DMA engine, BAR0 mailbox, peripheral model, CFG window) in this container without Vivado or hardware — drives the modules through their real BAR0 register bus and AXIS TLP interface with Verilator.
---

# Run / simulate pcileech-hd60pro (MZ0380 RTL)

This is Xilinx Artix-7 FPGA firmware. The shipping surface is a bitstream
synthesised by Vivado, flashed to a PCILeech board, enumerating as a PCIe
device — **none of which exists in this container** (no Vivado, no FPGA, no
PCIe host, and the PCIe core is present only as Xilinx `.xci`).

What *can* run here is the behavioural RTL. The changed submodules
(`pcileech_dma_engine`, `pcileech_bar_impl_mz0380_mb`,
`pcileech_mz0380_periph`, `pcileech_bar_impl_mz0380_cfg`) don't instantiate
the vendor IP, so Verilator compiles them and the testbenches drive them
through their **real** interfaces — the BAR0 register bus and the AXIS TLP
source the sink mux would consume. That is the surface here.

All paths below are relative to `pcileech-hd60pro/` (the unit dir).

## Prerequisites

```bash
apt-get update && apt-get install -y verilator
```

Verilator 5.x (this was tested on 5.020) and its g++ toolchain. That's it.
**Do not use Icarus (`iverilog`)** — it cannot parse the `IfAXIS128.source`
modport port on `pcileech_dma_engine` and fails at the port list.

## Run (agent path)

One command builds and runs both testbenches and prints `ALL PASS`:

```bash
bash .claude/skills/run-pcileech-hd60pro/drive.sh
```

Expected tail:

```
  PASS  tlp count = 6227
  PASS  payload = 0x30a5c0
  PASS  in-flight TLP ran to full 512 B
  PASS  only the in-flight TLP emitted
  PASS  engine idle after abort
...
  PASS  T6 bridge reg round-trip -> PARAM3 = 0x000000ab
  INFO  T7 MST read unpowered -> 0x00000000 (NAK, pin9 gate)
RESULT: PASS
== summary ==
ALL PASS
```

`drive.sh` exits 0 only when both testbenches print `RESULT: PASS`. The
testbenches live next to it:

- `tb_dma_engine.sv` — drives `mz_arm`, acts as the AXIS sink. Verifies the
  full no-signal burst (6227 TLPs, exactly `0x30a5c0` payload bytes — which is
  also the no-double-send check) and that STOP mid-TLP finishes the in-flight
  TLP to a full 512 B then idles (the abort-at-boundary behaviour).
- `tb_mailbox.sv` — drives BAR0 writes/reads. Verifies the STATUS boot/ok
  stamps, `GET_BOARD_VERSION`, `SET_BUF_VID` → slot table + count, START/STOP →
  `mz_arm`, and a bridge REG write/read round-trip that exercises the periph
  PARAM mux and the read-result capture into PARAM3.

## Run one testbench by hand

From `src/` (so `$readmemh` finds `mz0380_logo.mem` / `mz0380_edid.mem`):

```bash
cd src
verilator --binary --timing -Wno-fatal -I. --top-module tb_dma_engine \
  --Mdir /tmp/v_dma -o sim_dma \
  pcileech_mz0380_pkg.sv pcileech_dma_engine.sv \
  ../.claude/skills/run-pcileech-hd60pro/tb_dma_engine.sv
/tmp/v_dma/sim_dma
```

Swap in `tb_mailbox` / `pcileech_mz0380_periph.sv pcileech_bar_impl_mz0380_mb.sv`
for the mailbox bench.

## Static checks (not a substitute for the sim)

The repo ships its own elaboration + wiring checks. They catch multi-driver
and port errors but prove nothing about behaviour:

```bash
pip install pyslang      # one-time
python3 tools/lint.py src/pcileech_mz0380_pkg.sv src/pcileech_bar_impl_mz0380_mb.sv \
  src/pcileech_mz0380_periph.sv src/pcileech_dma_engine.sv src/pcileech_bar_impl_mz0380_cfg.sv
python3 tools/check_wiring.py
```

## Gotchas

- **`iverilog` is a dead end** for the DMA engine: it errors on the interface
  modport port (`IfAXIS128.source tlps_out`). Verilator is required.
- **Run from `src/`.** The engine does `$readmemh("mz0380_logo.mem", ...)` with
  a cwd-relative path; `drive.sh` already `cd`s there.
- **`-Wno-fatal` is needed.** Verilator lints the stock pcileech style (WIDTH,
  UNUSED, etc.) hard; the testbenches don't fix stock warnings, they downgrade
  them. Real elaboration errors still fail the build.
- **MST receiver can't be powered from the mailbox.** The modeled GPIO set
  only drives the low 8 shadow bits, but MST power is pin9 (`gpio_shadow[9]`),
  so the no-signal MST constants (0x55=0x03 etc.) stay gated — an MST read
  reads back 0 (NAK). This is pre-existing, not something the diff changed; it
  means the MST-index fix can't be exercised end-to-end here. `tb_mailbox`
  records it as the T7 `INFO` line rather than a pass/fail.
- **The board top is out of scope.** `pcileech_*_top.sv` → `pcie_7x_0` needs
  Vivado + xsim and a root-complex BFM; true end-to-end stays flash-to-hardware
  plus `lspci -nn -d 12ab:0381` and the Elgato/Wolffyx driver probe.

## Troubleshooting

- `Unable to locate package verilator` → run `apt-get update` first.
- `sim_*: Unable to open input file` / `$readmemh` can't find the `.mem` →
  you're not in `src/`; use `drive.sh` or `cd src` first.
- Build log at `/tmp/<mktemp>/build_*.log` (path printed on failure by
  `drive.sh`).
